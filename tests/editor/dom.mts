import { JSDOM } from 'jsdom';
import { registerHooks } from 'node:module';

// Node DOM fixtures exercise event/state ownership without launching the app or
// taking system focus. Geometry and real IME/rendering require separate acceptance.
registerHooks({ load(url, context, next) {
  if (url.endsWith('.css')) return { format: 'module', source: '', shortCircuit: true };
  return next(url, context);
} });
export function setupDOM() {
  const dom = new JSDOM('<!doctype html><body></body>', { pretendToBeVisual: true });
  const win = dom.window;
  for (const name of ['window', 'Window', 'document', 'navigator', 'HTMLElement', 'HTMLInputElement', 'HTMLTextAreaElement', 'HTMLSelectElement', 'Element', 'Node', 'Text', 'MutationObserver', 'DOMRect', 'KeyboardEvent', 'Event', 'Range'] as const) {
    Object.defineProperty(globalThis, name, { configurable: true, writable: true, value: name === 'window' ? win : win[name] });
  }
  const media = () => ({ matches: false, media: '', onchange: null, addEventListener() {}, removeEventListener() {}, addListener() {}, removeListener() {}, dispatchEvent() { return true; } });
  Object.defineProperty(win, 'matchMedia', { value: media });
  Object.defineProperty(globalThis, 'matchMedia', { configurable: true, value: media });
  Object.defineProperty(globalThis, 'getComputedStyle', { configurable: true, value: win.getComputedStyle.bind(win) });
  for (const name of ['innerWidth', 'innerHeight'] as const) Object.defineProperty(globalThis, name, { configurable: true, get: () => win[name] });
  Object.defineProperty(globalThis, 'requestAnimationFrame', { configurable: true, value: win.requestAnimationFrame.bind(win) });
  Object.defineProperty(globalThis, 'cancelAnimationFrame', { configurable: true, value: win.cancelAnimationFrame.bind(win) });
  Object.defineProperty(win.Range.prototype, 'getClientRects', { value: () => [] });
  Object.defineProperty(win.Range.prototype, 'getBoundingClientRect', { value: () => new win.DOMRect() });
  return { dom, mount: () => win.document.body.appendChild(win.document.createElement('section')) };
}
export const settleDOM = async () => { await new Promise(resolve => setTimeout(resolve, 25)); };
