import { Facet } from '@codemirror/state';
import type { EditorView } from '@codemirror/view';
import type { ComponentContext } from '@lino/protocol/editor-host';

export const componentMenus = Facet.define<(context: ComponentContext, x: number, y: number, imageScale?: number) => void>();
export function componentMenu(view: EditorView, context: ComponentContext, event: MouseEvent, imageScale?: number): void {
  const present = view.state.facet(componentMenus)[0];
  if (!present) return;
  event.preventDefault(); event.stopPropagation(); present(context, event.clientX, event.clientY, imageScale);
}
