import SwiftUI

/// Optional on-screen XY: X browses patterns (discrete), Y sets speed.
/// Releasing keeps the last pattern and speed (nothing snaps back).
struct XYPadView: View {
    @ObservedObject var vm: LightViewModel

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let h = max(1, geo.size.height)
            let count = IStrip.modes.count
            let maxIndex = Double(count - 1)
            let x = CGFloat(vm.snap.position / maxIndex) * w
            let y = (1 - CGFloat(Double(vm.state.speed) / 100)) * h
            let sglsEdge = CGFloat(Double(IStrip.modes.filter { $0.bank == .sgls }.count) - 0.5) / CGFloat(maxIndex) * w

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12).fill(Theme.panel)

                // Bank divider between SGLS (left) and MULT (right)
                Rectangle()
                    .fill(Color.cyan.opacity(0.25))
                    .frame(width: 1, height: h)
                    .offset(x: sglsEdge)

                Text("MONO").font(.caption2.monospaced()).foregroundStyle(Theme.dim).padding(6)
                Text("COLOR").font(.caption2.monospaced()).foregroundStyle(Theme.dim)
                    .padding(6)
                    .offset(x: sglsEdge)
                Text("SPEED ↑").font(.caption2.monospaced()).foregroundStyle(Theme.dim)
                    .padding(6)
                    .frame(width: w, height: h, alignment: .bottomTrailing)

                Circle()
                    .fill(Color.cyan)
                    .frame(width: 22, height: 22)
                    .shadow(color: .cyan, radius: 8)
                    .position(x: min(max(x, 11), w - 11), y: min(max(y, 11), h - 11))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let nx = Double(min(max(g.location.x / w, 0), 1))
                        let ny = Double(min(max(g.location.y / h, 0), 1))
                        vm.set(.pattern, nx * maxIndex)
                        vm.set(.speed, (1 - ny) * 100)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Pattern and speed pad")
            .accessibilityValue("\(vm.mode.name), speed \(vm.state.speed)")
        }
    }
}
