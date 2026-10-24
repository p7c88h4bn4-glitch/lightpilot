import SwiftUI

struct LightsView: View {
    @ObservedObject var host: AppHost
    @ObservedObject var vm: LightViewModel
    @State private var showAll = false

    private var devices: [DeviceRef] { vm.snap.global.devices }

    private func status(_ name: String) -> LightStatus? {
        vm.snap.statuses.first { $0.name == name }
    }

    private var nearby: [DiscoveredDevice] {
        host.discovered.filter { d in
            !devices.contains(where: { $0.name == d.name }) &&
            (showAll || d.advertisesService || d.name.uppercased().hasPrefix("ISP"))
        }
    }

    var body: some View {
        List {
            Section {
                if devices.isEmpty {
                    Text("None yet — scan below and add up to two.").foregroundStyle(.secondary)
                }
                ForEach(devices) { d in
                    let st = status(d.name)
                    HStack {
                        Circle().fill((st?.phase ?? .notFound).tint).frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text(d.name).font(.headline)
                            Text(st?.phaseLabel ?? "Not connected from the app")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("Send", isOn: Binding(
                            get: { d.enabled },
                            set: { host.setEnabled(d.name, $0) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Send to \(d.name)")
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) { host.removeDevice(d.name) }
                    }
                }
            } header: {
                Text("Your lights")
            } footer: {
                Text("Both lights get the same settings. Turn one off here to test it alone. Swipe to remove. Devices are remembered by their Bluetooth identifier, not just the name.")
            }

            Section {
                LabeledContent("Bluetooth path", value: vm.snap.global.transport.label)
                if vm.snap.global.transport == .direct {
                    Toggle("Connect from this app (testing)", isOn: $host.appConnectOverride)
                    Text("In Direct mode the plugin owns the lights. Turn this on only for Diagnostics; adding the plugin in Loopy turns it off automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Bridge mode: this app holds the connections and relays the plugin. Keep it open next to Loopy (Stage Manager or Split View); iOS may suspend it if it's fully in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Who connects") }

            Section {
                Button(host.scanning ? "Stop scanning" : "Scan for lights") {
                    host.scanning ? host.stopScan() : host.startScan()
                }
                Toggle("Show all Bluetooth devices", isOn: $showAll)
                ForEach(nearby) { d in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d.name)
                            Text("RSSI \(d.rssi)\(d.advertisesService ? " · FFF0" : "")")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Add") { host.addDevice(d) }
                            .buttonStyle(.borderedProminent)
                            .disabled(devices.count >= 2)
                    }
                }
            } header: { Text("Nearby") }
        }
        .navigationTitle("Lights")
        .onDisappear { if host.scanning { host.stopScan() } }
    }
}
