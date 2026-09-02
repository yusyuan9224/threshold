/// Why an export was refused.
///
/// Export is the one path by which diagnostics leave the machine, so it fails closed: a buffer that
/// still contains a forbidden shape produces an error and no bytes, never bytes plus a warning.
public enum DiagnosticsExportError: Error, Equatable {
    /// `DiagnosticsExportAnonymityCheck` found identity in the encoded export. The associated value
    /// carries one human-readable finding per problem shape, safe to show or log: the findings name
    /// the *kind* of value found, never the value itself.
    case anonymityViolation([String])
}
