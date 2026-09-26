import Foundation

func decodeSignerHex(_ value: String, expectedByteCount: Int) throws -> Data {
    let body = value.hasPrefix("0x") ? value.dropFirst(2) : value[...]
    guard body.count == expectedByteCount * 2, body.count.isMultiple(of: 2) else {
        throw Tx3Error.signing(.invalidHash)
    }

    var bytes = Data()
    bytes.reserveCapacity(expectedByteCount)
    var index = body.startIndex
    while index < body.endIndex {
        let next = body.index(index, offsetBy: 2)
        guard let byte = UInt8(body[index..<next], radix: 16) else {
            throw Tx3Error.signing(.invalidHash)
        }
        bytes.append(byte)
        index = next
    }
    return bytes
}

extension Data {
    var lowercaseHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
