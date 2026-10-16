use crate::{dispatch::error, DocumentRuntime};
use lino_application::updates::{newest_release, Release};
use lino_protocol::{ErrorCode, UpdateCheck, UpdateRelease, WireError};
use serde::Deserialize;

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
                    release.tag
                ),
                prerelease: release.prerelease || release.tag.contains('-'),
            }),
        })
    }
}
