import SwiftUI

/// Implementation steps 1–4 from the handoff: UUID discovery, fixture replay,
/// palette-characteristic verification, generated packets, AES self-test, ack log.
struct DiagnosticsView: View {
    @ObservedObject var host: AppHost
    @ObservedObject var vm: LightViewModel
    @State private var target: String = ""   // "" = all enabled lights

    private var targetName: String? { target.isEmpty ? nil : target }
    private var g: GlobalSettings { vm.snap.global }

    var body: some View {
        List {
            connectionSection
            fixtureSection
            patternSection
            paletteSection
            generatedSection
            characteristicsSection
            selfTestSection
            logSection
        }
        .navigationTitle("Diagnostics")
    }

    private var connectionSection: some View {
        Section {
            Picker("Send to", selection: $target) {
                Text("All enabled lights").tag("")
                ForEach(g.devices) { Text($0.name).tag($0.name) }
            }
            if g.transport == .direct && !host.appConnectOverride {
                Button("Connect from this app for testing") { host.appConnectOverride = true }
                    .buttonStyle(.borderedProminent)
            }
            ForEach(vm.snap.statuses) { st in
                HStack {
                    Circle().fill(st.phase.tint).frame(width: 8, height: 8)
                    Text(st.name)
                    Spacer()
                    Text("\(st.phaseLabel) · tx \(st.sent) · ack \(st.acks)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        } header: { Text("Connection") }
    }

    private var fixtureSection: some View {
        Section {
            HStack {
                Button("OFF") { host.engine.sendFixture(hex: IStrip.fixtureOff, to: targetName) }
                    .buttonStyle(.bordered)
                Button("ON") { host.engine.sendFixture(hex: IStrip.fixtureOn, to: targetName) }
                    .buttonStyle(.bordered)
            }
        } header: {
            Text("Step 1 · Known-good replay")
        } footer: {
            Text("Exact captured ciphertext you already confirmed in nRF Connect.")
        }
    }

    private var patternSection: some View {
        Section {
            ForEach(IStrip.modes) { m in
                HStack {
                    Text(m.label).font(.caption.monospaced())
                    Text(m.detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Replay") { host.engine.sendFixture(hex: m.fixture, to: targetName) }
                        .buttonStyle(.bordered)
                    if m.bank == .mult {
                        Button("+ Palette") {
                            host.engine.sendFixture(hex: m.fixture, to: targetName)
                            host.engine.sendPalette(IStrip.palette(PaletteLibrary.captured, length: g.paletteLength),
                                                    to: targetName)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        } header: {
            Text("Step 3 · Captured patterns")
        } footer: {
            Text("Exact captured commands. MULT modes need a palette write after the command; '+ Palette' sends the captured colors with a zero-filled tail (length set in Settings).")
        }
    }

    private var paletteSection: some View {
        Section {
            LabeledContent("Palette characteristic", value: String(g.paletteCharacteristic.suffix(6)))
            HStack {
                Button("Captured palette ×100") {
                    host.engine.sendPalette(IStrip.palette(PaletteLibrary.captured, length: 100), to: targetName)
                }
                .buttonStyle(.bordered)
                Button("×23") {
                    host.engine.sendPalette(IStrip.palette(PaletteLibrary.captured, length: 23), to: targetName)
                }
                .buttonStyle(.bordered)
            }
        } header: {
            Text("Step 2 · Palette characteristic")
        } footer: {
            Text("The handoff infers handle 0x0009 = …12960A. Pick a MULT mode, then send a palette: if the colors change, that characteristic is right. If not, choose another writable one below.")
        }
    }

    private var generatedSection: some View {
        Section {
            HStack {
                Button("TURN OFF (zero filler)") { host.engine.sendPlain(IStrip.turn(false, filler: .zero), to: targetName) }
                    .buttonStyle(.bordered)
                Button("ON") { host.engine.sendPlain(IStrip.turn(true, filler: .zero), to: targetName) }
                    .buttonStyle(.bordered)
            }
            Button("Resend current Perform state (generated)") { host.engine.forceResend() }
                .buttonStyle(.bordered)
            Text("Current: \(vm.mode.label) · speed \(vm.state.speed) · brightness \(vm.state.brightness)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        } header: {
            Text("Step 3 · Generated packets")
        } footer: {
            Text("Checks sanitized filler bytes. Then use the Perform tab: move Speed to learn which direction is faster (flip 'Invert speed' if needed) and check brightness on both banks.")
        }
    }

    private var characteristicsSection: some View {
        Section {
            ForEach(vm.snap.statuses) { st in
                if !st.characteristics.isEmpty {
                    Text(st.name).font(.caption.weight(.semibold))
                }
                ForEach(st.characteristics) { c in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(c.uuid).font(.caption2.monospaced())
                            Text(c.properties).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if c.uuid.uppercased() == g.paletteCharacteristic.uppercased() {
                            Text("palette").font(.caption2).foregroundStyle(.cyan)
                        } else if c.properties.contains("write") {
                            Button("Use for palette") {
                                vm.updateGlobal { $0.paletteCharacteristic = c.uuid }
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        } header: {
            Text("Discovered characteristics")
        }
    }

    private var selfTestSection: some View {
        Section {
            let passed = host.selfTest.filter { $0.passed }.count
            Text("\(passed) / \(host.selfTest.count) passed")
                .font(.headline)
                .foregroundStyle(passed == host.selfTest.count ? Color.green : Color.red)
            DisclosureGroup("Details") {
                ForEach(host.selfTest) { r in
                    HStack(alignment: .top) {
                        Image(systemName: r.passed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(r.passed ? Color.green : Color.red)
                        VStack(alignment: .leading) {
                            Text(r.name).font(.caption.weight(.semibold))
                            Text(r.detail).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Step 4 · AES + packet self-test")
        }
    }

    private var logSection: some View {
        Section {
            Button("Clear log") { host.logs.removeAll() }
            ForEach(Array(host.logs.suffix(150).reversed().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text("Log (newest first) — → sent, ← notification")
        }
    }
}
