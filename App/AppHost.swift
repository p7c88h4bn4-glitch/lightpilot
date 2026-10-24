import Foundation
import SwiftUI

/// Owns the app-side Bluetooth engine, the bridge receiver, and the app's own control core.
final class AppHost: ObservableObject {
    static let shared = AppHost()

    let engine: BLELightEngine
    let core: PerformanceCore
    let receiver: BridgeReceiver
    let vm: LightViewModel

    @Published var logs: [String] = []
    @Published var discovered: [DiscoveredDevice] = []
    @Published var scanning = false
    @Published var selfTest: [ProtocolSelfTest.Result] = []
    /// Lets the app connect while transport == .direct (diagnostics only).
    @Published var appConnectOverride = false {
        didSet { applyPolicy() }
    }

    private var saveWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "com.mrbradsmusic.lightpilot.appsave", qos: .utility)

    private init() {
        let g = SharedStore.shared.loadGlobal()
        engine = BLELightEngine(role: .app, wantsConnections: g.transport == .bridge)
        let inst = SharedStore.shared.load(InstanceState.self, SharedStore.appInstanceFile)
        core = PerformanceCore(rt: nil, isPlugin: false, initial: inst)
        receiver = BridgeReceiver(engine: engine)
        vm = LightViewModel(core: core)

        engine.addLogListener { [weak self] line in
            let stamp = Self.timeFormatter.string(from: Date())
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.logs.append("\(stamp) \(line)")
                if self.logs.count > 400 { self.logs.removeFirst(self.logs.count - 400) }
            }
        }
        engine.addDiscoveryListener { [weak self] list in
            DispatchQueue.main.async { self?.discovered = list }
        }

        core.onInstanceChanged = { [weak self] inst in self?.scheduleSave(inst) }
        core.onTransportChanged = { [weak self] _ in
            DispatchQueue.main.async { self?.applyPolicy() }
        }
        core.setSink(engine)
        engine.start()

        DarwinCenter.shared.observe(.releaseBluetooth) { [weak self] in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if SharedStore.shared.loadGlobal().transport == .direct {
                    self.appConnectOverride = false
                    self.log("Plugin started in Direct mode — app released Bluetooth")
                }
            }
        }
        DarwinCenter.shared.observe(.settings) { [weak self] in
            DispatchQueue.main.async { self?.applyPolicy() }
        }
        applyPolicy()
        selfTest = ProtocolSelfTest.run()
    }

    var transport: Transport { SharedStore.shared.loadGlobal().transport }

    func applyPolicy() {
        let t = transport
        engine.setWantsConnections(t == .bridge || appConnectOverride)
        receiver.setActive(t == .bridge)
        engine.reloadSettings()
    }

    func startScan() {
        scanning = true
        engine.startDiscovery()
    }

    func stopScan() {
        scanning = false
        engine.stopDiscovery()
    }

    func addDevice(_ d: DiscoveredDevice) {
        core.updateGlobal { g in
            guard !g.devices.contains(where: { $0.name == d.name }), g.devices.count < 2 else { return }
            g.devices.append(DeviceRef(name: d.name, appIdentifier: d.identifier, auIdentifier: nil, enabled: true))
        }
    }

    func removeDevice(_ name: String) {
        core.updateGlobal { g in g.devices.removeAll { $0.name == name } }
    }

    func setEnabled(_ name: String, _ on: Bool) {
        core.updateGlobal { g in
            if let i = g.devices.firstIndex(where: { $0.name == name }) { g.devices[i].enabled = on }
        }
    }

    func log(_ s: String) {
        logs.append("\(Self.timeFormatter.string(from: Date())) \(s)")
    }

    private func scheduleSave(_ inst: InstanceState) {
        saveQueue.async {
            self.saveWork?.cancel()
            let work = DispatchWorkItem { SharedStore.shared.save(inst, SharedStore.appInstanceFile) }
            self.saveWork = work
            self.saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
