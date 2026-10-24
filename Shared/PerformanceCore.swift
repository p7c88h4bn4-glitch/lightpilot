import Foundation

/// Everything the UI needs, published to the main thread at most ~30x/second.
struct CoreSnapshot: Equatable {
    var state = LightState()
    var position: Double = 0
    var statuses: [LightStatus] = []
    var learnTarget: ControlTarget?
    var performance = PerformanceSettings()
    var global = GlobalSettings()
    var favoritesFilled: [Bool] = Array(repeating: false, count: Favorites.slotCount)
    var lastMIDI = ""
    var droppedMIDI: UInt32 = 0
    var isPlugin = false
}

/// The non-realtime brain shared by the app and the plugin.
/// All mutable state is confined to `queue`. In the plugin it also drains the realtime
/// MIDI ring and parameter slots (filled by the render thread) on a short timer.
final class PerformanceCore {

    let queue = DispatchQueue(label: "com.mrbradsmusic.lightpilot.core", qos: .userInitiated)
    let isPlugin: Bool

    private let rt: OpaquePointer?
    private var pumpTimer: DispatchSourceTimer?
    private var state: LightState
    private var position: Double
    private var perf: PerformanceSettings
    private var global: GlobalSettings
    private var favorites: [LightState?]
    private var sink: LightSink?
    private var statuses: [LightStatus] = []
    private var learnTarget: ControlTarget?
    private var lastMIDI = ""
    private var lastFavoriteParam = 0
    private var snapshotScheduled = false
    private var settingsToken: UUID?

    /// Called on the main thread.
    var onSnapshot: ((CoreSnapshot) -> Void)?
    /// Called on `queue` when a value changed from MIDI / favorites / restore and the host's
    /// parameter should follow. (Plugin only.)
    var onParamOut: ((ControlTarget, Double) -> Void)?
    /// Called on `queue` after any state or mapping change (for persistence).
    var onInstanceChanged: ((InstanceState) -> Void)?
    /// Called on `queue` when the shared transport setting changes.
    var onTransportChanged: ((Transport) -> Void)?

    init(rt: OpaquePointer?, isPlugin: Bool, initial: InstanceState?) {
        self.rt = rt
        self.isPlugin = isPlugin
        let st = (initial?.state ?? LightState()).clamped()
        self.state = st
        self.position = Double(st.patternIndex)
        self.perf = initial?.performance ?? PerformanceSettings()
        self.global = SharedStore.shared.loadGlobal()
        self.favorites = SharedStore.shared.loadFavorites()

        settingsToken = DarwinCenter.shared.observe(.settings) { [weak self] in
            self?.queue.async { self?.reloadShared() }
        }
        if rt != nil { startPump() }
    }

    deinit {
        if let t = settingsToken { DarwinCenter.shared.remove(.settings, t) }
    }

    func shutdown() {
        queue.sync {
            pumpTimer?.cancel()
            pumpTimer = nil
            sink = nil
            onSnapshot = nil
            onParamOut = nil
        }
    }

    // MARK: Sink

    func setSink(_ newSink: LightSink?) {
        queue.async {
            self.sink = newSink
            guard let newSink = newSink else { return }
            newSink.addStatusListener { [weak self, weak newSink] list in
                guard let self = self else { return }
                self.queue.async {
                    guard let current = self.sink, current === newSink else { return }
                    self.statuses = list
                    self.scheduleSnapshot()
                }
            }
            newSink.submit(self.state)
            self.scheduleSnapshot()
        }
    }

    // MARK: Public API (thread-safe)

    /// Apply a control value. `echo` pushes it back to the host parameter (plugin MIDI path).
    func set(_ target: ControlTarget, _ value: Double, echo: Bool = false) {
        queue.async { self.apply(target, value, echo: echo) }
    }

    func recallFavorite(_ slot: Int) {
        queue.async { self.recall(slot) }
    }

    func saveFavorite(_ slot: Int) {
        queue.async {
            guard slot >= 0 && slot < Favorites.slotCount else { return }
            self.favorites[slot] = self.state
            SharedStore.shared.saveFavorites(self.favorites)
            self.scheduleSnapshot()
        }
    }

    func clearFavorite(_ slot: Int) {
        queue.async {
            guard slot >= 0 && slot < Favorites.slotCount else { return }
            self.favorites[slot] = nil
            SharedStore.shared.saveFavorites(self.favorites)
            self.scheduleSnapshot()
        }
    }

    func setCustomPaletteColor(_ index: Int, _ color: RGB) {
        queue.async {
            guard index >= 0 && index < 7 else { return }
            var s = self.state
            s.customPalette[index] = color
            self.commit(s)
        }
    }

    func beginLearn(_ target: ControlTarget?) {
        queue.async {
            self.learnTarget = (self.learnTarget == target) ? nil : target
            self.scheduleSnapshot()
        }
    }

    func clearMapping(_ target: ControlTarget) {
        queue.async {
            self.perf.ccMap[target.rawValue] = nil
            self.instanceChanged()
            self.scheduleSnapshot()
        }
    }

    func assignCC(_ target: ControlTarget, _ cc: Int?) {
        queue.async {
            if let cc = cc {
                self.perf.ccMap = self.perf.ccMap.filter { $0.value != cc }
                self.perf.ccMap[target.rawValue] = max(0, min(127, cc))
            } else {
                self.perf.ccMap[target.rawValue] = nil
            }
            self.instanceChanged()
            self.scheduleSnapshot()
        }
    }

    func setMIDIChannel(_ ch: Int) {
        queue.async {
            self.perf.midiChannel = max(0, min(16, ch))
            self.instanceChanged()
            self.scheduleSnapshot()
        }
    }

    func setHysteresis(_ h: Double) {
        queue.async {
            self.perf.hysteresis = max(0, min(0.45, h))
            self.instanceChanged()
            self.scheduleSnapshot()
        }
    }

    func updateGlobal(_ change: @escaping (inout GlobalSettings) -> Void) {
        queue.async {
            let old = self.global
            self.global = SharedStore.shared.updateGlobal(change)
            self.sink?.reloadSettings()
            if old.transport != self.global.transport { self.onTransportChanged?(self.global.transport) }
            if old.invertSpeed != self.global.invertSpeed { self.sink?.submit(self.state) }
            self.scheduleSnapshot()
        }
    }

    func restore(_ inst: InstanceState) {
        queue.async {
            self.perf = inst.performance
            let s = inst.state.clamped()
            self.position = Double(s.patternIndex)
            self.pushAllParams(of: s)
            self.commit(s, force: true)
        }
    }

    func instanceState() -> InstanceState {
        queue.sync { InstanceState(state: state, performance: perf) }
    }

    func currentParamValue(_ t: ControlTarget) -> Double {
        queue.sync { t == .pattern ? position : t.value(in: state) }
    }

    func requestSnapshot() {
        queue.async { self.scheduleSnapshot() }
    }

    // MARK: Internals (on queue)

    private func apply(_ t: ControlTarget, _ v: Double, echo: Bool) {
        var s = state
        switch t {
        case .power:
            s.power = v >= 0.5
        case .pattern:
            position = v
            s.patternIndex = PatternBrowser.quantize(position: v, current: s.patternIndex,
                                                     count: IStrip.modes.count, hysteresis: perf.hysteresis)
        case .speed:
            s.speed = Int(v.rounded())
        case .brightness:
            s.brightness = Int(v.rounded())
        case .hueA:
            s.hueA = v
        case .hueB:
            s.hueB = v
        case .saturation:
            s.saturation = v
        case .palette:
            s.paletteIndex = Int(v.rounded())
        case .favorite:
            let k = Int(v.rounded())
            if k != lastFavoriteParam {
                lastFavoriteParam = k
                if k >= 1 { recall(k - 1) }
            }
            if echo { onParamOut?(t, v) }
            return
        }
        if echo { onParamOut?(t, v) }
        commit(s.clamped())
    }

    private func recall(_ slot: Int) {
        guard slot >= 0 && slot < favorites.count, let fav = favorites[slot] else { return }
        let s = fav.clamped()
        position = Double(s.patternIndex)
        pushAllParams(of: s)
        commit(s)
    }

    private func pushAllParams(of s: LightState) {
        guard let out = onParamOut else { return }
        for t in ControlTarget.allCases where t != .favorite {
            out(t, t.value(in: s))
        }
    }

    private func commit(_ s: LightState, force: Bool = false) {
        if s == state && !force { scheduleSnapshot(); return }
        state = s
        sink?.submit(s)
        instanceChanged()
        scheduleSnapshot()
    }

    private func instanceChanged() {
        onInstanceChanged?(InstanceState(state: state, performance: perf))
    }

    private func reloadShared() {
        let old = global
        global = SharedStore.shared.loadGlobal()
        favorites = SharedStore.shared.loadFavorites()
        if old != global {
            sink?.reloadSettings()
            if old.transport != global.transport { onTransportChanged?(global.transport) }
        }
        scheduleSnapshot()
    }

    // MARK: MIDI

    private func handleMIDI(_ packed: UInt32) {
        let status = UInt8(packed & 0xFF)
        let d1 = UInt8((packed >> 8) & 0x7F)
        let d2 = UInt8((packed >> 16) & 0x7F)
        let type = status & 0xF0
        let channel = Int(status & 0x0F) + 1
        guard type >= 0x80 && type < 0xF0 else { return }

        switch type {
        case 0xB0:
            lastMIDI = "Ch \(channel)  CC \(d1) = \(d2)"
            if let t = learnTarget {
                perf.ccMap = perf.ccMap.filter { $0.value != Int(d1) }
                perf.ccMap[t.rawValue] = Int(d1)
                learnTarget = nil
                instanceChanged()
                scheduleSnapshot()
                return
            }
            guard perf.midiChannel == 0 || perf.midiChannel == channel else { break }
            for t in perf.target(forCC: Int(d1)) {
                apply(t, t.value(fromCC: d2), echo: true)
            }
        case 0xC0:
            lastMIDI = "Ch \(channel)  PC \(d1)"
            guard perf.midiChannel == 0 || perf.midiChannel == channel else { break }
            if global.programChangeRecallsFavorites && Int(d1) < Favorites.slotCount {
                recall(Int(d1))
            }
        case 0x90 where d2 > 0:
            lastMIDI = "Ch \(channel)  Note \(d1) vel \(d2)"
        default:
            break
        }
        scheduleSnapshot()
    }

    private func startPump() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pump() }
        t.resume()
        pumpTimer = t
    }

    private func pump() {
        guard let rt = rt else { return }
        var packed: UInt32 = 0
        var count = 0
        while count < 256 && lp_rt_pop_midi(rt, &packed) {
            handleMIDI(packed)
            count += 1
        }
        let dirty = lp_rt_take_dirty(rt)
        if dirty != 0 {
            for t in ControlTarget.allCases where dirty & (UInt32(1) << UInt32(t.rawValue)) != 0 {
                apply(t, Double(lp_rt_get_param(rt, UInt32(t.rawValue))), echo: false)
            }
        }
    }

    // MARK: Snapshot

    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
            guard let self = self else { return }
            self.snapshotScheduled = false
            var snap = CoreSnapshot()
            snap.state = self.state
            snap.position = self.position
            snap.statuses = self.statuses
            snap.learnTarget = self.learnTarget
            snap.performance = self.perf
            snap.global = self.global
            snap.favoritesFilled = self.favorites.map { $0 != nil }
            snap.lastMIDI = self.lastMIDI
            snap.droppedMIDI = self.rt.map { lp_rt_dropped($0) } ?? 0
            snap.isPlugin = self.isPlugin
            DispatchQueue.main.async { self.onSnapshot?(snap) }
        }
    }
}
