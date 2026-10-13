import { isolateHistory } from '@codemirror/commands';
import { EditorSelection, type EditorState, type TransactionSpec } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import { compositionState } from '../source-mode/state.ts';
import { guardTextBlocks } from '../markdown/selection.ts';
import { escapedLabel, escapedDestination, escapedTitle } from '../markdown/urls.ts';
import { referenceIndex, linkAt, type DocumentLink } from './model.ts';
import { navigateSourcePosition } from '../navigation/line.ts';
import { mediaHost } from '../media/state.ts';
import { t } from '../../localization/index.ts';

export function referenceEdit(state: EditorState, from: number, to: number, insert: string): TransactionSpec {
  return { changes: { from, to, insert }, selection: EditorSelection.cursor(from + insert.length),
    annotations: isolateHistory.of('full'), userEvent: 'input.reference', scrollIntoView: true };
}
export function serializedLink(label: string, url: string, title: string, previous?: DocumentLink): string {
  if (!url.trim() || /[\r\n\0]/.test(label + url + title)) throw new Error(t('references.invalidLink'));
  const text = previous?.label === label ? previous.rawLabel : escapedLabel(label);
  return `[${text}](<${escapedDestination(url.trim())}>${title ? ` "${escapedTitle(title)}"` : ''})`;
}
export function openLink(view: EditorView, url: string, report: (error: unknown) => void): boolean {
  if (url.startsWith('#')) {
    let anchor: string; try { anchor = decodeURIComponent(url.slice(1)); } catch { throw new Error(t('references.invalidLink')); }
    const target = view.state.field(referenceIndex).headings.find(heading => heading.anchor === anchor);
    if (!target) throw new Error(t('references.missingAnchor'));
    return navigateSourcePosition(view, target.from);
  }
  if (/^[a-z][a-z\d+.-]*:/i.test(url) && !/^(?:https?:|mailto:)/i.test(url) || url.startsWith('//')) throw new Error(t('media.protocol'));
  const host = mediaHost(view); if (!host) throw new Error(t('media.noHost'));
  const doc = view.state.doc;
  void host.assets.request('open-link', url).catch(error => {
    if (view.dom.isConnected && view.state.doc === doc) report(error);
  });
  return true;
}
export function navigateFootnote(view: EditorView): boolean {
  const index = view.state.field(referenceIndex), head = view.state.selection.main.head;
  const mention = index.mentions.find(note => note.from <= head && note.to >= head);
  const note = mention ? index.notes.get(mention.id) : Array.from(index.notes.values()).find(note => note.from <= head && note.to >= head);
  const target = mention ? note?.from : index.mentions.find(item => item.id === note?.id)?.from;
  if (target === undefined) throw new Error(t('references.missingFootnote'));
  return navigateSourcePosition(view, target);
}
export function referenceInsertion(view: EditorView, command: 'insert-footnote' | 'insert-toc' | 'insert-frontmatter' | 'horizontal-rule'): boolean {
  if (view.state.readOnly || view.composing || view.state.field(compositionState, false)) return false;
  guardTextBlocks(view.state); const state = view.state, range = state.selection.main;
  if (command === 'insert-frontmatter') {
    if (state.doc.line(1).text === '---') throw new Error(t('references.existingMetadata'));
    const insert = '---\ntitle: \n---\n\n';
    view.dispatch({ ...referenceEdit(state, 0, 0, insert), selection: { anchor: 11 } }); view.focus(); return true;
  }
  if (command === 'insert-footnote') {
    const index = state.field(referenceIndex); let number = 1;
    while (index.notes.has(String(number)) || index.mentions.some(item => item.id === String(number))) number++;
    const body = state.sliceDoc(range.from, range.to), mention = `[^${number}]`;
    const appendix = `${state.doc.length && state.sliceDoc(Math.max(0, state.doc.length - 2), state.doc.length) !== '\n\n' ? '\n\n' : ''}[^${number}]: ${body}`;
    const changes = state.changes([{ from: range.from, to: range.to, insert: mention }, { from: state.doc.length, insert: appendix }]);
    const anchor = changes.mapPos(state.doc.length, 1);
    view.dispatch({ ...referenceEdit(state, 0, 0, ''), changes, selection: { anchor }, userEvent: 'input.reference' }); view.focus(); return true;
  }
  const before = range.from && state.sliceDoc(Math.max(0, range.from - 2), range.from) !== '\n\n' ? '\n\n' : '';
  const after = range.to < state.doc.length ? '\n\n' : '\n';
  view.dispatch(referenceEdit(state, range.from, range.to, before + (command === 'insert-toc' ? '[TOC]' : '---') + after)); view.focus(); return true;
}
export function unlink(view: EditorView): boolean {
  if (view.state.readOnly || view.composing || view.state.field(compositionState, false)) return false;
  const link = linkAt(view.state); if (!link) return false;
  view.dispatch(referenceEdit(view.state, link.from, link.to, link.rawLabel)); view.focus(); return true;
}
