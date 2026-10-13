import { localizeError } from '../localization/index.ts';
import type { WireChange } from '@lino/protocol/generated/WireChange';
const encoder = new TextEncoder();
function boundary(text: string, at: number): boolean {
  if (at <= 0 || at >= text.length) return true;
  const before = text.charCodeAt(at - 1), after = text.charCodeAt(at);
  return !(before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff) && !(before === 13 && after === 10);
}
// A batch compares the acknowledged snapshot with the current source. No AST
// serialization, per-keystroke full-document IPC, or second editable model.
export function sourceChanges(previous: string, next: string): WireChange[] {
  if (/[\uD800-\uDFFF]/u.test(next)) throw localizeError(new Error(), 'document.invalidUnicode');
  if (previous === next) return [];
  let start = 0;
  while (start < previous.length && start < next.length && previous[start] === next[start]) start++;
  while (!boundary(previous, start) || !boundary(next, start)) start--;
  let oldEnd = previous.length, newEnd = next.length;
  while (oldEnd > start && newEnd > start && previous[oldEnd - 1] === next[newEnd - 1]) { oldEnd--; newEnd--; }
  while (!boundary(previous, oldEnd) || !boundary(next, newEnd)) { oldEnd++; newEnd++; }
  return [{ from: encoder.encode(previous.slice(0, start)).length, to: encoder.encode(previous.slice(0, oldEnd)).length, insert: next.slice(start, newEnd) }];
}
