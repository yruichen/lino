import { Compartment, EditorState, Facet, Transaction, type Extension } from '@codemirror/state';
import { EditorView, ViewPlugin, type ViewUpdate } from '@codemirror/view';
import { compositionState } from '../features/source-mode/state.ts';
import { currentLocale, onLocaleChange, tFor, type Locale } from './index.ts';

export const localeFacet = Facet.define<Locale, Locale>({ combine: values => values[0] ?? 'en' });
const chinesePhrases: Record<string, string> = {
  'Go to line': '跳转到行', go: '跳转', Cancel: '取消', close: '关闭',
  'Selection deleted': '选区已删除', 'Control character': '控制字符',
  'current match': '当前匹配', 'on line': '所在行',
  'replaced $ matches': '已替换 $ 个匹配', 'replaced match on line $': '已替换第 $ 行的匹配',
  Find: '查找', Replace: '替换', next: '下一个', previous: '上一个', all: '全部',
  'match case': '区分大小写', regexp: '正则表达式', 'by word': '整词匹配',
  replace: '替换', 'replace all': '全部替换', 'folded code': '已折叠代码', to: '至', unfold: '展开',
};
export function localeConfiguration(locale: Locale): Extension {
  return [localeFacet.of(locale), EditorState.phrases.of(locale === 'zh-Hans' ? chinesePhrases : {}),
    EditorView.contentAttributes.of({ 'aria-label': tFor(locale, 'editor.label') })];
}
export function editorLocalization(): Extension {
  const compartment = new Compartment();
  return [compartment.of(localeConfiguration(currentLocale())), ViewPlugin.fromClass(class {
    private readonly view: EditorView;
    private readonly unsubscribe: () => void;
    private composing = false;
    private queued = false;
    private disposed = false;
    private readonly start = () => { this.composing = true; };
    private readonly end = () => { this.composing = false; this.schedule(); };
    constructor(view: EditorView) {
      this.view = view;
      this.unsubscribe = onLocaleChange(() => this.schedule());
      // Capture composition from the document, table inputs and search fields.
      view.dom.addEventListener('compositionstart', this.start, true);
      view.dom.addEventListener('compositionend', this.end, true);
    }
    private schedule(): void {
      if (this.queued || this.disposed) return;
      this.queued = true;
      queueMicrotask(() => {
        this.queued = false;
        if (this.disposed || this.composing || this.view.composing || this.view.state.field(compositionState, false)) return;
        const locale = currentLocale();
        if (this.view.state.facet(localeFacet) !== locale) {
          // CodeMirror may recreate panels when phrases change. Preserve the
          // focused control here for every feature, instead of per-panel copies.
          const active = this.view.dom.ownerDocument.activeElement;
          const control = active instanceof HTMLInputElement || active instanceof HTMLTextAreaElement || active instanceof HTMLSelectElement ? active : undefined;
          const focused = control && this.view.dom.contains(control) ? control : undefined;
          const selection = focused && 'selectionStart' in focused ? [focused.selectionStart, focused.selectionEnd, focused.selectionDirection] as const : undefined;
          this.view.dispatch({ effects: compartment.reconfigure(localeConfiguration(locale)), annotations: Transaction.addToHistory.of(false) });
          if (focused && !focused.isConnected && focused.name) {
            const replacement = Array.from(this.view.dom.querySelectorAll<HTMLInputElement | HTMLTextAreaElement | HTMLSelectElement>('input, textarea, select'))
              .find(node => node.tagName === focused.tagName && node.name === focused.name);
            if (replacement && !replacement.disabled) {
              replacement.focus();
              if (selection && selection[0] !== null && selection[1] !== null && 'setSelectionRange' in replacement) replacement.setSelectionRange(selection[0], selection[1], selection[2] ?? undefined);
            }
          }
        }
      });
    }
    update(update: ViewUpdate): void {
      if (update.state.facet(localeFacet) !== currentLocale()) this.schedule();
    }
    destroy(): void {
      this.disposed = true; this.unsubscribe();
      this.view.dom.removeEventListener('compositionstart', this.start, true);
      this.view.dom.removeEventListener('compositionend', this.end, true);
    }
  })];
}
