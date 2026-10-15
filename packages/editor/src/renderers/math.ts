import katex from 'katex';
import 'katex/dist/katex.min.css';
import type { RenderInput, RenderResult } from './previews.ts';
export async function render(input: RenderInput): Promise<RenderResult> {
  return renderSync(input);
}
/** KaTeX computes markup synchronously, before the widget's first layout. */
export function renderSync(input: RenderInput): RenderResult {
  const options = { displayMode: input.block, throwOnError: true, trust: false, strict: 'warn' as const, maxExpand: 1000, maxSize: 20 };
  const html = katex.renderToString(input.text, { ...options, macros: {}, output: 'htmlAndMathml' });
  const markup = katex.renderToString(input.text, { ...options, macros: {}, output: 'mathml' });
  const mathml = /<math[\s\S]*<\/math>/.exec(markup)?.[0];
  if (!mathml) throw new Error('MathML output is missing');
  return { html, mathml };
}
