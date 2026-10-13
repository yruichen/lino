import type { MarkdownConfig } from '@lezer/markdown';
import { tags } from '@lezer/highlight';
import type { Input } from '@lezer/common';

let activeMetadataEnd: number | undefined;
// Inspect through the public parser input, without retaining a second source copy.
function metadataEnd(input: Input): number | undefined {
  if (input.read(0, Math.min(4, input.length)) !== '---\n') return undefined;
  let start = 4, prefix = '', whitespace = true;
  for (let offset = 4; offset < input.length; offset += 4096) {
    const chunk = input.read(offset, Math.min(offset + 4096, input.length));
    for (let i = 0; i < chunk.length; i++) {
      const char = chunk[i];
      if (char === '\n') {
        if ((prefix === '---' || prefix === '...') && whitespace) return offset + i;
        start = offset + i + 1; prefix = ''; whitespace = true;
      } else if (prefix.length < 3) prefix += char;
      else if (char !== ' ' && char !== '\t' && char !== '\r') whitespace = false;
    }
  }
  return start < input.length && (prefix === '---' || prefix === '...') && whitespace ? input.length : undefined;
}
const noteDefinition = /^ {0,3}(\[\^([^\[\]\s]+)\]):[ \t]*/;
const tocLine = /^ {0,3}\[toc\]\s*$/i;

export const referenceSyntax: MarkdownConfig = {
  wrap(inner, input) {
    const end = metadataEnd(input);
    return {
      advance() {
        const previous = activeMetadataEnd; activeMetadataEnd = end;
        try { return inner.advance(); } finally { activeMetadataEnd = previous; }
      },
      get parsedPos() { return inner.parsedPos; },
      get stoppedAt() { return inner.stoppedAt; },
      stopAt(position) { inner.stopAt(position); },
    };
  },
  defineNodes: [
    { name: 'FootnoteReference', style: tags.link }, { name: 'FootnoteDefinition', block: true },
    { name: 'FootnoteLabel', style: tags.labelName }, { name: 'ReferenceMark', style: tags.processingInstruction },
    { name: 'DocumentTOC', block: true, style: tags.processingInstruction },
    { name: 'FrontMatter', block: true, style: tags.meta },
    { name: 'Highlight', style: tags.special(tags.content) }, { name: 'HighlightMark', style: tags.processingInstruction },
    { name: 'Superscript', style: tags.special(tags.content) }, { name: 'Subscript', style: tags.special(tags.content) },
    { name: 'ScriptMark', style: tags.processingInstruction },
  ],
  parseBlock: [{ name: 'FrontMatter', before: 'HorizontalRule', parse(cx, line) {
    if (cx.lineStart !== 0 || cx.depth !== 1 || line.text !== '---' || activeMetadataEnd === undefined) return false;
    const from = cx.lineStart; cx.nextLine();
    while (true) {
      if (/^(?:---|\.\.\.)\s*$/.test(line.text)) { const to = cx.lineStart + line.text.length; cx.nextLine(); cx.addElement(cx.elt('FrontMatter', from, to)); return true; }
      if (!cx.nextLine()) { cx.addElement(cx.elt('FrontMatter', from, cx.prevLineEnd())); return true; }
    }
  } }, { name: 'DocumentTOC', before: 'LinkReference', parse(cx, line) {
    if (cx.depth !== 1 || !tocLine.test(line.text)) return false;
    const from = cx.lineStart, to = from + line.text.length;
    cx.nextLine(); cx.addElement(cx.elt('DocumentTOC', from, to)); return true;
  }, endLeaf(cx, line) { return cx.depth === 1 && tocLine.test(line.text); } }, { name: 'FootnoteDefinition', before: 'LinkReference', parse(cx, line) {
    const match = noteDefinition.exec(line.text);
    if (cx.depth !== 1 || !match) return false;
    const from = cx.lineStart, start = from + match[0].indexOf('[');
    const label = cx.elt('FootnoteLabel', start, start + match[1].length);
    let to = from + line.text.length;
    while (cx.nextLine()) {
      if (/^(?: {4}|\t)/.test(line.text)) { to = cx.lineStart + line.text.length; continue; }
      if (!line.text.trim() && /^(?: {4}|\t)/.test(cx.peekLine())) { to = cx.lineStart + line.text.length; continue; }
      break;
    }
    cx.addElement(cx.elt('FootnoteDefinition', from, to, [label])); return true;
  }, endLeaf(cx, line) { return cx.depth === 1 && noteDefinition.test(line.text); } }],
  parseInline: [{ name: 'FootnoteReference', before: 'Link', parse(cx, next, pos) {
    if (next !== 91 || cx.char(pos + 1) !== 94) return -1;
    for (let end = pos + 2; end < cx.end; end++) {
      const char = cx.char(end);
      if (char === 91 || /\s/.test(String.fromCharCode(char))) return -1;
      if (char === 93) {
        if (end === pos + 2) return -1;
        return cx.addElement(cx.elt('FootnoteReference', pos, end + 1, [cx.elt('ReferenceMark', pos, pos + 2), cx.elt('FootnoteLabel', pos + 2, end), cx.elt('ReferenceMark', end, end + 1)]));
      }
    }
    return -1;
  } }, ...([
    ['Highlight', '==', 'HighlightMark'], ['Superscript', '^', 'ScriptMark'], ['Subscript', '~', 'ScriptMark'],
  ] as const).map(([name, mark]) => ({ name, before: 'Emphasis', parse(cx: import('@lezer/markdown').InlineContext, next: number, pos: number) {
    if (next !== mark.charCodeAt(0) || cx.text.slice(pos - cx.offset, pos - cx.offset + mark.length) !== mark) return -1;
    if (mark === '~' && (cx.char(pos - 1) === 126 || cx.char(pos + 1) === 126)) return -1;
    const type = name === 'Highlight' ? highlight : name === 'Superscript' ? superscript : subscript;
    const before = cx.char(pos - 1), after = cx.char(pos + mark.length);
    return cx.addDelimiter(type, pos, pos + mark.length, !Number.isNaN(after) && !/\s/.test(String.fromCharCode(after)), !Number.isNaN(before) && !/\s/.test(String.fromCharCode(before)));
  } }))],
};
const highlight = { resolve: 'Highlight', mark: 'HighlightMark' };
const superscript = { resolve: 'Superscript', mark: 'ScriptMark' };
const subscript = { resolve: 'Subscript', mark: 'ScriptMark' };
