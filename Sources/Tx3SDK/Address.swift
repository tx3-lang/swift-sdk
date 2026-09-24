import Foundation

/// A validated Cardano address represented as Bech32 text or hexadecimal bytes.
public struct Address: Codable, Hashable, Sendable {
    /// The validated address text supplied by the caller.
    public let value: String

    /// Creates an address after validating its Bech32 checksum or hexadecimal form.
    ///
    /// - Parameter value: A Bech32 address or an even-length hexadecimal string.
    /// - Throws: ``Tx3Error/validation(_:)`` when the value is not a supported address form.
    public init(_ value: String) throws {
        guard Self.isHex(value) || Self.isBech32(value) else {
            throw Tx3Error.validation(.invalidAddress(value))
        }
        self.value = value
    }

    /// Decodes and validates an address string.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    /// Encodes the address as its validated string representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isHex(_ value: String) -> Bool {
        let body = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        return !body.isEmpty && body.count.isMultiple(of: 2)
            && body.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 48...57, 65...70, 97...102: true
                default: false
                }
            }
    }

    private static func isBech32(_ value: String) -> Bool {
        guard value == value.lowercased() || value == value.uppercased() else { return false }
        guard let separator = value.lastIndex(of: "1") else { return false }
        let hrp = value[..<separator].lowercased()
        let payload = value[value.index(after: separator)...].lowercased()
        guard !hrp.isEmpty, payload.count >= 6, value.count <= 90 else { return false }
        guard hrp.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else { return false }

        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })
        guard let values = payload.map({ lookup[$0] }) as? [Int] else { return false }

        var expanded = hrp.unicodeScalars.map { Int($0.value >> 5) }
        expanded.append(0)
        expanded.append(contentsOf: hrp.unicodeScalars.map { Int($0.value & 31) })
        return polymod(expanded + values) == 1
    }

    private static func polymod(_ values: [Int]) -> Int {
        let generators = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        return values.reduce(1) { checksum, value in
            let top = checksum >> 25
            var next = ((checksum & 0x1ff_ffff) << 5) ^ value
            for index in generators.indices where ((top >> index) & 1) == 1 {
                next ^= generators[index]
            }
            return next
        }
    }
}
