//! Release selection is shared; HTTP, presentation and opening a browser are ports.
use semver::Version;

pub struct Release {
    pub tag: String,
    pub prerelease: bool,
    pub draft: bool,
}

pub fn newest_release<'a>(
    current: &str,
    releases: &'a [Release],
    include_prereleases: bool,
) -> Result<Option<(&'a Release, bool)>, &'static str> {
    let current = Version::parse(current.trim_start_matches('v'))
        .map_err(|_| "Invalid installed application version")?;
    let latest = releases
        .iter()
        .filter(|release| !release.draft)
        .filter_map(|release| {
            let version =
                Version::parse(release.tag.strip_prefix('v').unwrap_or(&release.tag)).ok()?;
            (include_prereleases || (!release.prerelease && version.pre.is_empty()))
                .then_some((release, version))
        })
        .max_by(|(_, left), (_, right)| left.cmp_precedence(right));
    Ok(latest.map(|(release, version)| (release, version.cmp_precedence(&current).is_gt())))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn release(tag: &str, prerelease: bool, draft: bool) -> Release {
        Release {
            tag: tag.into(),
            prerelease,
            draft,
        }
    }
    #[test]
    fn release_selection_obeys_numeric_versions_channels_and_never_downgrades() {
        let releases = [
            release("v0.0.9", false, false),
            release("v0.0.10", false, false),
            release("v1.0.0-beta.2", true, false),
            release("v2.0.0", false, true),
            release("../../unsafe", false, false),
        ];
        assert_eq!(
            newest_release("0.0.9", &releases, false)
                .unwrap()
                .map(|(r, n)| (r.tag.as_str(), n)),
            Some(("v0.0.10", true))
        );
        assert_eq!(
            newest_release("1.0.0", &releases, true)
                .unwrap()
                .map(|(r, n)| (r.tag.as_str(), n)),
            Some(("v1.0.0-beta.2", false))
        );
        assert!(
            !newest_release("0.0.10+local", &releases[..2], false)
                .unwrap()
                .unwrap()
                .1
        );
        assert!(
            newest_release("0.0.4", &[release("v0.0.5", true, false)], false)
                .unwrap()
                .is_none()
        );
        assert!(newest_release("unknown", &releases, true).is_err());
    }
}
