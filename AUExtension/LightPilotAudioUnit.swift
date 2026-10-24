import AudioToolbox
import AVFoundation
import CoreAudioKit
import Foundation

/// One Bluetooth owner per plugin process, even when Loopy loads several LightPilot instances.
enum PluginSinks {
    private static let lock = NSLock()
    private static var direct: BLELightEngine?
    private static var bridge: BridgeSender?
    private static var directRefs = 0
    private static var bridgeRefs = 0

    static func acquire(_ transport: Transport) -> LightSink {
        lock.lock(); defer { lock.unlock() }
        switch transport {
        case .direct:
            if direct == nil {
                // Ask the app (if open) to drop its connections so the plugin can own the lights.
                DarwinCenter.shared.post(.releaseBluetooth)
                let engine = BLELightEngine(role: .plugin, wantsConnections: true)
                engine.start()
                direct = engine
            }
            directRefs += 1
            return direct!
        case .bridge:
            if bridge == nil {
                let sender = BridgeSender()
                sender.start()
                bridge = sender
            }
            bridgeRefs += 1
            return bridge!
        }
    }

    static func release(_ transport: Transport) {
        lock.lock(); defer { lock.unlock() }
        switch transport {
        case .direct:
            directRefs -= 1
            if directRefs <= 0 {
                directRefs = 0
                direct?.stop()
                direct = nil
            }
        case .bridge:
            bridgeRefs -= 1
            if bridgeRefs <= 0 {
                bridgeRefs = 0
                bridge?.stop()
                bridge = nil
            }
        }
    }
}

/// MIDI processor AUv3 (type 'aumi'). The render block only copies MIDI bytes and parameter
/// events into a lock-free ring; Bluetooth, AES and all decisions run on PerformanceCore's queue.
final class LightPilotAudioUnit: AUAudioUnit {

    let rt: OpaquePointer
    let core: PerformanceCore

    private let stateLock = NSLock()
    private var transport: Transport
    private var outputBus: AUAudioUnitBus!
    private var outputBusArray: AUAudioUnitBusArray!

    private static let stateKey = "lightpilot.instance"

    override init(componentDescription: AudioComponentDescription,
                  options: AudioComponentInstantiationOptions = []) throws {
        guard let rt = lp_rt_create() else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))
        }
        self.rt = rt
        let initial = InstanceState(state: LightState(), performance: PerformanceSettings())
        self.core = PerformanceCore(rt: rt, isPlugin: true, initial: initial)
        self.transport = SharedStore.shared.loadGlobal().transport

        try super.init(componentDescription: componentDescription, options: options)

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        outputBus = try AUAudioUnitBus(format: format)
        outputBus.maximumChannelCount = 2
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        maximumFramesToRender = 4096

        buildParameters(initial: initial.state)

        core.onParamOut = { [weak self] target, value in
            self?.parameterTree?.parameter(withAddress: AUParameterAddress(target.rawValue))?
                .setValue(AUValue(value), originator: nil)
        }
        core.onTransportChanged = { [weak self] newTransport in
            self?.switchTransport(to: newTransport)
        }
        core.setSink(PluginSinks.acquire(transport))
    }

    deinit {
        core.shutdown()
        stateLock.lock()
        let t = transport
        stateLock.unlock()
        PluginSinks.release(t)
        lp_rt_destroy(rt)
    }

    private func switchTransport(to newTransport: Transport) {
        stateLock.lock()
        let old = transport
        transport = newTransport
        stateLock.unlock()
        guard old != newTransport else { return }
        let sink = PluginSinks.acquire(newTransport)
        core.setSink(sink)
        PluginSinks.release(old)
    }

    /// UI moves go through the parameter so Loopy sees and records them.
    func setFromUI(_ target: ControlTarget, _ value: Double) {
        parameterTree?.parameter(withAddress: AUParameterAddress(target.rawValue))?
            .setValue(AUValue(value), originator: nil)
    }

    // MARK: Parameters

    private func buildParameters(initial: LightState) {
        let flags: AudioUnitParameterOptions = [.flag_IsReadable, .flag_IsWritable]
        var params: [AUParameter] = []
        for t in ControlTarget.allCases {
            var unit: AudioUnitParameterUnit = .generic
            var strings: [String]?
            switch t {
            case .power:
                unit = .indexed
                strings = ["Off", "On"]
            case .pattern:
                unit = .generic
            case .speed, .brightness, .saturation:
                unit = .percent
            case .hueA, .hueB:
                unit = .degrees
            case .palette:
                unit = .indexed
                strings = (0..<PaletteLibrary.count).map { PaletteLibrary.name($0) }
            case .favorite:
                unit = .indexed
                strings = ["—"] + (1...Favorites.slotCount).map { "Favorite \($0)" }
            }
            let p = AUParameterTree.createParameter(withIdentifier: t.identifier,
                                                    name: t.name,
                                                    address: AUParameterAddress(t.rawValue),
                                                    min: AUValue(t.range.lowerBound),
                                                    max: AUValue(t.range.upperBound),
                                                    unit: unit,
                                                    unitName: nil,
                                                    flags: flags,
                                                    valueStrings: strings,
                                                    dependentParameters: nil)
            lp_rt_store_param_quiet(rt, UInt32(t.rawValue), Float(t.value(in: initial)))
            params.append(p)
        }

        let tree = AUParameterTree.createTree(withChildren: params)
        let rt = self.rt
        tree.implementorValueObserver = { param, value in
            lp_rt_set_param(rt, UInt32(truncatingIfNeeded: param.address), value)
        }
        tree.implementorValueProvider = { param in
            lp_rt_get_param(rt, UInt32(truncatingIfNeeded: param.address))
        }
        tree.implementorStringFromValueCallback = { param, valuePtr in
            let v = Double(valuePtr?.pointee ?? param.value)
            guard let t = ControlTarget(rawValue: Int(param.address)) else { return String(format: "%.0f", v) }
            switch t {
            case .pattern:
                let i = max(0, min(IStrip.modes.count - 1, Int(v.rounded())))
                return IStrip.modes[i].name
            case .power:
                return v >= 0.5 ? "On" : "Off"
            case .palette:
                return PaletteLibrary.name(Int(v.rounded()))
            case .favorite:
                let k = Int(v.rounded())
                return k == 0 ? "—" : "Favorite \(k)"
            case .hueA, .hueB:
                return String(format: "%.0f°", v)
            default:
                return String(format: "%.0f", v)
            }
        }
        parameterTree = tree
    }

    // MARK: AUAudioUnit

    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override var internalRenderBlock: AUInternalRenderBlock {
        let rt = self.rt
        return { _, _, _, _, outputData, realtimeEventListHead, _ in
            var event = realtimeEventListHead
            while let e = event {
                switch e.pointee.head.eventType {
                case .MIDI:
                    let m = e.pointee.MIDI
                    let d1: UInt32 = m.length > 1 ? UInt32(m.data.1) : 0
                    let d2: UInt32 = m.length > 2 ? UInt32(m.data.2) : 0
                    _ = lp_rt_push_midi(rt, UInt32(m.data.0) | (d1 << 8) | (d2 << 16))
                case .parameter, .parameterRamp:
                    let p = e.pointee.parameter
                    lp_rt_set_param(rt, UInt32(truncatingIfNeeded: p.parameterAddress), p.value)
                default:
                    break
                }
                event = UnsafePointer(e.pointee.head.next)
            }
            // MIDI processor: output silence on the (host-required) bus.
            let buffers = UnsafeMutableAudioBufferListPointer(outputData)
            for buffer in buffers {
                if let data = buffer.mData {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
            return noErr
        }
    }

    override var fullState: [String: Any]? {
        get {
            var s = super.fullState ?? [:]
            if let data = try? JSONEncoder().encode(core.instanceState()) {
                s[Self.stateKey] = data
            }
            return s
        }
        set {
            super.fullState = newValue
            if let data = newValue?[Self.stateKey] as? Data,
               let inst = try? JSONDecoder().decode(InstanceState.self, from: data) {
                core.restore(inst)
            }
        }
    }

    override var canProcessInPlace: Bool { true }
}
