import Foundation

private struct BridgeStateRecord: Codable {
    var seq: UInt64
    var state: LightState
}

private struct BridgeStatusRecord: Codable {
    var time: Double
    var statuses: [LightStatus]
}

/// Plugin side of the fallback path: forwards the latest desired state to the LightPilot app,
/// which owns Bluetooth. Writes are coalesced; only the newest state is ever written.
final class BridgeSender: LightSink {
    private let queue = DispatchQueue(label: "com.mrbradsmusic.lightpilot.bridge.sender", qos: .userInitiated)
    private var latest: LightState?
    private var scheduled = false
    private var seq: UInt64 = UInt64.random(in: 1...(UInt64.max / 2))
    private var listeners: [([LightStatus]) -> Void] = []
    private var token: UUID?
    private var watchdog: DispatchSourceTimer?
    private var lastStatusTime: Double = 0
    private var lastStatuses: [LightStatus] = []

    func submit(_ state: LightState) {
        queue.async {
            self.latest = state
            guard !self.scheduled else { return }
            self.scheduled = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(15)) { self.flush() }
        }
    }

    private func flush() {
        scheduled = false
        guard let s = latest else { return }
        seq &+= 1
        SharedStore.shared.save(BridgeStateRecord(seq: seq, state: s), SharedStore.bridgeStateFile)
        DarwinCenter.shared.post(.bridgeState)
    }

    func addStatusListener(_ listener: @escaping ([LightStatus]) -> Void) {
        queue.async { self.listeners.append(listener) }
    }

    func reloadSettings() {}

    func start() {
        queue.async {
            guard self.token == nil else { return }
            self.token = DarwinCenter.shared.observe(.bridgeStatus) { [weak self] in
                self?.queue.async { self?.readStatus() }
            }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in self?.checkAlive() }
            t.resume()
            self.watchdog = t
            self.readStatus()
            // Push current state so the app catches up right away.
            if self.latest != nil { self.flush() }
        }
    }

    func stop() {
        queue.async {
            if let t = self.token { DarwinCenter.shared.remove(.bridgeStatus, t) }
            self.token = nil
            self.watchdog?.cancel()
            self.watchdog = nil
        }
    }

    private func readStatus() {
        guard let rec = SharedStore.shared.load(BridgeStatusRecord.self, SharedStore.bridgeStatusFile) else {
            checkAlive()
            return
        }
        lastStatusTime = rec.time
        lastStatuses = rec.statuses
        checkAlive()
    }

    private func checkAlive() {
        let alive = Date().timeIntervalSince1970 - lastStatusTime < 3.5
        let list: [LightStatus]
        if alive {
            list = lastStatuses
        } else {
            let names = SharedStore.shared.loadGlobal().devices.map { $0.name }
            list = (names.isEmpty ? ["LightPilot app"] : names).map { LightStatus(name: $0, phase: .bridgeOffline) }
        }
        listeners.forEach { $0(list) }
    }
}

/// App side of the fallback path: reads states the plugin wrote and feeds the BLE engine;
/// publishes the engine's status back with a heartbeat.
final class BridgeReceiver {
    private let engine: BLELightEngine
    private let queue = DispatchQueue(label: "com.mrbradsmusic.lightpilot.bridge.receiver", qos: .userInitiated)
    private var token: UUID?
    private var lastSeq: UInt64 = 0
    private(set) var active = false
    var onRemoteState: ((LightState) -> Void)?

    init(engine: BLELightEngine) {
        self.engine = engine
        engine.addStatusListener { [weak self] statuses in
            self?.queue.async { self?.publish(statuses) }
        }
    }

    func setActive(_ on: Bool) {
        queue.async {
            guard on != self.active else { return }
            self.active = on
            if on {
                self.token = DarwinCenter.shared.observe(.bridgeState) { [weak self] in
                    self?.queue.async { self?.readState() }
                }
                self.readState()
            } else if let t = self.token {
                DarwinCenter.shared.remove(.bridgeState, t)
                self.token = nil
            }
        }
    }

    private func readState() {
        guard active,
              let rec = SharedStore.shared.load(BridgeStateRecord.self, SharedStore.bridgeStateFile),
              rec.seq != lastSeq else { return }
        lastSeq = rec.seq
        engine.submit(rec.state)
        onRemoteState?(rec.state)
    }

    private func publish(_ statuses: [LightStatus]) {
        guard active else { return }
        SharedStore.shared.save(BridgeStatusRecord(time: Date().timeIntervalSince1970, statuses: statuses),
                                SharedStore.bridgeStatusFile)
        DarwinCenter.shared.post(.bridgeStatus)
    }
}
