import SwiftUI
import UIKit

/// Compact performance panel used by both the app and the plugin window.
struct ControlPanelView: View {
    @ObservedObject var vm: LightViewModel
    var showsSettingsButton = true
    @State private var showSettings = false
    @AppStorage("lp.showXY") private var showXY = true

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                StatusStrip(vm: vm, onSettings: showsSettingsButton ? { showSettings = true } : nil)
                patternRow
                if showXY {
                    XYPadView(vm: vm)
                        .frame(height: 150)
                }
                LabeledSlider(title: "Speed", value: vm.binding(.speed), range: 0...100, format: "%.0f")
                LabeledSlider(title: "Brightness", value: vm.binding(.brightness), range: 0...100, format: "%.0f%%")
                colorSection
                favoritesRow
                Toggle("On-screen XY pad", isOn: $showXY)
                    .font(.caption)
                    .tint(.cyan)
            }
            .padding(12)
        }
        .background(Theme.background.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(vm: vm) }
                .preferredColorScheme(.dark)
        }
    }

    private var patternRow: some View {
        HStack(spacing: 8) {
            Button { vm.togglePower() } label: {
                Image(systemName: "power")
                    .font(.title3.weight(.bold))
                    .frame(width: 44, height: 44)
                    .background(vm.state.power ? Color.green.opacity(0.85) : Theme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel(vm.state.power ? "Turn lights off" : "Turn lights on")

            Button { vm.step(pattern: -1) } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 44)
            }
            VStack(spacing: 2) {
                Text(vm.mode.label)
                    .font(.system(.headline, design: .monospaced))
                Text(vm.mode.detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)
            Button { vm.step(pattern: 1) } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 44)
            }
        }
        .padding(6)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if vm.mode.bank == .sgls {
                HueSlider(title: "Color A", hue: vm.binding(.hueA), swatch: vm.state.colorA)
                HueSlider(title: "Color B", hue: vm.binding(.hueB), swatch: vm.state.colorB)
                LabeledSlider(title: "Saturation", value: vm.binding(.saturation), range: 0...100, format: "%.0f%%")
            } else {
                HStack {
                    Text("Palette").font(.caption).foregroundStyle(Theme.dim)
                    Spacer()
                    Menu {
                        ForEach(0..<PaletteLibrary.count, id: \.self) { i in
                            Button(PaletteLibrary.name(i)) { vm.set(.palette, Double(i)) }
                        }
                    } label: {
                        Text(PaletteLibrary.name(vm.state.paletteIndex))
                            .font(.subheadline.weight(.semibold))
                    }
                }
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { i in
                        if vm.state.paletteIndex == PaletteLibrary.builtIn.count {
                            ColorPicker("", selection: Binding(
                                get: { vm.state.customPalette[i].color },
                                set: { vm.setCustomColor(i, RGB(uiColor: UIColor($0))) }
                            ), supportsOpacity: false)
                            .labelsHidden()
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(vm.state.palette[i].color)
                                .frame(height: 22)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var favoritesRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Favorites — tap to recall, long-press to save")
                .font(.caption2)
                .foregroundStyle(Theme.dim)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(0..<Favorites.slotCount, id: \.self) { i in
                    let filled = i < vm.snap.favoritesFilled.count && vm.snap.favoritesFilled[i]
                    Text("\(i + 1)")
                        .font(.headline.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(filled ? Color.cyan.opacity(0.35) : Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(filled ? Color.cyan : Theme.dim.opacity(0.4)))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onTapGesture { if filled { vm.recall(i) } }
                        .onLongPressGesture { vm.save(i) }
                        .contextMenu {
                            Button("Save current here") { vm.save(i) }
                            if filled { Button("Clear", role: .destructive) { vm.clear(i) } }
                        }
                        .accessibilityLabel("Favorite \(i + 1)\(filled ? "" : ", empty")")
                }
            }
        }
    }
}

// MARK: - Pieces

enum Theme {
    static let background = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let panel = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let text = Color(white: 0.93)
    static let dim = Color(white: 0.55)
}

struct StatusStrip: View {
    @ObservedObject var vm: LightViewModel
    var onSettings: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if vm.snap.statuses.isEmpty {
                Text("No lights selected")
                    .font(.caption)
                    .foregroundStyle(Theme.dim)
            }
            ForEach(vm.snap.statuses) { st in
                HStack(spacing: 5) {
                    Circle().fill(st.phase.tint).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(st.name).font(.caption2.weight(.semibold))
                        Text(st.enabled ? st.phaseLabel : "Disabled").font(.caption2).foregroundStyle(Theme.dim)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.panel)
                .clipShape(Capsule())
            }
            Spacer(minLength: 0)
            Text(vm.snap.global.transport == .direct ? "DIRECT" : "BRIDGE")
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.dim)
            if let onSettings = onSettings {
                Button(action: onSettings) {
                    Image(systemName: "gearshape").font(.title3)
                }
                .accessibilityLabel("Settings")
            }
        }
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(Theme.dim).frame(width: 78, alignment: .leading)
            Slider(value: $value, in: range).tint(.cyan)
            Text(String(format: format, value))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct HueSlider: View {
    let title: String
    @Binding var hue: Double
    let swatch: RGB

    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(Theme.dim).frame(width: 78, alignment: .leading)
            ZStack {
                LinearGradient(colors: stride(from: 0.0, through: 360.0, by: 30.0).map {
                    Color(hue: $0 / 360, saturation: 1, brightness: 1)
                }, startPoint: .leading, endPoint: .trailing)
                .frame(height: 6)
                .clipShape(Capsule())
                Slider(value: $hue, in: 0...360).tint(.clear)
            }
            RoundedRectangle(cornerRadius: 4).fill(swatch.color).frame(width: 44, height: 20)
        }
    }
}

extension RGB {
    init(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        func u(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        self.init(u(r), u(g), u(b))
    }
}
