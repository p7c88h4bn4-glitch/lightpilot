import Foundation

// MARK: - Color

struct RGB: Codable, Equatable, Hashable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }

    static let black = RGB(0, 0, 0)

    var bytes: [UInt8] { [r, g, b] }

    /// Scale by a 0...100 brightness percentage (hue preserved).
    func scaled(_ percent: Int) -> RGB {
        let p = max(0, min(100, percent))
        func s(_ v: UInt8) -> UInt8 { UInt8((Int(v) * p + 50) / 100) }
        return RGB(s(r), s(g), s(b))
    }

    /// h: 0...360, s: 0...1, v: 0...1
    static func hsv(_ h: Double, _ s: Double, _ v: Double = 1) -> RGB {
        let hh = (h.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 60
        let sat = max(0, min(1, s))
        let val = max(0, min(1, v))
        let c = val * sat
        let x = c * (1 - abs(hh.truncatingRemainder(dividingBy: 2) - 1))
        let m = val - c
        var rgb: (Double, Double, Double)
        switch Int(hh) {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        func u(_ d: Double) -> UInt8 { UInt8(max(0, min(255, ((d + m) * 255).rounded()))) }
        return RGB(u(rgb.0), u(rgb.1), u(rgb.2))
    }
}

// MARK: - Palettes

struct Palette: Equatable {
    let name: String
    let colors: [RGB]   // always 7
}

enum PaletteLibrary {
    /// Full-brightness palette observed in the capture: red, orange, yellow, green, blue, magenta, white.
    static let captured: [RGB] = [
        RGB(0xFF, 0x00, 0x00), RGB(0xFF, 0xA2, 0x00), RGB(0xFF, 0xFF, 0x00), RGB(0x00, 0xFF, 0x00),
        RGB(0x00, 0x00, 0xFF), RGB(0xFF, 0x00, 0xFF), RGB(0xFF, 0xFF, 0xFF)
    ]

    static let builtIn: [Palette] = [
        Palette(name: "Captured Rainbow", colors: captured),
        Palette(name: "Fire", colors: [RGB(255, 0, 0), RGB(255, 40, 0), RGB(255, 90, 0), RGB(255, 150, 0), RGB(255, 200, 20), RGB(255, 60, 0), RGB(200, 0, 0)]),
        Palette(name: "Ocean", colors: [RGB(0, 0, 255), RGB(0, 80, 255), RGB(0, 160, 255), RGB(0, 255, 220), RGB(0, 255, 120), RGB(0, 40, 160), RGB(120, 200, 255)]),
        Palette(name: "Forest", colors: [RGB(0, 255, 0), RGB(60, 200, 0), RGB(0, 160, 40), RGB(150, 255, 0), RGB(0, 255, 120), RGB(30, 120, 0), RGB(200, 255, 80)]),
        Palette(name: "Candy", colors: [RGB(255, 0, 140), RGB(255, 100, 200), RGB(170, 0, 255), RGB(0, 200, 255), RGB(255, 255, 255), RGB(255, 60, 100), RGB(120, 80, 255)]),
        Palette(name: "Sunset", colors: [RGB(255, 60, 0), RGB(255, 0, 80), RGB(180, 0, 160), RGB(80, 0, 255), RGB(255, 140, 0), RGB(255, 0, 0), RGB(255, 200, 100)]),
        Palette(name: "Ice", colors: [RGB(255, 255, 255), RGB(160, 220, 255), RGB(0, 120, 255), RGB(200, 240, 255), RGB(0, 200, 255), RGB(255, 255, 255), RGB(80, 80, 255)]),
        Palette(name: "Police", colors: [RGB(255, 0, 0), RGB(0, 0, 255), RGB(255, 0, 0), RGB(0, 0, 255), RGB(255, 255, 255), RGB(255, 0, 0), RGB(0, 0, 255)])
    ]

    /// Index == builtIn.count means "Custom".
    static var count: Int { builtIn.count + 1 }

    static func name(_ index: Int) -> String {
        index < builtIn.count ? builtIn[max(0, index)].name : "Custom"
    }
}

// MARK: - Light state (what we want the lights to show)

struct LightState: Codable, Equatable {
    var power: Bool = true
    var patternIndex: Int = 0          // 0...24 browse index into IStrip.modes
    var speed: Int = 80                // 0...100 as the user sees it
    var brightness: Int = 100          // 0...100
    var hueA: Double = 0               // 0...360
    var hueB: Double = 240             // 0...360
    var saturation: Double = 100       // 0...100
    var paletteIndex: Int = 0          // 0...PaletteLibrary.count-1
    var customPalette: [RGB] = PaletteLibrary.captured

    var colorA: RGB { RGB.hsv(hueA, saturation / 100) }
    var colorB: RGB { RGB.hsv(hueB, saturation / 100) }

    var palette: [RGB] {
        if paletteIndex >= 0 && paletteIndex < PaletteLibrary.builtIn.count {
            return PaletteLibrary.builtIn[paletteIndex].colors
        }
        return customPalette.count == 7 ? customPalette : PaletteLibrary.captured
    }

    var mode: IStrip.Mode { IStrip.modes[max(0, min(IStrip.modes.count - 1, patternIndex))] }

    func clamped() -> LightState {
        var s = self
        s.patternIndex = max(0, min(IStrip.modes.count - 1, s.patternIndex))
        s.speed = max(0, min(100, s.speed))
        s.brightness = max(0, min(100, s.brightness))
        s.hueA = max(0, min(360, s.hueA))
        s.hueB = max(0, min(360, s.hueB))
        s.saturation = max(0, min(100, s.saturation))
        s.paletteIndex = max(0, min(PaletteLibrary.count - 1, s.paletteIndex))
        if s.customPalette.count != 7 { s.customPalette = PaletteLibrary.captured }
        return s
    }
}

// MARK: - Controls (AU parameters + MIDI learn targets share these addresses)

enum ControlTarget: Int, CaseIterable, Codable, Identifiable {
    case power = 0
    case pattern = 1
    case speed = 2
    case brightness = 3
    case hueA = 4
    case hueB = 5
    case saturation = 6
    case palette = 7
    case favorite = 8

    var id: Int { rawValue }

    var name: String {
        switch self {
        case .power: return "Power"
        case .pattern: return "Pattern"
        case .speed: return "Speed"
        case .brightness: return "Brightness"
        case .hueA: return "Color A Hue"
        case .hueB: return "Color B Hue"
        case .saturation: return "Saturation"
        case .palette: return "Palette"
        case .favorite: return "Favorite"
        }
    }

    var identifier: String {
        switch self {
        case .power: return "power"
        case .pattern: return "pattern"
        case .speed: return "speed"
        case .brightness: return "brightness"
        case .hueA: return "hueA"
        case .hueB: return "hueB"
        case .saturation: return "saturation"
        case .palette: return "palette"
        case .favorite: return "favorite"
        }
    }

    var range: ClosedRange<Double> {
        switch self {
        case .power: return 0...1
        case .pattern: return 0...Double(IStrip.modes.count - 1)
        case .speed, .brightness, .saturation: return 0...100
        case .hueA, .hueB: return 0...360
        case .palette: return 0...Double(PaletteLibrary.count - 1)
        case .favorite: return 0...Double(Favorites.slotCount)
        }
    }

    /// Value from a 0...127 MIDI CC.
    func value(fromCC cc: UInt8) -> Double {
        if self == .power { return cc >= 64 ? 1 : 0 }
        let n = Double(min(cc, 127)) / 127.0
        let v = range.lowerBound + (range.upperBound - range.lowerBound) * n
        switch self {
        case .palette, .favorite: return v.rounded()
        default: return v
        }
    }

    /// The parameter value that represents a given state.
    func value(in state: LightState) -> Double {
        switch self {
        case .power: return state.power ? 1 : 0
        case .pattern: return Double(state.patternIndex)
        case .speed: return Double(state.speed)
        case .brightness: return Double(state.brightness)
        case .hueA: return state.hueA
        case .hueB: return state.hueB
        case .saturation: return state.saturation
        case .palette: return Double(state.paletteIndex)
        case .favorite: return 0
        }
    }
}

// MARK: - Pattern browsing

enum PatternBrowser {
    /// Quantize a continuous position (0...count-1) to a pattern index with hysteresis.
    /// `hysteresis` is extra distance (0...0.45) the position must travel past the midpoint
    /// before the index changes. Endpoints always snap.
    static func quantize(position: Double, current: Int, count: Int, hysteresis: Double) -> Int {
        guard count > 0 else { return 0 }
        let top = Double(count - 1)
        let p = max(0, min(top, position))
        let nearest = Int(p.rounded())
        if nearest == current { return current }
        if p <= 0 || p >= top { return nearest }
        let h = max(0, min(0.45, hysteresis))
        if abs(p - Double(current)) > 0.5 + h { return nearest }
        return current
    }
}

// MARK: - Settings

enum Transport: String, Codable, CaseIterable, Identifiable {
    case direct      // Bluetooth from inside the AUv3
    case bridge      // AUv3 forwards state; the LightPilot app holds Bluetooth
    var id: String { rawValue }
    var label: String { self == .direct ? "Direct (plugin)" : "Via app bridge" }
}

enum FillerMode: String, Codable, CaseIterable, Identifiable {
    case random, zero
    var id: String { rawValue }
}

struct DeviceRef: Codable, Equatable, Identifiable {
    var name: String
    var appIdentifier: UUID?
    var auIdentifier: UUID?
    var enabled: Bool = true
    var id: String { name }
}

/// Process-wide settings shared by the app and every plugin instance (App Group file).
struct GlobalSettings: Codable, Equatable {
    var transport: Transport = .direct
    var devices: [DeviceRef] = []            // max 2
    var intervalMs: Int = 50                  // coalescing tick
    var filler: FillerMode = .random
    var invertSpeed: Bool = false
    var paletteCharacteristic: String = IStrip.paletteCandidateUUIDString
    var paletteLength: Int = 100              // 100 (as captured) or 23 (meaningful bytes only)
    var programChangeRecallsFavorites: Bool = false
}

/// Per-instance settings saved in the plugin's state (Loopy project).
struct PerformanceSettings: Codable, Equatable {
    var midiChannel: Int = 0                  // 0 = omni, 1...16
    var ccMap: [Int: Int] = [:]               // ControlTarget.rawValue -> CC number
    var hysteresis: Double = 0.15

    func target(forCC cc: Int) -> [ControlTarget] {
        ccMap.compactMap { $0.value == cc ? ControlTarget(rawValue: $0.key) : nil }
    }
}

struct InstanceState: Codable {
    var state: LightState
    var performance: PerformanceSettings
}

enum Favorites {
    static let slotCount = 8
}

// MARK: - Status

struct CharacteristicInfo: Codable, Equatable, Identifiable, Hashable {
    var uuid: String
    var properties: String
    var id: String { uuid }
}

struct LightStatus: Codable, Equatable, Identifiable {
    enum Phase: String, Codable {
        case notFound, disconnected, connecting, discovering, ready, bridgeOffline, bluetoothOff, unauthorized
    }
    var name: String
    var phase: Phase
    var enabled: Bool = true
    var sent: Int = 0
    var acks: Int = 0
    var lastAck: String = ""
    var lastLatencyMs: Int = 0
    var hasPaletteCharacteristic: Bool = false
    var characteristics: [CharacteristicInfo] = []
    var id: String { name }

    var phaseLabel: String {
        switch phase {
        case .notFound: return "Searching"
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting"
        case .discovering: return "Discovering"
        case .ready: return "Ready"
        case .bridgeOffline: return "App bridge offline"
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth not allowed"
        }
    }
}

struct DiscoveredDevice: Identifiable, Equatable {
    var identifier: UUID
    var name: String
    var rssi: Int
    var advertisesService: Bool
    var id: UUID { identifier }
}
