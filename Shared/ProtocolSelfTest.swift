import Foundation

/// On-device check of AES + packet builders against the captured fixtures.
/// For each fixture: decrypt, verify the header, rebuild the plaintext with our builder
/// (reusing the captured filler bytes), re-encrypt, and compare with the capture byte-for-byte.
enum ProtocolSelfTest {
    struct Result: Identifiable {
        let id = UUID()
        let name: String
        let passed: Bool
        let detail: String
    }

    static func run() -> [Result] {
        var results: [Result] = []

        func check(_ name: String, _ hex: String, rebuild: ([UInt8]) -> [UInt8]?) {
            guard let cipher = [UInt8](hex: hex), cipher.count == 16,
                  let plain = IStrip.decrypt(cipher) else {
                results.append(Result(name: name, passed: false, detail: "decrypt failed"))
                return
            }
            guard let rebuilt = rebuild(plain), let enc = IStrip.encrypt(rebuilt) else {
                results.append(Result(name: name, passed: false, detail: "rebuild failed: \(plain.hexString)"))
                return
            }
            let ok = enc.bytes == cipher
            results.append(Result(name: name, passed: ok, detail: IStrip.describe(plain)))
        }

        check("TURN OFF", IStrip.fixtureOff) { p in
            guard p[0] == 0x05, Array(p[1...4]) == IStrip.ascTURN, p[5] == 0 else { return nil }
            return IStrip.turn(false, filler: .explicit(Array(p[6...])))
        }
        check("TURN ON", IStrip.fixtureOn) { p in
            guard p[0] == 0x05, Array(p[1...4]) == IStrip.ascTURN, p[5] == 1 else { return nil }
            return IStrip.turn(true, filler: .explicit(Array(p[6...])))
        }

        for m in IStrip.modes {
            check("\(m.bank.rawValue) \(m.id)", m.fixture) { p in
                switch m.bank {
                case .sgls:
                    guard p[0] == 0x0E, Array(p[1...4]) == IStrip.ascSGLS, p[5] == m.id else { return nil }
                    return IStrip.sgls(mode: m.id, speed: p[8],
                                       a: RGB(p[9], p[10], p[11]), b: RGB(p[12], p[13], p[14]),
                                       filler: .explicit(Array(p[15...])))
                case .mult:
                    guard p[0] == 0x09, Array(p[1...4]) == IStrip.ascMULT, p[5] == m.id, p[9] == 7 else { return nil }
                    return IStrip.mult(mode: m.id, speed: p[8], filler: .explicit(Array(p[10...])))
                }
            }
        }

        let pal = IStrip.paletteMeaningful(PaletteLibrary.captured)
        let expected = [UInt8](hex: "16 00 FF 00 00 FF A2 00 FF FF 00 00 FF 00 00 00 FF FF 00 FF FF FF FF") ?? []
        results.append(Result(name: "Palette bytes", passed: pal == expected, detail: pal.hexString))

        let lengths = [IStrip.turn(true, filler: .random).count,
                       IStrip.sgls(mode: 0, speed: 100, a: .black, b: .black, filler: .zero).count,
                       IStrip.mult(mode: 14, speed: 0, filler: .random).count]
        results.append(Result(name: "16-byte packets, no padding block", passed: lengths.allSatisfy { $0 == 16 },
                              detail: "\(lengths)"))
        return results
    }
}
