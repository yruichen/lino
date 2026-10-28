//! Personal navigation configuration and file ranking; independent of windows and I/O.

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NavigationPreferences {
    pub locations: Vec<String>,
    pub favorites: Vec<String>,
    pub sections: Vec<String>,
    pub show_favorites: bool,
    pub show_locations: bool,
    pub show_open_files: bool,
    pub show_recents: bool,
    pub follow_active: bool,
    pub show_root: bool,
    pub show_extensions: bool,
    pub compact: bool,
    pub sort: String,
}
impl Default for NavigationPreferences {
    fn default() -> Self {
        Self {
            locations: vec![],
            favorites: vec![],
            sections: ["favorites", "locations", "open_files", "recents"]
                .map(String::from)
                .to_vec(),
            show_favorites: true,
            show_locations: true,
            show_open_files: true,
            show_recents: false,
            follow_active: false,
            show_root: false,
            show_extensions: true,
            compact: false,
            sort: "name".into(),
        }
    }
}
impl NavigationPreferences {
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.locations.len() > 32 || self.favorites.len() > 256 {
            return Err("Too many navigation entries");
        }
        for paths in [&self.locations, &self.favorites] {
            let mut seen = std::collections::HashSet::new();
            if paths
                .iter()
                .any(|path| path.is_empty() || path.len() > 4096 || !seen.insert(path))
            {
                return Err("Invalid or duplicate navigation path");
            }
        }
        let mut sections = self.sections.clone();
        sections.sort();
        if sections != ["favorites", "locations", "open_files", "recents"] {
            return Err("Invalid navigation sections");
        }
        if !["name", "modified"].contains(&self.sort.as_str()) {
            return Err("Invalid navigation ordering");
        }
        Ok(())
    }
}

/// Match quality dominates recency: exact, prefix, contained phrase, then subsequence.
/// Unicode scalar iteration avoids invalid byte slices for multilingual filenames.
pub fn supported_document_extension(extension: &str) -> bool {
    crate::document_types::DocumentKind::supports_extension(extension)
}
/// Browsable files include native, read-only media; editable documents remain UTF-8.
pub fn supported_browsing_extension(extension: &str) -> bool {
    supported_document_extension(extension)
        || [
            "pdf", "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "svg", "heic",
            "heif", "avif",
        ]
        .contains(&extension.to_lowercase().as_str())
}
pub fn file_score(query: &str, name: &str, _title: &str, path: &str) -> Option<u32> {
    let query = query.trim().to_lowercase();
    if query.is_empty() {
        return Some(0);
    }
    fn quality(query: &str, value: &str) -> Option<u32> {
        let value = value.to_lowercase();
        if value == query {
            return Some(0);
        }
        if value.starts_with(query) {
            return Some(1);
        }
        if value.contains(query) {
            return Some(2);
        }
        let mut wanted = query.chars();
        let mut next = wanted.next();
        for ch in value.chars() {
            if Some(ch) == next {
                next = wanted.next();
                if next.is_none() {
                    return Some(3);
                }
            }
        }
        None
    }
    // All filename matches outrank paths. A filename without its extension is
    // also an exact match when people type the document's name.
    let stem = name.rsplit_once('.').map_or(name, |(stem, _)| stem);
    quality(&query, name)
        .into_iter()
        .chain(quality(&query, stem))
        .min()
        .or_else(|| quality(&query, path).map(|quality| 4 + quality))
}

/// First Markdown heading in a bounded file prefix; code fences and front matter are skipped.
pub fn document_title(text: &str) -> String {
    let mut fence: Option<char> = None;
    let mut metadata = false;
    let mut previous = "";
    for (index, line) in text.lines().enumerate() {
        let line = line.trim();
        if index == 0 && line == "---" {
            metadata = true;
            continue;
        }
        if metadata {
            if line == "---" || line == "..." {
                metadata = false;
            }
            continue;
        }
        if line.starts_with("```") || line.starts_with("~~~") {
            let marker = line.chars().next().unwrap();
            if fence == Some(marker) {
                fence = None;
            } else if fence.is_none() {
                fence = Some(marker);
            }
            continue;
        }
        if fence.is_some() {
            continue;
        }
        if line.starts_with('#') {
            let heading = line.trim_start_matches('#');
            if line.len() - heading.len() <= 6 && heading.starts_with(char::is_whitespace) {
                return heading.trim().trim_end_matches('#').trim().to_owned();
            }
        }
        if !previous.is_empty()
            && line.len() >= 3
            && (line.chars().all(|c| c == '=') || line.chars().all(|c| c == '-'))
        {
            return previous.to_owned();
        }
        previous = line;
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranking_preserves_relevance_and_unicode() {
        assert!(
            file_score("Ideas", "Ideas.md", "Ideas", "Notes/Ideas.md")
                < file_score("Ideas", "Ideas old.md", "", "Ideas old.md")
        );
        assert!(file_score("ip", "Important.md", "", "Important.md").is_some());
        assert!(file_score(
            "慢思",
            "关于慢下来的思考.md",
            "",
            "文章/关于慢下来的思考.md"
        )
        .is_some());
        assert_eq!(file_score("missing", "Ideas.md", "", "Ideas.md"), None);
    }
    #[test]
    fn title_excludes_code_and_metadata() {
        assert_eq!(
            document_title("---\ntitle: metadata\n---\n```md\n# code\n```\n# Real heading\n"),
            "Real heading"
        );
        assert_eq!(document_title("My title\n========\n"), "My title");
    }
}
