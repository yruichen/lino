use crate::{dispatch::error, DocumentRuntime};
use lino_application::updates::{newest_release, Release};
use lino_protocol::{ErrorCode, UpdateCheck, UpdateRelease, WireError};
use serde::Deserialize;

fn encode_path_segment(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push('%');
            encoded.push(char::from(b"0123456789ABCDEF"[(byte >> 4) as usize]));
            encoded.push(char::from(b"0123456789ABCDEF"[(byte & 0x0f) as usize]));
        }
    }
    encoded
}

#[derive(Deserialize)]
struct GitHubRelease {
    tag_name: String,
    prerelease: bool,
    draft: bool,
}

impl DocumentRuntime {
    pub fn evaluate_releases(
        &self,
        json: &str,
        current_version: &str,
        include_prereleases: bool,
    ) -> Result<UpdateCheck, WireError> {
        let invalid = |message: &str| error(ErrorCode::InvalidMessage, message, false);
        if json.len() > 2 * 1024 * 1024 {
            return Err(invalid("Release response is too large"));
        }
        let input: Vec<GitHubRelease> =
            serde_json::from_str(json).map_err(|_| invalid("Invalid GitHub release response"))?;
        let releases: Vec<_> = input
            .into_iter()
            .map(|value| Release {
                tag: value.tag_name,
                prerelease: value.prerelease,
                draft: value.draft,
            })
            .collect();
        let result =
            newest_release(current_version, &releases, include_prereleases).map_err(invalid)?;
        Ok(UpdateCheck {
            newer: result.is_some_and(|(_, newer)| newer),
            release: result.map(|(release, _)| UpdateRelease {
                version: release.tag.clone(),
                url: format!(
                    "https://github.com/yruichen/lino/releases/tag/{}",
                    encode_path_segment(&release.tag)
                ),
                prerelease: release.prerelease || release.tag.contains('-'),
            }),
        })
    }
}
