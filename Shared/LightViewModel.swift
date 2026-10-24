import Foundation
import SwiftUI

/// Main-thread view model shared by the app and the plugin UI.
final class LightViewModel: ObservableObject {
    @Published private(set) var snap = CoreSnapshot()

    let core: PerformanceCore
    /// Plugin: routes through AUParameter.setValue so the host sees UI moves.
    /// App: calls the core directly.
    private let setParam: (ControlTarget, Double) -> Void

    init(core: PerformanceCore, setParam: ((ControlTarget, Double) -> Void)? = nil) {
        self.core = core
        self.setParam = setParam ?? { [weak core] t, v in core?.set(t, v) }
        core.onSnapshot = { [weak self] s in
            guard let self = self, self.snap != s else { return }
            self.snap = s
        }
        core.requestSnapshot()
    }

    var state: LightState { snap.state }
    var mode: IStrip.Mode { snap.state.mode }

    func set(_ t: ControlTarget, _ v: Double) { setParam(t, v) }

    func binding(_ t: ControlTarget) -> Binding<Double> {
        Binding(
            get: { t == .pattern ? self.snap.position : t.value(in: self.snap.state) },
            set: { self.set(t, $0) }
        )
    }

    func step(pattern delta: Int) {
        let n = IStrip.modes.count
        let next = (snap.state.patternIndex + delta + n) % n
        set(.pattern, Double(next))
    }

    func togglePower() { set(.power, snap.state.power ? 0 : 1) }

    func recall(_ slot: Int) { core.recallFavorite(slot) }
    func save(_ slot: Int) { core.saveFavorite(slot) }
    func clear(_ slot: Int) { core.clearFavorite(slot) }

    func learn(_ t: ControlTarget) { core.beginLearn(t) }
    func clearMapping(_ t: ControlTarget) { core.clearMapping(t) }
    func setChannel(_ ch: Int) { core.setMIDIChannel(ch) }
    func setHysteresis(_ h: Double) { core.setHysteresis(h) }
    func updateGlobal(_ change: @escaping (inout GlobalSettings) -> Void) { core.updateGlobal(change) }
    func setCustomColor(_ i: Int, _ c: RGB) { core.setCustomPaletteColor(i, c) }

    func ccLabel(_ t: ControlTarget) -> String {
        if snap.learnTarget == t { return "Learning…" }
        if let cc = snap.performance.ccMap[t.rawValue] { return "CC \(cc)" }
        return "—"
    }
}

extension RGB {
    var color: Color {
        Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

extension LightStatus.Phase {
    var tint: Color {
        switch self {
        case .ready: return .green
        case .connecting, .discovering: return .yellow
        case .notFound, .disconnected: return .orange
        case .bridgeOffline, .bluetoothOff, .unauthorized: return .red
        }
    }
}
