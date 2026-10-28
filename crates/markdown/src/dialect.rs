//! Syntax profile used by the pure Markdown analysis layer.

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Dialect {
    #[default]
    Markdown,
    Latex,
}
