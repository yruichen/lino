//! User-facing document profiles shared by navigation, sessions and hosts.

#[derive(Clone, Copy, Debug, Eq, PartialEq, Default)]
pub enum DocumentKind {
    #[default]
    Markdown,
    Latex,
}

impl DocumentKind {
    pub const MARKDOWN_EXTENSIONS: &'static [&'static str] =
        &["md", "markdown", "mdown", "mkd", "txt"];
    pub const LATEX_EXTENSIONS: &'static [&'static str] = &["tex"];

    pub fn from_extension(extension: &str) -> Option<Self> {
        let extension = extension.to_ascii_lowercase();
        if Self::LATEX_EXTENSIONS.contains(&extension.as_str()) {
            Some(Self::Latex)
        } else if Self::MARKDOWN_EXTENSIONS.contains(&extension.as_str()) {
            Some(Self::Markdown)
        } else {
            None
        }
    }

    pub fn from_label(label: &str) -> Self {
        std::path::Path::new(label)
            .extension()
            .and_then(|extension| extension.to_str())
            .and_then(Self::from_extension)
            .unwrap_or_default()
    }

    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::Markdown => "markdown",
            Self::Latex => "latex",
        }
    }

    pub fn supports_extension(extension: &str) -> bool {
        Self::from_extension(extension).is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_case_insensitive_document_profiles() {
        assert_eq!(
            DocumentKind::from_extension("MD"),
            Some(DocumentKind::Markdown)
        );
        assert_eq!(
            DocumentKind::from_extension("TeX"),
            Some(DocumentKind::Latex)
        );
        assert_eq!(DocumentKind::from_label("paper.tex"), DocumentKind::Latex);
        assert_eq!(DocumentKind::from_extension("rs"), None);
    }
}
