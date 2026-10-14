import { Facet } from '@codemirror/state';
import type { EditorHostEvent } from '@lino/protocol/editor-host';
export const nativeAnalysisUI = Facet.define<boolean, boolean>({ combine: values => values[0] ?? false });
export const analysisEmitter = Facet.define<(event: EditorHostEvent) => void, ((event: EditorHostEvent) => void) | undefined>({ combine: values => values[0] });
