public let macHealthVersion = "1.1.0"

/// Version of the `--json` contract. Consumers should refuse a payload whose
/// `schemaVersion` exceeds what they were written against. Adding a field is
/// not a breaking change and does not bump this.
public let macHealthSchemaVersion = 1
