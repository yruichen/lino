import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { PreviewRenderer, PreviewError, type RenderInput } from '../../packages/editor/src/renderers/previews.ts';
import { setupDOM } from './dom.mts';
const fixture = setupDOM(); after(() => fixture.dom.window.close());
const { render: math } = await import('../../packages/editor/src/renderers/math.ts');
const input = (text: string, dark = false): RenderInput => ({ kind: 'math', text, block: false, dark });
test('real KaTeX returns display HTML and MathML; errors and untrusted HTML cannot become markup', async () => {
  const result = await math(input('\\frac{a}{b}')); assert.match(result.html, /katex/); assert.match(result.mathml!, /^<math/); assert.match(result.mathml!, /<mfrac/);
  await assert.rejects(math(input('\\notARealCommand{')));
  const untrusted = await math(input('\\href{javascript:alert(1)}{x}')); assert.doesNotMatch(untrusted.html, /<a |href="javascript:/);
  const macro = await math(input('\\gdef\\foo{x}\\foo')); assert.match(macro.html, /katex/);
  await assert.rejects(math(input('\\foo'))); // no macros leak into another block.
});
test('preview queue serializes renderer config, rejects saturation and never caches cancelled results', async () => {
  let release!: () => void, calls = 0, active = 0, max = 0;
  const queue = new PreviewRenderer(async item => {
    calls++; max = Math.max(max, ++active); if (calls === 1) await new Promise<void>(resolve => { release = resolve; }); active--;
    return { html: item.text };
  });
  const controller = new AbortController(), first = queue.request(input('a'), controller.signal);
  const cancelled = assert.rejects(first, (error: unknown) => error instanceof PreviewError && error.reason === 'cancelled');
  const later = Array.from({ length: 24 }, (_, index) => queue.request(input(String(index)), new AbortController().signal));
  await assert.rejects(queue.request(input('overflow'), new AbortController().signal), (error: unknown) => error instanceof PreviewError && error.reason === 'busy');
  controller.abort(); release(); await cancelled; await Promise.all(later); assert.equal(max, 1);
  const old = calls; await queue.request(input('a'), new AbortController().signal); assert.equal(calls, old + 1);
  await queue.request(input('a'), new AbortController().signal); assert.equal(calls, old + 1);
  await queue.request(input('a', true), new AbortController().signal); assert.equal(calls, old + 2);
  await assert.rejects(queue.request(input('x'.repeat(50_001)), new AbortController().signal));
});
test('real Mermaid renders SVG for flow and sequence, strips navigation and cleans up errors (synthetic geometry only)', async () => {
  const win = fixture.dom.window;
  for (const name of ['DOMParser', 'XMLSerializer', 'SVGElement', 'SVGSVGElement', 'DocumentFragment', 'CSSStyleSheet', 'getComputedStyle'] as const) {
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value: name === 'getComputedStyle' ? win.getComputedStyle.bind(win) : win[name] });
  }
  Object.defineProperty(win.SVGElement.prototype, 'getBBox', { configurable: true, value: () => ({ x: 0, y: 0, width: 100, height: 20 }) });
  Object.defineProperty(win.SVGElement.prototype, 'getComputedTextLength', { configurable: true, value: () => 100 });
  const { render } = await import('../../packages/editor/src/renderers/diagram.ts');
  const renderDiagram = (text: string, dark = false) => render({ kind: 'diagram', text, block: true, dark });
  const flow = await renderDiagram('flowchart LR\n A[Start] --> B[End]\n click A "https://example.invalid"');
  assert.match(flow.svg!, /<svg/); assert.match(flow.svg!, /Start/); assert.doesNotMatch(flow.svg!, /<script|<foreignObject|<a[ >]|href="https:/);
  const sequence = await renderDiagram('sequenceDiagram\n Alice->>Bob: Hello', true); assert.match(sequence.svg!, /Alice/); assert.match(sequence.svg!, /Hello/);
  await assert.rejects(renderDiagram('not-a-diagram {')); assert.equal(document.querySelector('[id^=ot-diagram]'), null);
});
