import type { MarkdownIt } from 'markdown-it';

/** A limited inline HTML convention; attributes and other HTML remain literal. */
export function underlineReading(markdown: MarkdownIt): void {
  markdown.inline.ruler.before('html_inline', 'lino_underline', (state, silent) => {
    const mark = /^<\/?u>/.exec(state.src.slice(state.pos));
    if (!mark) return false;
    if (!silent) state.push(mark[0] === '<u>' ? 'underline_open' : 'underline_close', 'u', mark[0] === '<u>' ? 1 : -1);
    state.pos += mark[0].length; return true;
  });
}
