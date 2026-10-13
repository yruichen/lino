/// Explicit bound for this implementation, including the UTF-8 BOM on disk.
pub const MAX_DOCUMENT_BYTES: usize = 64 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct TextFormat {
    pub utf8_bom: bool,
}
