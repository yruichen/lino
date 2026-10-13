import type { MarkdownConfig } from '@lezer/markdown';
import { tags } from '@lezer/highlight';

/** Math is part of the existing Markdown parser, not a second document scan. */
export const mathSyntax: MarkdownConfig = {
  defineNodes: [{ name: 'InlineMath', style: tags.special(tags.string) }, { name: 'MathBlock', block: true, style: tags.special(tags.string) }, { name: 'MathMark', style: tags.processingInstruction }],
  parseInline: [{ name: 'InlineMath', after: 'InlineCode', parse(cx, next, pos) {
    if (next !== 36 || cx.char(pos + 1) === 36 || /\s/.test(cx.slice(pos + 1, pos + 2))) return -1;
    for (let end = pos + 1; end < cx.end; end++) {
      const char = cx.char(end);
      if (char === 10) return -1;
      if (char === 92) { end++; continue; }
      if (char === 36) {
        if (/\s/.test(cx.slice(end - 1, end)) || /\d/.test(cx.slice(end + 1, end + 2))) return -1;
        return cx.addElement(cx.elt('InlineMath', pos, end + 1, [cx.elt('MathMark', pos, pos + 1), cx.elt('MathMark', end, end + 1)]));
      }
    }
    return -1;
  } }],
  parseBlock: [{ name: 'MathBlock', before: 'FencedCode', parse(cx, line) {
    // Container math remains source until its prefix mapping is supported.
    if (cx.depth !== 1 || !/^ {0,3}\$\$\s*$/.test(line.text)) return false;
    const from = cx.lineStart, mark = from + line.text.indexOf('$$');
    let to = from + line.text.length;
    const marks = [cx.elt('MathMark', mark, mark + 2)];
    while (cx.nextLine()) {
      to = cx.lineStart + line.text.length;
      if (/^ {0,3}\$\$\s*$/.test(line.text)) {
        const end = cx.lineStart + line.text.indexOf('$$'); marks.push(cx.elt('MathMark', end, end + 2));
        cx.nextLine(); break;
      }
    }
    cx.addElement(cx.elt('MathBlock', from, to, marks)); return true;
  }, endLeaf: (_cx, line) => /^ {0,3}\$\$\s*$/.test(line.text) }],
};
