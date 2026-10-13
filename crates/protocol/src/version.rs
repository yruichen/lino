pub const PROTOCOL_VERSION: u32 = 1;
pub const RESOURCE_VERSION: &str = env!("CARGO_PKG_VERSION");
pub const CAPABILITIES: &[&str] = &[
    "utf8-changes",
    "save-tickets",
    "utf8-bom",
    "mixed-line-endings",
    "recovery-snapshots",
];
