import SwiftUI

@main
struct LightPilotApp: App {
    @StateObject private var host = AppHost.shared

    var body: some Scene {
        WindowGroup {
            AppRootView(host: host, vm: host.vm)
                .preferredColorScheme(.dark)
        }
    }
}

struct AppRootView: View {
    @ObservedObject var host: AppHost
    @ObservedObject var vm: LightViewModel

    var body: some View {
        TabView {
            ControlPanelView(vm: vm, showsSettingsButton: false)
                .tabItem { Label("Perform", systemImage: "slider.horizontal.3") }
            NavigationStack { LightsView(host: host, vm: vm) }
                .tabItem { Label("Lights", systemImage: "lightbulb.2") }
            NavigationStack { DiagnosticsView(host: host, vm: vm) }
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            NavigationStack { SettingsView(vm: vm) }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(.cyan)
    }
}
