/// A value-semantic transaction builder seeded by the facade layer.
///
/// The facade adds transaction metadata and native argument handling. This core definition owns
/// the generated-client seam so statically constructed ``ArgValue`` values are retained without a
/// second schema-directed encoding pass.
public struct TxBuilder: Sendable {
    var taggedArguments: [String: ArgValue]

    init(taggedArguments: [String: ArgValue] = [:]) {
        self.taggedArguments = taggedArguments
    }

    /// Adds an already canonical tagged argument.
    ///
    /// Names are normalized case-insensitively and later writes replace earlier ones. The value is
    /// stored directly and is not passed through ``ArgEncoder`` again.
    public func argTagged(_ name: String, _ value: ArgValue) -> TxBuilder {
        var copy = self
        copy.taggedArguments[name.lowercased()] = value
        return copy
    }
}
