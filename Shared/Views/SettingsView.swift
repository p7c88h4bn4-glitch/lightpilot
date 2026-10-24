import SwiftUI

struct SettingsView: View {
    @ObservedObject var vm: LightViewModel
    @Environment(\.dismiss) private var dismiss

    private var g: GlobalSettings { vm.snap.global }

    var body: some View {
        Form {
            Section {
                Picker("Bluetooth path", selection: Binding(
                    get: { g.transport },
                    set: { v in vm.updateGlobal { $0.transport = v } }
                )) {
                    ForEach(Transport.allCases) { Text($0.label).tag($0) }
                }
                Text(g.transport == .direct
                     ? "The plugin talks to the lights itself. Try this first."
                     : "The plugin forwards to the LightPilot app, which must stay open (Stage Manager or Split View next to Loopy).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: { Text("Connection") }

            Section {
                ForEach(vm.snap.statuses) { st in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Circle().fill(st.phase.tint).frame(width: 8, height: 8)
                            Text(st.name).font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(st.enabled ? st.phaseLabel : "Disabled").font(.caption)
                        }
                        Text("sent \(st.sent) · acks \(st.acks) · last ack \(st.lastLatencyMs) ms\(st.hasPaletteCharacteristic ? "" : " · no palette char")")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                if vm.snap.statuses.isEmpty {
                    Text("Pick your lights in the LightPilot app (Lights tab).").font(.caption)
                }
            } header: { Text("Lights") }

            Section {
                Picker("Channel", selection: Binding(
                    get: { vm.snap.performance.midiChannel },
                    set: { vm.setChannel($0) }
                )) {
                    Text("Omni").tag(0)
                    ForEach(1...16, id: \.self) { Text("\($0)").tag($0) }
                }
                ForEach(ControlTarget.allCases) { t in
                    HStack {
                        Text(t.name)
                        Spacer()
                        Text(vm.ccLabel(t))
                            .font(.caption.monospaced())
                            .foregroundStyle(vm.snap.learnTarget == t ? Color.cyan : Color.secondary)
                        Button(vm.snap.learnTarget == t ? "Cancel" : "Learn") { vm.learn(t) }
                            .buttonStyle(.bordered)
                        if vm.snap.performance.ccMap[t.rawValue] != nil {
                            Button { vm.clearMapping(t) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Clear \(t.name) mapping")
                        }
                    }
                }
                Toggle("Program Change 0–7 recalls favorites", isOn: Binding(
                    get: { g.programChangeRecallsFavorites },
                    set: { v in vm.updateGlobal { $0.programChangeRecallsFavorites = v } }
                ))
                LabeledContent("Last MIDI", value: vm.snap.lastMIDI.isEmpty ? "—" : vm.snap.lastMIDI)
                if vm.snap.droppedMIDI > 0 {
                    LabeledContent("Dropped MIDI", value: "\(vm.snap.droppedMIDI)")
                }
            } header: {
                Text("MIDI")
            } footer: {
                Text(vm.snap.isPlugin
                     ? "No CCs are assigned by default. In Loopy you can also bind widgets straight to the plugin's parameters (Pattern, Speed, Brightness…) and skip CCs entirely."
                     : "MIDI is received by the plugin inside Loopy. Mappings are saved per plugin instance.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Boundary hysteresis: \(vm.snap.performance.hysteresis, specifier: "%.2f")")
                    Slider(value: Binding(get: { vm.snap.performance.hysteresis }, set: { vm.setHysteresis($0) }),
                           in: 0...0.45)
                }
                Toggle("Invert speed", isOn: Binding(
                    get: { g.invertSpeed },
                    set: { v in vm.updateGlobal { $0.invertSpeed = v } }
                ))
            } header: {
                Text("Pattern browsing")
            } footer: {
                Text("Hysteresis stops the pattern flickering when X rests on a boundary. Invert speed if higher values turn out to be slower on the lights.")
            }

            Section {
                Stepper("Send tick: \(g.intervalMs) ms", value: Binding(
                    get: { g.intervalMs },
                    set: { v in vm.updateGlobal { $0.intervalMs = v } }
                ), in: 20...200, step: 10)
                Picker("Filler bytes", selection: Binding(
                    get: { g.filler },
                    set: { v in vm.updateGlobal { $0.filler = v } }
                )) {
                    Text("Random (like iStrip)").tag(FillerMode.random)
                    Text("Zero").tag(FillerMode.zero)
                }
                Picker("Palette write length", selection: Binding(
                    get: { g.paletteLength },
                    set: { v in vm.updateGlobal { $0.paletteLength = v } }
                )) {
                    Text("100 bytes (as captured)").tag(100)
                    Text("23 bytes").tag(23)
                }
            } header: {
                Text("Protocol")
            } footer: {
                Text("Only the newest state is ever sent, once per tick. Raise the tick if the lights miss commands.")
            }
        }
        .navigationTitle("LightPilot Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }
}
