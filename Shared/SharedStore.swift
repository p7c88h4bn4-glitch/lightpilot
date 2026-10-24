import Foundation

enum AppGroup {
    static let id = "group.com.mrbradsmusic.LightPilot"
}

/// Small JSON files in the App Group container. Files (not UserDefaults) so the app and the
/// plugin process always read the latest bytes without preference-cache lag.
final class SharedStore {
    static let shared = SharedStore()

    let directory: URL
    private let lock = NSLock()

    private init() {
        let fm = FileManager.default
        if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) {
            directory = url.appendingPathComponent("LightPilot", isDirectory: true)
        } else {
            directory = fm.temporaryDirectory.appendingPathComponent("LightPilot", isDirectory: true)
        }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var hasAppGroup: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) != nil
    }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Named records

    static let globalFile = "global.json"
    static let favoritesFile = "favorites.json"
    static let appInstanceFile = "app-instance.json"
    static let bridgeStateFile = "bridge-state.json"
    static let bridgeStatusFile = "bridge-status.json"

    func loadGlobal() -> GlobalSettings {
        load(GlobalSettings.self, Self.globalFile) ?? GlobalSettings()
    }

    func saveGlobal(_ g: GlobalSettings) {
        save(g, Self.globalFile)
        DarwinCenter.shared.post(.settings)
    }

    /// Read-modify-write helper.
    func updateGlobal(_ change: (inout GlobalSettings) -> Void) -> GlobalSettings {
        var g = loadGlobal()
        change(&g)
        saveGlobal(g)
        return g
    }

    func loadFavorites() -> [LightState?] {
        let f = load([LightState?].self, Self.favoritesFile) ?? []
        return (0..<Favorites.slotCount).map { $0 < f.count ? f[$0] : nil }
    }

    func saveFavorites(_ f: [LightState?]) {
        save(f, Self.favoritesFile)
        DarwinCenter.shared.post(.settings)
    }
}

// MARK: - Darwin notifications (cross-process pings; payloads live in the files above)

enum DarwinName: String, CaseIterable {
    case settings = "com.mrbradsmusic.LightPilot.settings"
    case bridgeState = "com.mrbradsmusic.LightPilot.bridge.state"
    case bridgeStatus = "com.mrbradsmusic.LightPilot.bridge.status"
    case releaseBluetooth = "com.mrbradsmusic.LightPilot.releaseBluetooth"
}

final class DarwinCenter {
    static let shared = DarwinCenter()

    private let lock = NSLock()
    private var handlers: [String: [UUID: () -> Void]] = [:]
    private var registered: Set<String> = []

    private init() {}

    @discardableResult
    func observe(_ name: DarwinName, _ handler: @escaping () -> Void) -> UUID {
        let token = UUID()
        lock.lock()
        handlers[name.rawValue, default: [:]][token] = handler
        let needsRegister = !registered.contains(name.rawValue)
        if needsRegister { registered.insert(name.rawValue) }
        lock.unlock()

        if needsRegister {
            let center = CFNotificationCenterGetDarwinNotifyCenter()
            let observer = Unmanaged.passUnretained(self).toOpaque()
            CFNotificationCenterAddObserver(center, observer, { _, observer, cfName, _, _ in
                guard let observer = observer, let cfName = cfName else { return }
                let me = Unmanaged<DarwinCenter>.fromOpaque(observer).takeUnretainedValue()
                me.fire(cfName.rawValue as String)
            }, name.rawValue as CFString, nil, .deliverImmediately)
        }
        return token
    }

    func remove(_ name: DarwinName, _ token: UUID) {
        lock.lock()
        handlers[name.rawValue]?[token] = nil
        lock.unlock()
    }

    func post(_ name: DarwinName) {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(name.rawValue as CFString), nil, nil, true)
    }

    private func fire(_ name: String) {
        lock.lock()
        let list = Array((handlers[name] ?? [:]).values)
        lock.unlock()
        list.forEach { $0() }
    }
}
