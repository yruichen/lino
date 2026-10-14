import { StateField, Transaction, type EditorState } from '@codemirror/state';
import { isolateHistory, redo, undo } from '@codemirror/commands';
import { selectedSearchMatch } from '../search/state.ts';
import { syntaxTree } from '@codemirror/language';
import { Decoration, EditorView, WidgetType, type DecorationSet } from '@codemirror/view';
import { tFor, type Locale } from '../../localization/index.ts';
import { localeFacet } from '../../localization/editor.ts';
import { changeComposition, compositionState, modeState } from '../source-mode/state.ts';
import { editCell, tableFromNode, type MarkdownTable } from './model.ts';
import { runTableCommand, type TableCommand } from './commands.ts';
import { TableError, type TableErrorCode } from './errors.ts';
import { focusTableCell, restoreCellFocus, tableCellFocus, tableWritable } from './state.ts';
import { componentMenu } from '../../controls/components.ts';
import { presentCell } from './presentation.ts';

interface CellPresentation { element: HTMLElement; source: string; dark: boolean; cancel(): void }
interface Binding { table: MarkdownTable; inputs: HTMLInputElement[][]; cells: CellPresentation[][]; view: EditorView; status: HTMLOutputElement; errorCode?: TableErrorCode }
const bindings = new WeakMap<HTMLElement, Binding>();
class TableWidget extends WidgetType {
  readonly table: MarkdownTable;
  readonly readOnly: boolean;
  readonly locale: Locale;
  readonly preserveInput: boolean;
  readonly dark: boolean;
  constructor(table: MarkdownTable, readOnly: boolean, locale: Locale, preserveInput: boolean, dark: boolean) { super(); this.table = table; this.readOnly = readOnly; this.locale = locale; this.preserveInput = preserveInput; this.dark = dark; }
  override eq(other: TableWidget): boolean { return this.table.from === other.table.from && this.table.source === other.table.source && this.readOnly === other.readOnly && this.locale === other.locale && this.dark === other.dark; }
  toDOM(view: EditorView): HTMLElement {
    const wrapper = document.createElement('div'); wrapper.className = 'markdown-table'; wrapper.dataset.tableFrom = String(this.table.from);
    wrapper.dataset.tableTo = String(this.table.to);
    const status = document.createElement('output'); status.setAttribute('role', 'status');
    const binding: Binding = { table: this.table, inputs: [], cells: [], view, status }; bindings.set(wrapper, binding);
    const report = (error: unknown) => { binding.errorCode = error instanceof TableError ? error.code : undefined; status.textContent = error instanceof TableError ? tFor(view.state.facet(localeFacet), `table.${error.code}`) : String(error); };
    const run = (command: TableCommand) => {
      if (!tableWritable(view.state, view.composing)) return;
      const current = view.state.field(tableCellFocus, false);
      if (current?.tableFrom !== binding.table.from) {
        view.dispatch({ selection: { anchor: binding.table.header.cells[0].from }, effects: focusTableCell.of({ tableFrom: binding.table.from, row: 0, column: 0 }) });
      }
      status.textContent = ''; binding.errorCode = undefined;
      runTableCommand(view, command, (message, code) => { binding.errorCode = code; status.textContent = message; });
    };
    wrapper.addEventListener('contextmenu', event => {
      const input = (event.target as Element).closest<HTMLInputElement>('input[data-row]');
      if (input) input.focus();
      else view.dispatch({ selection: { anchor: binding.table.header.cells[0].from }, effects: focusTableCell.of({ tableFrom: binding.table.from, row: 0, column: 0 }) });
      componentMenu(view, 'table', event);
    });
    const element = wrapper.appendChild(document.createElement('table'));
    [this.table.header, ...this.table.rows].forEach((row, rowIndex) => {
      const tr = element.insertRow(); binding.inputs[rowIndex] = []; binding.cells[rowIndex] = [];
      for (let column = 0; column < this.table.header.cells.length; column++) {
        const cell = document.createElement(rowIndex === 0 ? 'th' : 'td'); tr.appendChild(cell);
        cell.style.textAlign = this.alignment(column);
        const preview = cell.appendChild(document.createElement('div')); preview.className = 'table-cell-preview'; preview.setAttribute('aria-hidden', 'true');
        const source = row.cells[column]?.text ?? '';
        binding.cells[rowIndex].push({ element: preview, source, dark: this.dark, cancel: presentCell(preview, source, this.dark, () => view.requestMeasure()) });
        const input = cell.appendChild(document.createElement('input'));
        input.value = row.cells[column]?.text ?? ''; input.readOnly = this.readOnly;
        input.dataset.row = String(rowIndex); input.dataset.column = String(column); input.style.textAlign = 'inherit';
        input.setAttribute('aria-label', tFor(this.locale, 'table.cell', { row: rowIndex + 1, column: column + 1 }));
        binding.inputs[rowIndex].push(input);
        let composing = false, firstInput = true;
        const commit = () => {
          if (view.state.readOnly) return;
          try {
            const current = binding.table;
            if (view.state.doc.sliceString(current.from, current.to) !== current.source) throw new TableError('stale');
            const target = rowIndex === 0 ? current.header : current.rows[rowIndex - 1];
            if (input.value !== (target.cells[column]?.text ?? '')) {
              view.dispatch({ changes: editCell(current, rowIndex, column, input.value), annotations: [Transaction.userEvent.of('input.type'), ...(firstInput ? [isolateHistory.of('before')] : [])] });
              firstInput = false;
            }
          } catch (error) { report(error); }
        };
        input.addEventListener('focus', () => {
          cell.classList.toggle('is-editing', !input.readOnly);
          firstInput = true;
          const target = rowIndex === 0 ? binding.table.header : binding.table.rows[rowIndex - 1];
          view.dispatch({ selection: { anchor: target.cells[column]?.from ?? target.to }, effects: focusTableCell.of({ tableFrom: binding.table.from, row: rowIndex, column }), annotations: Transaction.addToHistory.of(false) });
        });
        input.addEventListener('blur', () => { cell.classList.remove('is-editing'); });
        input.addEventListener('input', () => { if (!composing) commit(); });
        input.addEventListener('compositionstart', () => { composing = true; view.dispatch({ effects: changeComposition.of(true) }); });
        input.addEventListener('compositionend', () => { composing = false; commit(); view.dispatch({ effects: changeComposition.of(false) }); });
        input.addEventListener('keydown', event => {
          if (composing || event.isComposing || view.state.readOnly) return;
          if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'z') {
            event.preventDefault(); view.focus(); (event.shiftKey ? redo : undo)(view);
            const focus = view.state.field(tableCellFocus, false); if (focus) restoreCellFocus(view, focus);
          }
          if (event.key === 'Tab') {
            event.preventDefault();
            const width = binding.inputs[0].length, next = rowIndex * width + column + (event.shiftKey ? -1 : 1);
            if (next < 0) { view.focus(); view.dispatch({ selection: { anchor: binding.table.from } }); }
            else if (next >= binding.inputs.length * width) run('add-row');
            else { const target = binding.inputs[Math.floor(next / width)][next % width]; target.focus(); target.select(); }
          }
          if (event.key === 'Enter' || event.key === 'Escape') { event.preventDefault(); view.focus(); }
        });
      }
    });
    wrapper.append(status); return wrapper;
  }
  private alignment(column: number): 'left' | 'center' | 'right' {
    const delimiter = this.table.delimiter.cells[column]?.text ?? '';
    return delimiter.endsWith(':') ? delimiter.startsWith(':') ? 'center' : 'right' : 'left';
  }
  override updateDOM(dom: HTMLElement): boolean {
    const binding = bindings.get(dom)!;
    const rows = [this.table.header, ...this.table.rows];
    if (rows.length !== binding.inputs.length || this.table.header.cells.length !== binding.inputs[0].length) return false;
    binding.table = this.table; dom.dataset.tableFrom = String(this.table.from);
    dom.dataset.tableTo = String(this.table.to);
    if (binding.errorCode) binding.status.textContent = tFor(this.locale, `table.${binding.errorCode}`);
    rows.forEach((row, r) => binding.inputs[r].forEach((input, c) => {
      input.readOnly = this.readOnly; input.parentElement!.style.textAlign = this.alignment(c);
      input.parentElement!.classList.toggle('is-editing', input === document.activeElement && !input.readOnly);
      input.setAttribute('aria-label', tFor(this.locale, 'table.cell', { row: r + 1, column: c + 1 }));
      if (input !== document.activeElement || !this.preserveInput) input.value = row.cells[c]?.text ?? '';
      const cell = binding.cells[r][c], source = row.cells[c]?.text ?? '';
      if (cell.source !== source || cell.dark !== this.dark) {
        cell.cancel(); cell.source = source; cell.dark = this.dark;
        cell.cancel = presentCell(cell.element, source, this.dark, () => binding.view.requestMeasure());
      }
    }));
    return true;
  }
  override ignoreEvent(): boolean { return true; }
  override destroy(dom: HTMLElement): void { for (const row of bindings.get(dom)?.cells ?? []) for (const cell of row) cell.cancel(); bindings.delete(dom); }
}
function buildTables(state: EditorState, preserveInput = true): DecorationSet {
  if (state.field(modeState) === 'source') return Decoration.none;
  const match = selectedSearchMatch(state);
  const ranges: ReturnType<Decoration['range']>[] = [];
  syntaxTree(state).iterate({ enter(node) {
    if (node.name !== 'Table') return;
    if (state.doc.lineAt(node.from).from !== node.from) return false;
    // Reveal only a navigated match's table so its source selection and replace
    // remain visible. Opening search must not dismantle every rendered widget.
    if (match && match.from < node.to && match.to >= node.from) return false;
    ranges.push(Decoration.replace({ block: true, widget: new TableWidget(tableFromNode(node.node, (from, to) => state.doc.sliceString(from, to)), state.readOnly, state.facet(localeFacet), preserveInput, state.facet(EditorView.darkTheme)) }).range(node.from, node.to));
    return false;
  } });
  return Decoration.set(ranges, true);
}
export const tableView = StateField.define<DecorationSet>({
  create: buildTables,
  update(value, transaction) {
    if (transaction.state.field(compositionState)) return value.map(transaction.changes);
    if (transaction.startState.facet(EditorView.darkTheme) !== transaction.state.facet(EditorView.darkTheme) || transaction.startState.facet(localeFacet) !== transaction.state.facet(localeFacet) || selectedSearchMatch(transaction.startState) !== selectedSearchMatch(transaction.state) || transaction.startState.readOnly !== transaction.state.readOnly || transaction.docChanged || transaction.startState.field(modeState) !== transaction.state.field(modeState) || transaction.startState.field(compositionState) !== transaction.state.field(compositionState) || syntaxTree(transaction.startState) !== syntaxTree(transaction.state)) return buildTables(transaction.state, !transaction.docChanged || transaction.isUserEvent('input.type'));
    return value;
  },
  provide: field => [EditorView.decorations.from(field), EditorView.atomicRanges.of(view => view.state.field(field))],
});
