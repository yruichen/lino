use serde::Serialize;

#[derive(Serialize)]
pub struct EditorShortcut {
    pub command: &'static str,
    pub key: &'static str,
    pub modifiers: &'static [&'static str],
}

pub const MARKDOWN_SHORTCUTS: &[EditorShortcut] = &[
    EditorShortcut {
        command: "heading-1",
        key: "1",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "heading-2",
        key: "2",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "heading-3",
        key: "3",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "heading-4",
        key: "4",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "heading-5",
        key: "5",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "heading-6",
        key: "6",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "paragraph",
        key: "0",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "bold",
        key: "b",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "italic",
        key: "i",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "strikethrough",
        key: "x",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "inline-code",
        key: "e",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "highlight",
        key: "h",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "superscript",
        key: "=",
        modifiers: &["command", "control"],
    },
    EditorShortcut {
        command: "subscript",
        key: "-",
        modifiers: &["command", "control"],
    },
    EditorShortcut {
        command: "clear-formatting",
        key: "\\",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "link",
        key: "k",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "link-properties",
        key: "k",
        modifiers: &["command", "option"],
    },
    EditorShortcut {
        command: "ordered-list",
        key: "7",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "bullet-list",
        key: "8",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "task-list",
        key: "9",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "toggle-task",
        key: "l",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "indent",
        key: "]",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "outdent",
        key: "[",
        modifiers: &["command"],
    },
    EditorShortcut {
        command: "blockquote",
        key: "b",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "code-block",
        key: "k",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "code-language",
        key: "l",
        modifiers: &["command", "option"],
    },
    EditorShortcut {
        command: "horizontal-rule",
        key: "j",
        modifiers: &["command", "option"],
    },
    EditorShortcut {
        command: "insert-table",
        key: "t",
        modifiers: &["command", "option"],
    },
    EditorShortcut {
        command: "image-import",
        key: "i",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "math-inline",
        key: "m",
        modifiers: &["command", "control"],
    },
    EditorShortcut {
        command: "math-block",
        key: "m",
        modifiers: &["command", "shift"],
    },
    EditorShortcut {
        command: "insert-diagram",
        key: "m",
        modifiers: &["command", "option"],
    },
    EditorShortcut {
        command: "insert-footnote",
        key: "r",
        modifiers: &["command", "option"],
    },
    EditorShortcut {
        command: "goto-footnote",
        key: "r",
        modifiers: &["command", "control"],
    },
    EditorShortcut {
        command: "insert-toc",
        key: "t",
        modifiers: &["command", "control"],
    },
    EditorShortcut {
        command: "insert-frontmatter",
        key: "f",
        modifiers: &["command", "option", "control"],
    },
];
