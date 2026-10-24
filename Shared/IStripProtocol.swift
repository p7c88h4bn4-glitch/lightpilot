import Foundation
import CoreBluetooth

/// iStrip Pro protocol — ONLY what was observed in the captures (see handoff notes).
///
/// Every control packet is one AES-128-ECB block. The decrypted layout is:
///   byte 0      = count of meaningful bytes that follow (TURN 5, MULT 9, SGLS 14, palette 22)
///   bytes 1-4   = ASCII command
///   then args, then filler up to 16 bytes.
/// The "byte 0 = meaningful length" reading is consistent with every captured packet
/// (it also explains why SGLS byte 15 and MULT bytes 10-15 vary). Filler content is
/// still unverified on hardware: random (as the vendor app appears to do) is the default.
enum IStrip {

    // MARK: Bluetooth endpoints (by UUID — never by ATT handle)

    static let serviceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    static let commandUUID = CBUUID(string: "D44BC439-ABFD-45A2-B575-925416129600")
    static let notifyUUID = CBUUID(string: "D44BC439-ABFD-45A2-B575-925416129601")
    /// Inferred mapping for captured palette handle 0x0009. Must be verified in Diagnostics.
    static let paletteCandidateUUIDString = "D44BC439-ABFD-45A2-B575-92541612960A"

    // MARK: Crypto

    static let key: [UInt8] = [0x32, 0x67, 0x2F, 0x79, 0x74, 0xAD, 0x43, 0x45,
                               0x1D, 0x9C, 0x6C, 0x89, 0x4A, 0x0E, 0x87, 0x64]

    static func encrypt(_ plain: [UInt8]) -> Data? {
        guard plain.count == 16, let c = AES128ECB.encrypt(plain, key: key) else { return nil }
        return Data(c)
    }

    static func decrypt(_ cipher: [UInt8]) -> [UInt8]? {
        AES128ECB.decrypt(cipher, key: key)
    }

    // MARK: Known-good fixtures (exact captured ciphertext)

    static let fixtureOff = "85779AAD396C16A275A579564443D576"   // replay-tested by Brad
    static let fixtureOn = "FC37A92625A66F7CC8E12AB9671D98AE"    // replay-tested by Brad

    // MARK: Mode catalog — 10 SGLS + 15 MULT, browse order from the capture table

    enum Bank: String, Codable {
        case sgls = "SGLS"
        case mult = "MULT"
    }

    struct Mode: Identifiable, Equatable {
        let browse: Int
        let bank: Bank
        let id: UInt8
        let name: String
        let fixture: String
        let capturedSpeed: UInt8
        let capturedA: RGB
        let capturedB: RGB

        var label: String { String(format: "%02d  %@", browse + 1, name) }
        var detail: String { "\(bank.rawValue) \(id)" }
    }

    static let modes: [Mode] = [
        Mode(browse:  0, bank: .sgls, id:  1, name: "Mono 02", fixture: "75DFB0C083121D4C501DCD120E72B8C2", capturedSpeed:  34, capturedA: RGB(0xF6, 0xF6, 0xF6), capturedB: RGB(0x00, 0x00, 0xFF)),
        Mode(browse:  1, bank: .sgls, id:  0, name: "Mono 01", fixture: "0599705AC6B073385620555843D9E010", capturedSpeed:  80, capturedA: RGB(0x00, 0x00, 0xFF), capturedB: RGB(0x00, 0x00, 0xFF)),
        Mode(browse:  2, bank: .sgls, id:  2, name: "Mono 03", fixture: "EF3B181B01F57932E1EF4521E12E63A4", capturedSpeed:  80, capturedA: RGB(0xFF, 0xFF, 0xFF), capturedB: RGB(0xFF, 0xFF, 0xFF)),
        Mode(browse:  3, bank: .sgls, id:  3, name: "Mono 04", fixture: "A20B0FFBCA55015835A76372247A6E25", capturedSpeed:  80, capturedA: RGB(0xFF, 0xAE, 0x15), capturedB: RGB(0x00, 0x00, 0x00)),
        Mode(browse:  4, bank: .sgls, id:  4, name: "Mono 05", fixture: "BB53D98D2CC4A55BDD6957528F3C3969", capturedSpeed:  68, capturedA: RGB(0xFF, 0x00, 0x00), capturedB: RGB(0x00, 0x00, 0x00)),
        Mode(browse:  5, bank: .sgls, id:  5, name: "Mono 06", fixture: "923FA8CD07A728E2AE46639D098CF87C", capturedSpeed:  80, capturedA: RGB(0xFF, 0xFF, 0xFF), capturedB: RGB(0x00, 0x00, 0xFF)),
        Mode(browse:  6, bank: .sgls, id:  6, name: "Mono 07", fixture: "B327280DAE871678BB3A5BBC318BF162", capturedSpeed:  80, capturedA: RGB(0x4D, 0x23, 0xFE), capturedB: RGB(0x00, 0xFF, 0x00)),
        Mode(browse:  7, bank: .sgls, id:  7, name: "Mono 08", fixture: "C2926C6A200B44CF97B7037EED710572", capturedSpeed:  80, capturedA: RGB(0xFF, 0xFF, 0x00), capturedB: RGB(0xFF, 0x00, 0xFF)),
        Mode(browse:  8, bank: .sgls, id:  8, name: "Mono 09", fixture: "94792779E00FBEA0F8AA5059F271F99A", capturedSpeed:  80, capturedA: RGB(0xFF, 0x00, 0x00), capturedB: RGB(0x00, 0xFF, 0x00)),
        Mode(browse:  9, bank: .sgls, id:  9, name: "Mono 10", fixture: "2BC05D4CF6FA93F2E008E1FC8C2C3009", capturedSpeed:  80, capturedA: RGB(0xFF, 0x00, 0x00), capturedB: RGB(0x00, 0x00, 0xFF)),
        Mode(browse: 10, bank: .mult, id:  0, name: "Color 01", fixture: "57DDB269245C1661FA6805797C15891F", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 11, bank: .mult, id:  1, name: "Color 02", fixture: "F473874511B783EB0045CEC494880154", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 12, bank: .mult, id:  2, name: "Color 03", fixture: "D7155718C7699479A500591D6FC7CC68", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 13, bank: .mult, id:  3, name: "Color 04", fixture: "9092CF35295780FB9B060C8D47B64488", capturedSpeed:  57, capturedA: .black, capturedB: .black),
        Mode(browse: 14, bank: .mult, id:  4, name: "Color 05", fixture: "4E877496327096110FFFB2EF6FFD86A3", capturedSpeed:  42, capturedA: .black, capturedB: .black),
        Mode(browse: 15, bank: .mult, id:  5, name: "Color 06", fixture: "E815298FB977A6054C69474AA792FCB1", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 16, bank: .mult, id:  6, name: "Color 07", fixture: "E76D351B8871CAFC26BB71BC1E6E7E9E", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 17, bank: .mult, id:  7, name: "Color 08", fixture: "70715CDB8695B3B71026493FF68A732C", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 18, bank: .mult, id:  8, name: "Color 09", fixture: "195BB6C04AC9EA1A1A7F9D20E7DEB259", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 19, bank: .mult, id:  9, name: "Color 10", fixture: "7106BD0495EEA83336EF635F12787E07", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 20, bank: .mult, id: 10, name: "Color 11", fixture: "2BD1A1D8427F09FCA3551E9902C4502B", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 21, bank: .mult, id: 11, name: "Color 12", fixture: "D2A90DC6E979ED6B8CFF916F8066A32E", capturedSpeed:  46, capturedA: .black, capturedB: .black),
        Mode(browse: 22, bank: .mult, id: 12, name: "Color 13", fixture: "770D3BF318B7730A9E254989FBF71996", capturedSpeed:  80, capturedA: .black, capturedB: .black),
        Mode(browse: 23, bank: .mult, id: 13, name: "Color 14", fixture: "F96CB0794FD28C3EE22F6EE110B34991", capturedSpeed:  43, capturedA: .black, capturedB: .black),
        Mode(browse: 24, bank: .mult, id: 14, name: "Color 15", fixture: "EAE2EC791E00C2BCAC06AA696A4F10DF", capturedSpeed:  80, capturedA: .black, capturedB: .black)
    ]

    // MARK: Packet builders (plaintext, 16 bytes)

    enum Filler: Equatable {
        case random
        case zero
        case explicit([UInt8])
    }

    static func filler(_ mode: FillerMode) -> Filler { mode == .zero ? .zero : .random }

    private static func finish(_ meaningful: [UInt8], _ filler: Filler) -> [UInt8] {
        var out = meaningful
        let need = 16 - out.count
        precondition(need >= 0, "control packet exceeds 16 bytes")
        switch filler {
        case .zero:
            out += [UInt8](repeating: 0, count: need)
        case .random:
            out += (0..<need).map { _ in UInt8.random(in: 0...255) }
        case .explicit(let bytes):
            out += bytes.prefix(need)
            if out.count < 16 { out += [UInt8](repeating: 0, count: 16 - out.count) }
        }
        return out
    }

    static let ascTURN: [UInt8] = Array("TURN".utf8)
    static let ascSGLS: [UInt8] = Array("SGLS".utf8)
    static let ascMULT: [UInt8] = Array("MULT".utf8)

    /// 05 'TURN' state
    static func turnMeaningful(_ on: Bool) -> [UInt8] {
        var b: [UInt8] = [0x05]
        b.append(contentsOf: ascTURN)
        b.append(on ? 0x01 : 0x00)
        return b
    }

    /// 0E 'SGLS' mode 00 64 speed rA gA bA rB gB bB
    static func sglsMeaningful(mode: UInt8, speed: UInt8, a: RGB, b: RGB) -> [UInt8] {
        var out: [UInt8] = [0x0E]
        out.append(contentsOf: ascSGLS)
        out.append(contentsOf: [mode, 0x00, 0x64, min(speed, 100)])
        out.append(contentsOf: a.bytes)
        out.append(contentsOf: b.bytes)
        return out
    }

    /// 09 'MULT' mode 00 64 speed 07
    static func multMeaningful(mode: UInt8, speed: UInt8) -> [UInt8] {
        var out: [UInt8] = [0x09]
        out.append(contentsOf: ascMULT)
        out.append(contentsOf: [mode, 0x00, 0x64, min(speed, 100), 0x07])
        return out
    }

    static func turn(_ on: Bool, filler: Filler) -> [UInt8] {
        finish(turnMeaningful(on), filler)
    }

    static func sgls(mode: UInt8, speed: UInt8, a: RGB, b: RGB, filler: Filler) -> [UInt8] {
        finish(sglsMeaningful(mode: mode, speed: speed, a: a, b: b), filler)
    }

    static func mult(mode: UInt8, speed: UInt8, filler: Filler) -> [UInt8] {
        finish(multMeaningful(mode: mode, speed: speed), filler)
    }

    // MARK: Palette (unencrypted)

    /// 16 00 + seven RGB triplets (23 meaningful bytes), then a sanitized zero tail.
    /// The vendor app wrote 100 bytes; its tail looked like stale app memory and is NOT reproduced.
    static func paletteMeaningful(_ colors: [RGB]) -> [UInt8] {
        let seven = Array((colors + [RGB](repeating: .black, count: 7)).prefix(7))
        var out: [UInt8] = [0x16, 0x00]
        for c in seven { out.append(contentsOf: c.bytes) }
        return out
    }

    static func palette(_ colors: [RGB], length: Int) -> Data {
        var bytes = paletteMeaningful(colors)
        let total = max(bytes.count, min(512, length))
        bytes += [UInt8](repeating: 0, count: total - bytes.count)
        return Data(bytes)
    }

    // MARK: State → meaningful bytes (used for diffing and sending)

    static func wireSpeed(_ speed: Int, invert: Bool) -> UInt8 {
        let s = max(0, min(100, speed))
        return UInt8(invert ? 100 - s : s)
    }

    /// Meaningful command bytes for the pattern part of a state (no filler).
    static func patternMeaningful(_ state: LightState, invertSpeed: Bool) -> [UInt8] {
        let m = state.mode
        let sp = wireSpeed(state.speed, invert: invertSpeed)
        switch m.bank {
        case .sgls:
            return sglsMeaningful(mode: m.id, speed: sp,
                                  a: state.colorA.scaled(state.brightness),
                                  b: state.colorB.scaled(state.brightness))
        case .mult:
            return multMeaningful(mode: m.id, speed: sp)
        }
    }

    /// Meaningful palette bytes, or nil for SGLS modes.
    static func paletteFor(_ state: LightState) -> [UInt8]? {
        guard state.mode.bank == .mult else { return nil }
        return paletteMeaningful(state.palette.map { $0.scaled(state.brightness) })
    }

    /// Pads meaningful pattern bytes to a full 16-byte plaintext.
    static func pad(_ meaningful: [UInt8], filler: Filler) -> [UInt8] {
        finish(meaningful, filler)
    }

    /// Human-readable decode of a 16-byte plaintext.
    static func describe(_ p: [UInt8]) -> String {
        guard p.count >= 5 else { return p.hexString }
        let cmd = String(bytes: p[1...4], encoding: .ascii) ?? "????"
        switch cmd {
        case "TURN": return "TURN \(p[5] == 1 ? "ON" : "OFF")"
        case "SGLS" where p.count >= 15:
            return "SGLS mode \(p[5]) speed \(p[8]) A \(Array(p[9...11]).hexString) B \(Array(p[12...14]).hexString)"
        case "MULT" where p.count >= 10:
            return "MULT mode \(p[5]) speed \(p[8]) colors \(p[9])"
        default:
            return "\(cmd) \(p.hexString)"
        }
    }
}
