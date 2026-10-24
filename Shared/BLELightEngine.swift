import Foundation
import CoreBluetooth

/// Anything that can take the latest desired light state.
protocol LightSink: AnyObject {
    /// Thread-safe. Only the most recent state matters; older ones are discarded.
    func submit(_ state: LightState)
    func addStatusListener(_ listener: @escaping ([LightStatus]) -> Void)
    func reloadSettings()
    func start()
    func stop()
}

/// Owns CoreBluetooth for up to two iStrip lights.
///
/// Sending model: "latest state wins". Callers overwrite `desired`; a timer on the BLE queue
/// diffs desired vs. what each light last received and sends only what changed. Nothing is
/// queued, so fast XY gestures can never build a backlog.
final class BLELightEngine: NSObject, LightSink {

    enum Role { case app, plugin }

    final class Link {
        let name: String
        var peripheral: CBPeripheral?
        var command: CBCharacteristic?
        var notify: CBCharacteristic?
        var palette: CBCharacteristic?
        var characteristics: [CBCharacteristic] = []
        var phase: LightStatus.Phase = .notFound
        var sent: LightState?
        var sentCount = 0
        var ackCount = 0
        var lastAck = ""
        var lastWriteTime: CFAbsoluteTime = 0
        var lastLatencyMs = 0
        init(name: String) { self.name = name }
    }

    let role: Role
    let queue = DispatchQueue(label: "com.mrbradsmusic.lightpilot.ble", qos: .userInitiated)

    private var central: CBCentralManager?
    private var settings: GlobalSettings
    private var links: [String: Link] = [:]
    private var desired: LightState?
    private var timer: DispatchSourceTimer?
    private var timerInterval = 0
    private var statusListeners: [([LightStatus]) -> Void] = []
    private var logListeners: [(String) -> Void] = []
    private var discoveryListeners: [([DiscoveredDevice]) -> Void] = []
    private var discovered: [UUID: DiscoveredDevice] = [:]
    private var userScanning = false
    private var statusDirty = true
    private var lastStatusPublish: CFAbsoluteTime = 0
    private var running = false

    /// When false the engine stays disconnected (used by the app while the plugin owns Bluetooth).
    private var wantsConnections: Bool

    init(role: Role, wantsConnections: Bool) {
        self.role = role
        self.wantsConnections = wantsConnections
        self.settings = SharedStore.shared.loadGlobal()
        super.init()
    }

    // MARK: LightSink

    func submit(_ state: LightState) {
        queue.async {
            self.desired = state.clamped()
        }
    }

    func addStatusListener(_ listener: @escaping ([LightStatus]) -> Void) {
        queue.async {
            self.statusListeners.append(listener)
            self.statusDirty = true
        }
    }

    func addLogListener(_ listener: @escaping (String) -> Void) {
        queue.async { self.logListeners.append(listener) }
    }

    func addDiscoveryListener(_ listener: @escaping ([DiscoveredDevice]) -> Void) {
        queue.async { self.discoveryListeners.append(listener) }
    }

    func reloadSettings() {
        queue.async {
            let old = self.settings
            self.settings = SharedStore.shared.loadGlobal()
            if old.paletteCharacteristic != self.settings.paletteCharacteristic {
                for link in self.links.values {
                    self.assignPalette(link)
                    link.sent = nil      // resend so MULT palettes reach the newly chosen characteristic
                }
            }
            if old.intervalMs != self.settings.intervalMs { self.restartTimer() }
            if old.devices != self.settings.devices { self.syncLinks() }
            self.statusDirty = true
        }
    }

    func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            if self.central == nil {
                self.central = CBCentralManager(delegate: self, queue: self.queue,
                                                options: [CBCentralManagerOptionShowPowerAlertKey: false])
            }
            self.restartTimer()
            self.syncLinks()
        }
    }

    func stop() {
        queue.async {
            self.running = false
            self.timer?.cancel()
            self.timer = nil
            self.disconnectAll()
            self.central?.stopScan()
        }
    }

    // MARK: Connection policy

    func setWantsConnections(_ wants: Bool) {
        queue.async {
            guard self.wantsConnections != wants else { return }
            self.wantsConnections = wants
            self.log(wants ? "Bluetooth: connecting enabled" : "Bluetooth: released")
            if wants { self.syncLinks() } else { self.disconnectAll() }
            self.statusDirty = true
        }
    }

    private func disconnectAll() {
        for link in links.values {
            if let p = link.peripheral { central?.cancelPeripheralConnection(p) }
            link.phase = .disconnected
            link.sent = nil
        }
        statusDirty = true
    }

    private func identifierForRole(_ ref: DeviceRef) -> UUID? {
        role == .app ? ref.appIdentifier : ref.auIdentifier
    }

    /// Make `links` match the saved device list and connect what we can.
    private func syncLinks() {
        let names = Set(settings.devices.map { $0.name })
        for (name, link) in links where !names.contains(name) {
            if let p = link.peripheral { central?.cancelPeripheralConnection(p) }
            links[name] = nil
        }
        for ref in settings.devices where links[ref.name] == nil {
            links[ref.name] = Link(name: ref.name)
        }
        statusDirty = true
        guard wantsConnections, running, let central = central, central.state == .poweredOn else { return }

        var needScan = false
        for ref in settings.devices {
            guard let link = links[ref.name] else { continue }
            if link.peripheral == nil, let id = identifierForRole(ref),
               let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                link.peripheral = p
            }
            guard let p = link.peripheral else { needScan = true; continue }
            if p.state == .disconnected {
                p.delegate = self
                link.phase = .connecting
                central.connect(p, options: nil)
                log("Connecting \(ref.name)")
            }
        }
        updateScan(needSaved: needScan)
    }

    private func updateScan(needSaved: Bool) {
        guard let central = central, central.state == .poweredOn else { return }
        let should = userScanning || (needSaved && wantsConnections)
        if should && !central.isScanning {
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        } else if !should && central.isScanning {
            central.stopScan()
        }
    }

    // MARK: Discovery (Lights tab)

    func startDiscovery() {
        queue.async {
            self.userScanning = true
            self.discovered = [:]
            self.publishDiscovery()
            self.updateScan(needSaved: false)
        }
    }

    func stopDiscovery() {
        queue.async {
            self.userScanning = false
            self.updateScan(needSaved: self.links.values.contains { $0.peripheral == nil })
        }
    }

    private func publishDiscovery() {
        let list = discovered.values.sorted { $0.rssi > $1.rssi }
        discoveryListeners.forEach { $0(list) }
    }

    // MARK: Sending

    private func restartTimer() {
        timer?.cancel()
        let ms = max(15, min(500, settings.intervalMs))
        timerInterval = ms
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms), leeway: .milliseconds(3))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if let d = desired {
            for ref in settings.devices where ref.enabled {
                guard let link = links[ref.name], link.phase == .ready else { continue }
                step(link, toward: d)
            }
        }
        let now = CFAbsoluteTimeGetCurrent()
        if statusDirty && now - lastStatusPublish > 0.2 {
            publishStatus()
        } else if now - lastStatusPublish > 1.0 {
            publishStatus()     // heartbeat (bridge uses it to detect a live app)
        }
    }

    /// Send whatever differs between what the light last received and `d`.
    /// Order follows the capture: TURN, then the pattern command, then (MULT) the palette.
    private func step(_ link: Link, toward d: LightState) {
        guard let p = link.peripheral, let cmd = link.command else { return }
        if !p.canSendWriteWithoutResponse { return }   // peripheralIsReady will call tick again
        let s = link.sent
        let filler = IStrip.filler(settings.filler)
        let invert = settings.invertSpeed
        var wrote = false

        if s == nil || s!.power != d.power {
            write(link, cmd, IStrip.turn(d.power, filler: filler), encrypted: true)
            wrote = true
        }

        if d.power {
            let newPattern = IStrip.patternMeaningful(d, invertSpeed: invert)
            let oldPattern = s.map { IStrip.patternMeaningful($0, invertSpeed: invert) }
            let patternChanged = (oldPattern != newPattern) || (s?.power == false)
            if patternChanged {
                write(link, cmd, IStrip.pad(newPattern, filler: filler), encrypted: true)
                wrote = true
            }
            if let pal = IStrip.paletteFor(d) {
                let oldPal = s.flatMap { IStrip.paletteFor($0) }
                let modeChanged = s?.patternIndex != d.patternIndex
                if pal != oldPal || modeChanged {
                    if let palChar = link.palette {
                        var bytes = pal
                        let total = max(bytes.count, min(512, settings.paletteLength))
                        bytes += [UInt8](repeating: 0, count: total - bytes.count)
                        writeRaw(link, palChar, Data(bytes), label: "PALETTE \(Array(pal.prefix(23)).hexString)")
                        wrote = true
                    } else {
                        log("\(link.name): no palette characteristic selected — MULT palette skipped")
                    }
                }
            }
        }

        // Record the target even if a part was skipped (e.g. no palette characteristic yet),
        // so a missing piece is logged once per change instead of every tick.
        if wrote || s != d {
            link.sent = d
            statusDirty = true
        }
    }

    private func write(_ link: Link, _ ch: CBCharacteristic, _ plain: [UInt8], encrypted: Bool) {
        guard let data = IStrip.encrypt(plain) else {
            log("AES failed for \(plain.hexString)")
            return
        }
        writeRaw(link, ch, data, label: IStrip.describe(plain))
    }

    private func writeRaw(_ link: Link, _ ch: CBCharacteristic, _ data: Data, label: String) {
        guard let p = link.peripheral else { return }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.writeValue(data, for: ch, type: type)
        link.sentCount += 1
        link.lastWriteTime = CFAbsoluteTimeGetCurrent()
        log("→ \(link.name) \(label)")
    }

    // MARK: Diagnostics API (app only)

    /// Send exact bytes to the command characteristic of every enabled ready light (or one).
    func sendFixture(hex: String, to name: String?) {
        queue.async {
            guard let bytes = [UInt8](hex: hex), bytes.count == 16 else { self.log("Bad fixture"); return }
            let plain = IStrip.decrypt(bytes) ?? []
            for link in self.targets(name) {
                guard let c = link.command else { continue }
                self.writeRaw(link, c, Data(bytes), label: "FIXTURE \(IStrip.describe(plain))")
                self.holdAutomaticSend(link)
            }
        }
    }

    func sendPlain(_ plain: [UInt8], to name: String?) {
        queue.async {
            for link in self.targets(name) {
                guard let c = link.command else { continue }
                self.write(link, c, plain, encrypted: true)
                self.holdAutomaticSend(link)
            }
        }
    }

    func sendPalette(_ data: Data, to name: String?) {
        queue.async {
            for link in self.targets(name) {
                guard let c = link.palette else { self.log("\(link.name): no palette characteristic"); continue }
                self.writeRaw(link, c, data, label: "PALETTE(\(data.count)) \(Array(data.prefix(23)).hexString)")
            }
        }
    }

    /// After a manual diagnostic write, mark the light as already matching `desired` so the
    /// automatic sender doesn't immediately overwrite the test. The next real control change
    /// (or "Resend current state") sends normally again.
    private func holdAutomaticSend(_ link: Link) {
        link.sent = desired
    }

    /// Forget what each light received so the next tick resends the whole desired state.
    func forceResend() {
        queue.async { self.links.values.forEach { $0.sent = nil } }
    }

    private func targets(_ name: String?) -> [Link] {
        links.values.filter { ($0.phase == .ready) && (name == nil || $0.name == name) }
    }

    // MARK: Status

    private func publishStatus() {
        lastStatusPublish = CFAbsoluteTimeGetCurrent()
        statusDirty = false
        let btPhase: LightStatus.Phase? = {
            guard let c = central else { return nil }
            switch c.state {
            case .poweredOff: return .bluetoothOff
            case .unauthorized: return .unauthorized
            default: return nil
            }
        }()
        let list: [LightStatus] = settings.devices.map { ref in
            let link = links[ref.name]
            var st = LightStatus(name: ref.name, phase: btPhase ?? link?.phase ?? .notFound)
            st.enabled = ref.enabled
            st.sent = link?.sentCount ?? 0
            st.acks = link?.ackCount ?? 0
            st.lastAck = link?.lastAck ?? ""
            st.lastLatencyMs = link?.lastLatencyMs ?? 0
            st.hasPaletteCharacteristic = link?.palette != nil
            st.characteristics = (link?.characteristics ?? []).map {
                CharacteristicInfo(uuid: $0.uuid.uuidString, properties: Self.describe($0.properties))
            }
            return st
        }
        statusListeners.forEach { $0(list) }
    }

    private static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoResp") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }

    private func log(_ text: String) {
        guard !logListeners.isEmpty else { return }
        logListeners.forEach { $0(text) }
    }

    private func assignPalette(_ link: Link) {
        let target = CBUUID(string: settings.paletteCharacteristic)
        link.palette = link.characteristics.first { $0.uuid == target }
    }

    private func link(for p: CBPeripheral) -> Link? {
        links.values.first { $0.peripheral?.identifier == p.identifier }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLELightEngine: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Bluetooth state: \(central.state.rawValue)")
        statusDirty = true
        if central.state == .poweredOn {
            syncLinks()
            if userScanning { updateScan(needSaved: false) }
        } else {
            for link in links.values {
                link.phase = .disconnected
                link.sent = nil
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        if userScanning, !name.isEmpty {
            discovered[peripheral.identifier] = DiscoveredDevice(identifier: peripheral.identifier, name: name,
                                                                 rssi: RSSI.intValue,
                                                                 advertisesService: services.contains(IStrip.serviceUUID))
            publishDiscovery()
        }
        // Saved light found by name (first run in this process, or identifiers differ per process).
        guard wantsConnections, let link = links[name], link.peripheral == nil else { return }
        link.peripheral = peripheral
        peripheral.delegate = self
        link.phase = .connecting
        central.connect(peripheral, options: nil)
        log("Found \(name) — connecting")
        let role = self.role
        settings = SharedStore.shared.updateGlobal { g in
            if let i = g.devices.firstIndex(where: { $0.name == name }) {
                if role == .app { g.devices[i].appIdentifier = peripheral.identifier }
                else { g.devices[i].auIdentifier = peripheral.identifier }
            }
        }
        if !links.values.contains(where: { $0.peripheral == nil }) { updateScan(needSaved: false) }
        statusDirty = true
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let link = link(for: peripheral) else { return }
        link.phase = .discovering
        link.sent = nil
        statusDirty = true
        log("Connected \(link.name) — discovering")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let link = link(for: peripheral) else { return }
        link.phase = .disconnected
        statusDirty = true
        log("Connect failed \(link.name): \(error?.localizedDescription ?? "unknown")")
        if wantsConnections && running { central.connect(peripheral, options: nil) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let link = link(for: peripheral) else { return }
        link.phase = .disconnected
        link.command = nil
        link.notify = nil
        link.palette = nil
        link.sent = nil
        statusDirty = true
        log("Disconnected \(link.name)\(error.map { ": \($0.localizedDescription)" } ?? "")")
        if wantsConnections && running {
            link.phase = .connecting
            central.connect(peripheral, options: nil)   // iOS keeps this pending until the light returns
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLELightEngine: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let link = link(for: peripheral) else { return }
        link.characteristics = []
        for s in peripheral.services ?? [] {
            log("\(link.name) service \(s.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let link = link(for: peripheral) else { return }
        for c in service.characteristics ?? [] {
            if !link.characteristics.contains(where: { $0.uuid == c.uuid }) { link.characteristics.append(c) }
            log("  \(c.uuid.uuidString) [\(Self.describe(c.properties))]")
            if c.uuid == IStrip.commandUUID { link.command = c }
            if c.uuid == IStrip.notifyUUID {
                link.notify = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        assignPalette(link)
        if link.command != nil && link.phase != .ready {
            link.phase = .ready
            link.sent = nil
            log("\(link.name) ready\(link.palette == nil ? " (palette characteristic not found yet)" : "")")
        }
        statusDirty = true
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let link = link(for: peripheral), let data = characteristic.value else { return }
        let bytes = data.bytes
        var text = bytes.hexString
        if bytes.count % 16 == 0, let plain = IStrip.decrypt(bytes) {
            text = "\(plain.printableASCII)  [\(plain.hexString)]"
        }
        link.ackCount += 1
        link.lastAck = text
        if link.lastWriteTime > 0 {
            link.lastLatencyMs = Int((CFAbsoluteTimeGetCurrent() - link.lastWriteTime) * 1000)
        }
        statusDirty = true
        log("← \(link.name) \(text)")
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let link = link(for: peripheral), let d = desired, link.phase == .ready else { return }
        if settings.devices.first(where: { $0.name == link.name })?.enabled == true {
            step(link, toward: d)
        }
    }
}
