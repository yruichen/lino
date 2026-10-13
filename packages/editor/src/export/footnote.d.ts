declare module 'markdown-it-footnote' {
  import type { MarkdownIt } from 'markdown-it';
  export default function footnotes(parser: MarkdownIt): void;
}
