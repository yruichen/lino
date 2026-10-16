import { normalizeLocale, tFor } from '../localization/index.ts';

/** Continue a rectangular Markdown table across column groups, preserving rows.
 * Widths include cell borders/padding and come from one intrinsic table layout.
 * Only the leading row-label column is duplicated; no content is rasterized. */
export function splitTableForPrint(table: HTMLTableElement, widths: readonly number[], available: number): void {
  if (!widths.length || !Number.isFinite(available) || available <= 0
      || widths.some(width => !Number.isFinite(width) || width <= 0)
      || [...table.rows].some(row => row.cells.length !== widths.length)) throw new Error('Invalid print table geometry');
  if (widths.reduce((sum, width) => sum + width, 0) <= available) return;
  // A group needs room for both its row label and at least one data column.
  // Overlong tokens wrap within those allocated cells, without changing font size.
  const first = Math.min(widths[0], widths.length > 1 ? available / 2 : available);
  const fitted = widths.map((width, index) => index === 0 ? first : Math.min(width, available - first));
  const groups: number[][] = [];
  let columns = [0], used = first;
  for (let column = 1; column < widths.length; column++) {
    if (columns.length > 1 && used + fitted[column] > available) { groups.push(columns); columns = [0]; used = first; }
    columns.push(column); used += fitted[column];
  }
  groups.push(columns);
  if (groups.length === 1) {
    table.style.width = '100%'; table.style.tableLayout = 'fixed';
    setColumns(table, groups[0], fitted); return;
  }
  const output = table.ownerDocument.createDocumentFragment(), ids = new Set<string>();
  for (const group of groups) {
    const next = table.cloneNode(false) as HTMLTableElement;
    next.style.width = '100%'; next.style.tableLayout = 'fixed';
    const caption = next.createCaption();
    const last = group[group.length - 1] + 1;
    const range = group[1] === 1 ? `1–${last}` : `1, ${group[1] + 1}${group.length > 2 ? `–${last}` : ''}`;
    const label = tFor(normalizeLocale(table.ownerDocument.documentElement.lang), 'export.tableColumns', { range, total: widths.length });
    if (table.caption) { caption.append(...[...table.caption.childNodes].map(node => node.cloneNode(true)), table.ownerDocument.createElement('br')); }
    caption.append(label);
    setColumns(next, group, fitted);
    for (const section of [...table.children]) {
      if (!['THEAD', 'TBODY', 'TFOOT'].includes(section.tagName)) continue;
      const copy = section.cloneNode(false) as HTMLTableSectionElement;
      for (const row of [...(section as HTMLTableSectionElement).rows]) {
        const copiedRow = row.cloneNode(false) as HTMLTableRowElement;
        for (const column of group) copiedRow.append(row.cells[column].cloneNode(true));
        copy.append(copiedRow);
      }
      next.append(copy);
    }
    // Continuations retain link destinations only on the first occurrence.
    for (const element of [next, ...next.querySelectorAll<HTMLElement>('[id]')]) {
      if (!element.id) continue;
      if (ids.has(element.id)) element.removeAttribute('id'); else ids.add(element.id);
    }
    output.append(next);
  }
  table.replaceWith(output);
}
function setColumns(table: HTMLTableElement, columns: readonly number[], widths: readonly number[]): void {
  table.querySelectorAll(':scope > colgroup').forEach(group => group.remove());
  const group = table.ownerDocument.createElement('colgroup');
  const total = columns.reduce((sum, column) => sum + widths[column], 0);
  for (const column of columns) {
    const col = table.ownerDocument.createElement('col'); col.style.width = `${widths[column] / total * 100}%`; group.append(col);
  }
  table.insertBefore(group, table.querySelector(':scope > thead, :scope > tbody, :scope > tfoot'));
}

/** One temporary intrinsic-layout clone per table, only during fixed output.
 * DOM work is proportional to source cells plus repeated row-label cells. */
export function preparePrintTables(article: HTMLElement, available: number, pageHeight: number): void {
  for (const table of article.querySelectorAll<HTMLTableElement>('table')) {
    const probe = table.cloneNode(true) as HTMLTableElement;
    probe.classList.add('export-table-measure');
    probe.style.cssText = 'position:absolute;visibility:hidden;width:min-content;max-width:none;table-layout:auto';
    probe.querySelectorAll<HTMLElement>('td,th').forEach(cell => { cell.style.overflowWrap = 'normal'; });
    table.after(probe);
    try {
      const widths = [...probe.rows[0].cells].map(cell => cell.getBoundingClientRect().width);
      const edge = Math.max(0, probe.getBoundingClientRect().width - widths.reduce((sum, width) => sum + width, 0));
      splitTableForPrint(table, widths, available - edge);
    } finally { probe.remove(); }
  }
  // Layout all column groups at their final paper width before reading rows.
  for (const table of article.querySelectorAll<HTMLTableElement>('table')) {
    const rows = [...table.tBodies].flatMap(body => [...body.rows]);
    const heights = rows.map(row => row.getBoundingClientRect().height);
    const overhead = Math.max(0, table.getBoundingClientRect().height - heights.reduce((sum, height) => sum + height, 0));
    splitTableRowsForPrint(table, heights, overhead, pageHeight, { width: table.getBoundingClientRect().width, columns: [...table.rows[0].cells].map(cell => cell.getBoundingClientRect().width) });
  }
}

/** Paged.js 0.4.3 shallow-clones table ancestors on vertical continuation,
 * losing headings/columns; WebKit may also fragment a boundary row across its
 * temporary columns before the library sees overflow. Give it complete tables
 * that fit one content box instead of relying on that lossy table split. */
export function splitTableRowsForPrint(table: HTMLTableElement, heights: readonly number[], overhead: number, available: number, geometry: { width: number; columns: readonly number[] }): void {
  const rows = [...table.tBodies].flatMap(body => [...body.rows]);
  if (rows.length !== heights.length || !Number.isFinite(overhead) || overhead < 0
      || !Number.isFinite(available) || available <= overhead
      || heights.some(height => !Number.isFinite(height) || height <= 0 || height + overhead > available)) throw new Error('A table row exceeds the printable page height');
  table.style.breakInside = 'avoid';
  if (heights.reduce((sum, height) => sum + height, overhead) <= available) return;
  // Only vertically split tables need fixed columns. Keep ordinary short
  // tables in their natural layout and preserve a narrow table's actual width.
  table.style.width = `${geometry.width}px`; table.style.tableLayout = 'fixed';
  setColumns(table, geometry.columns.map((_, index) => index), geometry.columns);
  const groups: HTMLTableRowElement[][] = [];
  let group: HTMLTableRowElement[] = [], used = overhead;
  rows.forEach((row, index) => {
    if (group.length && used + heights[index] > available) { groups.push(group); group = []; used = overhead; }
    group.push(row); used += heights[index];
  });
  if (group.length) groups.push(group);
  const output = table.ownerDocument.createDocumentFragment();
  groups.forEach((rows, index) => {
    const next = table.cloneNode(false) as HTMLTableElement;
    for (const child of table.children) if (child.tagName !== 'TBODY') next.append(child.cloneNode(true));
    if (index > 0) for (const node of [next, ...next.querySelectorAll('[id]')]) node.removeAttribute('id');
    const body = next.createTBody(); body.append(...rows); output.append(next);
  });
  table.replaceWith(output);
}
