import { EditorState } from '@codemirror/state';
import { parser, GFM } from '@lezer/markdown';
import { sourceDocument } from '../../transactions/line-endings.ts';
import { mathSyntax } from './syntax.ts';
import { referenceSyntax } from '../references/syntax.ts';
import { linkDefinitions } from '../markdown/urls.ts';
import { sourceNode } from './model.ts';
import { footnoteBodies } from '../references/bodies.ts';

export function localImageSources(raw: string): string[] {
  const state = EditorState.create({ doc: sourceDocument(raw).doc });
  const tree = parser.configure([GFM, mathSyntax, referenceSyntax]).parse(state.doc.toString());
  const bodies = footnoteBodies(state, tree), definitions = linkDefinitions(state, tree, bodies), paths = new Set<string>();
  for (const input of [{ state, tree }, ...bodies]) input.tree.iterate({ enter(node) {
    if (['FencedCode', 'CodeBlock', 'InlineCode', 'InlineMath', 'MathBlock', 'FrontMatter', 'HTMLBlock', 'FootnoteDefinition'].includes(node.name)) return false;
    if (node.name !== 'Image') return;
    const image = sourceNode(input.state, node.node, definitions);
    if (image && !/^(?:https?:|data:)/i.test(image.text)) paths.add(image.text);
    return false;
  } });
  return [...paths];
}
