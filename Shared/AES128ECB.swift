import Foundation
import CommonCrypto

/// AES-128 in ECB mode with NO padding. Every iStrip control packet is exactly one 16-byte block.
enum AES128ECB {
    static func encrypt(_ input: [UInt8], key: [UInt8]) -> [UInt8]? {
        crypt(input, key: key, operation: CCOperation(kCCEncrypt))
    }

    static func decrypt(_ input: [UInt8], key: [UInt8]) -> [UInt8]? {
        crypt(input, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ input: [UInt8], key: [UInt8], operation: CCOperation) -> [UInt8]? {
        guard key.count == kCCKeySizeAES128,
              !input.isEmpty,
              input.count % kCCBlockSizeAES128 == 0 else { return nil }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status: CCCryptorStatus = key.withUnsafeBytes { keyPtr in
            input.withUnsafeBytes { inPtr in
                output.withUnsafeMutableBytes { outPtr in
                    CCCrypt(operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode),          // ECB, no PKCS#7 padding
                            keyPtr.baseAddress, key.count,
                            nil,
                            inPtr.baseAddress, input.count,
                            outPtr.baseAddress, input.count,
                            &moved)
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == input.count else { return nil }
        return output
    }
}

// MARK: - Hex helpers

extension Array where Element == UInt8 {
    init?(hex: String) {
        let clean = hex.filter { $0.isHexDigit }
        guard clean.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var printableASCII: String {
        String(map { (0x20...0x7E).contains($0) ? Character(UnicodeScalar($0)) : "." })
    }
}

extension Data {
    var bytes: [UInt8] { [UInt8](self) }
}
