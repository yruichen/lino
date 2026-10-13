import { MapMode, RangeSet, RangeValue, StateEffect, StateField, Text, type EditorState } from '@codemirror/state';
import { invertedEffects } from '@codemirror/commands';

class LineEnding extends RangeValue {
  override mapMode = MapMode.TrackDel;
  override startSide = 1;
  override endSide = 1;
  override point = true;
  readonly text: string;
  constructor(text: string) { super(); this.text = text; }
  override eq(other: LineEnding): boolean { return this.text === other.text; }
}

// The engine edits LF coordinates; original line endings are mapped through
// the same transactions. Formatting metadata is not a second document/undo.
export function sourceDocument(raw: string) {
  const endings: ReturnType<LineEnding['range']>[] = [];
  let source = '', offset = 0, preferred = '\n';
  for (const match of raw.matchAll(/\r\n|\r|\n/g)) {
    source += raw.slice(offset, match.index);
    if (!endings.length) preferred = match[0];
    endings.push(new LineEnding(match[0]).range(source.length));
    source += '\n';
    offset = match.index! + match[0].length;
  }
  source += raw.slice(offset);
  const restore = StateEffect.define<RangeSet<LineEnding>>({ map: (value, changes) => value.map(changes) });
  const field = StateField.define<RangeSet<LineEnding>>({
    create: () => RangeSet.of(endings),
    update(value, transaction) {
      for (const effect of transaction.effects) if (effect.is(restore)) return effect.value;
      if (!transaction.docChanged) return value;
      const add: ReturnType<LineEnding['range']>[] = [];
      const removed: { from: number; to: number }[] = [];
      transaction.changes.iterChanges((fromA, toA, fromB, _toB, inserted) => {
        if (fromA < toA) removed.push({ from: fromA, to: toA });
        const text = inserted.toString();
        for (let i = 0; i < text.length; i++) {
          if (text[i] === '\n') add.push(new LineEnding(preferred).range(fromB + i));
        }
      });
      // TrackDel retains a point at a deletion's leading boundary. A removed
      // newline must be discarded before mapping, or it can collide with a
      // surviving newline and serialize twice at the same position.
      if (removed.length) value = value.update({
        filterFrom: removed[0].from, filterTo: removed.at(-1)!.to,
        filter: from => {
          let low = 0, high = removed.length;
          while (low < high) {
            const middle = (low + high) >>> 1;
            if (removed[middle].to <= from) low = middle + 1; else high = middle;
          }
          return low === removed.length || from < removed[low].from;
        },
      });
      return value.map(transaction.changes).update({ add, sort: true });
    },
  });
  return {
    doc: Text.of(source.split('\n')),
    extension: [field, invertedEffects.of(transaction => transaction.docChanged ? [restore.of(transaction.startState.field(field))] : [])],
    read(state: EditorState): string {
      const pieces: string[] = [];
      const ledger = state.field(field);
      let start = 0;
      ledger.between(0, state.doc.length, (from, _to, value) => {
        // Mapping a deletion must never resurrect a removed line break.
        if (state.doc.sliceString(from, from + 1) !== '\n') return;
        pieces.push(state.doc.sliceString(start, from), value.text);
        start = from + 1;
      });
      pieces.push(state.doc.sliceString(start));
      return pieces.join('');
    },
  };
}
