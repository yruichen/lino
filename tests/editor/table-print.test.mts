import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { setupDOM } from './dom.mts';
const fixture = setupDOM();
after(() => fixture.dom.window.close());
const { splitTableForPrint } = await import('../../packages/editor/src/export/tables.ts');
function table() {
  const mount = fixture.mount();
  mount.innerHTML = '<table id="results"><thead><tr><th id="row">Row</th><th>First</th><th>Second</th><th>Third</th></tr></thead><tbody><tr><td><a id="label" href="#target">Alpha</a></td><td style="text-align:right"><strong>A</strong></td><td id="target">B</td><td>C</td></tr><tr><td></td><td>D</td><td>E</td><td>F</td></tr></tbody></table>';
  return { mount, element: mount.querySelector('table')! };
}
test('overwide print tables continue all rows in contiguous column groups with a repeated row label', () => {
  const { mount, element } = table();
  try {
    splitTableForPrint(element, [70, 90, 90, 90], 250);
    const tables = [...mount.querySelectorAll('table')];
    assert.equal(tables.length, 2);
    assert.deepEqual(tables.map(t => [...t.rows].map(r => [...r.cells].map(c => c.textContent))), [
      [['Row', 'First', 'Second'], ['Alpha', 'A', 'B'], ['', 'D', 'E']],
      [['Row', 'Third'], ['Alpha', 'C'], ['', 'F']],
    ]);
    assert.deepEqual(tables.map(t => t.caption!.textContent), ['Columns 1–3 of 4', 'Columns 1, 4 of 4']);
    assert.equal(tables[0].querySelector('td strong')?.textContent, 'A');
    assert.equal(tables[0].querySelector('td[style]')?.getAttribute('style'), 'text-align:right');
    assert.equal(mount.querySelectorAll('#results').length, 1);
    assert.equal(mount.querySelectorAll('#label').length, 1);
    assert.equal(mount.querySelectorAll('#target').length, 1);
    assert.equal(tables[1].querySelector('a')?.getAttribute('href'), '#target');
  } finally { mount.remove(); }
});
test('ordinary tables remain intact and long individual columns fit the available print width', () => {
  const ordinary = table(), wide = table();
  try {
    splitTableForPrint(ordinary.element, [30, 40, 40, 40], 250);
    assert.equal(ordinary.mount.querySelector('table'), ordinary.element);
    assert.equal(ordinary.element.caption, null);
    splitTableForPrint(wide.element, [1000, 1000, 80, 80], 250);
    const tables = [...wide.mount.querySelectorAll('table')];
    assert.equal(tables.length, 3);
    assert.deepEqual(tables.map(t => [...t.rows[0].cells].map(c => c.textContent)), [['Row', 'First'], ['Row', 'Second'], ['Row', 'Third']]);
    for (const t of tables) {
      const widths = [...t.querySelectorAll('col')].map(col => Number.parseFloat(col.style.width));
      assert(widths.every(width => width > 0));
      assert(Math.abs(widths.reduce((a, b) => a + b, 0) - 100) < 0.001);
    }
  } finally { ordinary.mount.remove(); wide.mount.remove(); }
});
test('one overwide column wraps without inventing a continuation or dropping content', () => {
  const mount = fixture.mount(); mount.innerHTML = '<table><thead><tr><th>Only</th></tr></thead><tbody><tr><td>LongURL</td></tr></tbody></table>';
  try {
    splitTableForPrint(mount.querySelector('table')!, [1000], 250);
    assert.equal(mount.querySelectorAll('table').length, 1);
    assert.equal(mount.querySelector('td')!.textContent, 'LongURL');
    assert.equal(mount.querySelector('caption'), null);
    assert.equal(mount.querySelector('table')!.style.tableLayout, 'fixed');
  } finally { mount.remove(); }
});

test('print continuation keeps page-sized row groups with their column widths and headings', async () => {
  const { splitTableRowsForPrint } = await import('../../packages/editor/src/export/tables.ts');
  const { mount, element } = table();
  try {
    element.insertAdjacentHTML('beforeend', '<colgroup><col style="width:20%"><col style="width:30%"><col style="width:30%"><col style="width:20%"></colgroup>');
    splitTableRowsForPrint(element, [60, 60], 40, 140, { width: 200, columns: [40, 60, 60, 40] });
    const tables = [...mount.querySelectorAll('table')];
    assert.equal(tables.length, 2);
    assert.deepEqual(tables.map(t => [...t.rows].map(r => [...r.cells].map(c => c.textContent))), [
      [['Row', 'First', 'Second', 'Third'], ['Alpha', 'A', 'B', 'C']],
      [['Row', 'First', 'Second', 'Third'], ['', 'D', 'E', 'F']],
    ]);
    assert(tables.every(t => t.style.breakInside === 'avoid' && t.querySelectorAll('col').length === 4));
    assert.equal(mount.querySelectorAll('#row').length, 1);
    assert.equal(mount.querySelectorAll('#results').length, 1);
  } finally { mount.remove(); }
});

test('a row taller than a complete paper content box fails before mutating the table', async () => {
  const { splitTableRowsForPrint } = await import('../../packages/editor/src/export/tables.ts');
  const { mount, element } = table(), before = element.outerHTML;
  try {
    assert.throws(() => splitTableRowsForPrint(element, [110, 20], 40, 140, { width: 200, columns: [40, 60, 60, 40] }), /printable page height/);
    assert.equal(element.outerHTML, before);
  } finally { mount.remove(); }
});

test('narrow long tables retain their measured column widths across row continuations', async () => {
  const { splitTableRowsForPrint } = await import('../../packages/editor/src/export/tables.ts');
  const { mount, element } = table();
  try {
    splitTableRowsForPrint(element, [60, 60], 40, 140, { width: 200, columns: [20, 60, 80, 40] });
    const tables = [...mount.querySelectorAll('table')];
    assert(tables.every(t => t.style.width === '200px' && t.style.tableLayout === 'fixed'));
    assert.deepEqual(tables.map(t => [...t.querySelectorAll('col')].map(c => c.style.width)), [['10%', '30%', '40%', '20%'], ['10%', '30%', '40%', '20%']]);
  } finally { mount.remove(); }
});
