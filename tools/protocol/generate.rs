use open_typora_protocol::{
    CloseIntent, OpenedDocument, RecoveryEntry, RequestEnvelope, ResponseEnvelope, SaveTarget,
    CAPABILITIES, PROTOCOL_VERSION, RESOURCE_VERSION,
};
use ts_rs::TS;

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let output = std::env::args()
        .nth(1)
        .ok_or("Pass the generated output directory")?;
    std::fs::create_dir_all(&output)?;
    let config = ts_rs::Config::new().with_out_dir(&output);
    OpenedDocument::export_all(&config)?;
    RequestEnvelope::export_all(&config)?;
    ResponseEnvelope::export_all(&config)?;
    SaveTarget::export_all(&config)?;
    CloseIntent::export_all(&config)?;
    RecoveryEntry::export_all(&config)?;
    std::fs::write(std::path::Path::new(&output).join("version.ts"), format!(
        "// Generated from crates/protocol. Do not edit.\nexport const PROTOCOL_VERSION = {PROTOCOL_VERSION};\nexport const RESOURCE_VERSION = {RESOURCE_VERSION:?};\nexport const CAPABILITIES = {:?} as const;\n", CAPABILITIES))?;
    Ok(())
}
