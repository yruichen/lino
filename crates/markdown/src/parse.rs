//! Bounded, source-preserving Markdown line parser.

use crate::{
    ast::{Document, Node, NodeKind},
    dialect::Dialect,
};

pub fn parse(source: &str, _dialect: Dialect) -> Document {
    let mut document = Document {
        nodes: Vec::new(),
        source_len: source.len(),
    };
    let mut offset = 0usize;
    let mut fence: Option<char> = None;
    for raw in source.split_inclusive('\n') {
        let line_len = raw.len();
        let mut line = raw;
        if line.ends_with('\n') {
            line = &line[..line.len() - 1];
        }
        if line.ends_with('\r') {
            line = &line[..line.len() - 1];
        }
        let line_end = offset + line.len();
        let trimmed = line.trim_start();
        if let Some(marker) = fence {
            document.nodes.push(Node {
                kind: NodeKind::CodeFence { marker },
                range: offset..line_end,
                content: offset..line_end,
            });
            if trimmed.starts_with(marker) && trimmed.chars().take(3).all(|c| c == marker) {
                fence = None;
            }
            offset += line_len;
            continue;
        }
        if trimmed.starts_with("```") || trimmed.starts_with("~~~") {
            let marker = trimmed.chars().next().unwrap_or('`');
            fence = Some(marker);
            document.nodes.push(Node {
                kind: NodeKind::CodeFence { marker },
                range: offset..line_end,
                content: offset..line_end,
            });
        } else if let Some((level, content_start)) = atx_heading(line, offset) {
            document.nodes.push(Node {
                kind: NodeKind::Heading { level },
                range: offset..line_end,
                content: content_start..line_end,
            });
        } else if line.trim().is_empty() {
            // Blank lines delimit paragraphs but have no semantic node.
        } else if is_thematic_break(line) {
            document.nodes.push(Node {
                kind: NodeKind::ThematicBreak,
                range: offset..line_end,
                content: offset..line_end,
            });
        } else {
            document.nodes.push(Node {
                kind: NodeKind::Paragraph,
                range: offset..line_end,
                content: offset..line_end,
            });
        }
        offset += line_len;
    }
    if source.is_empty() {
        document.source_len = 0;
    }
    document
}

fn atx_heading(line: &str, offset: usize) -> Option<(u8, usize)> {
    let leading = line.len() - line.trim_start().len();
    let value = line.trim_start();
    let level = value.bytes().take_while(|byte| *byte == b'#').count();
    if !(1..=6).contains(&level)
        || value
            .as_bytes()
            .get(level)
            .is_none_or(|byte| !byte.is_ascii_whitespace())
    {
        return None;
    }
    let whitespace_len = value[level..].chars().next()?.len_utf8();
    Some((level as u8, offset + leading + level + whitespace_len))
}

fn is_thematic_break(line: &str) -> bool {
    let value: String = line
        .chars()
        .filter(|character| !character.is_whitespace())
        .collect();
    value.len() >= 3 && (value.chars().all(|c| c == '-') || value.chars().all(|c| c == '*'))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{headings, Dialect, NodeKind};

    #[test]
    fn preserves_unicode_ranges_and_crlf_boundaries() {
        let source = "# 标题\r\n正文\r\n";
        let document = parse(source, Dialect::Markdown);
        assert_eq!(document.source_len, source.len());
        assert!(matches!(
            document.nodes[0].kind,
            NodeKind::Heading { level: 1 }
        ));
        assert_eq!(&source[document.nodes[0].content.clone()], "标题");
        assert_eq!(headings(source, Dialect::Markdown).len(), 1);
    }

    #[test]
    fn fenced_lines_are_not_reinterpreted_as_headings() {
        let document = parse("```md\n# code\n```\n# real\n", Dialect::Markdown);
        assert_eq!(
            document
                .nodes
                .iter()
                .filter(|node| matches!(node.kind, NodeKind::Heading { .. }))
                .count(),
            1
        );
    }
}
