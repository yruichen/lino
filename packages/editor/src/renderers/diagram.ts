import mermaid from 'mermaid';
import type { RenderInput, RenderResult } from './previews.ts';
let sequence = 0;
export async function render(input: RenderInput): Promise<RenderResult> {
  mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: input.dark ? 'dark' : 'default', htmlLabels: false,
    maxTextSize: 50_000, maxEdges: 500, flowchart: { htmlLabels: false },
    secure: ['securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'htmlLabels', 'flowchart', 'theme', 'themeCSS', 'themeVariables'] });
  const container = document.createElement('div'); container.style.position = 'absolute'; container.style.left = '-100000px'; document.body.append(container);
  try {
    const rendered = await mermaid.render(`ot-diagram-${++sequence}`, input.text, container);
    const doc = new DOMParser().parseFromString(rendered.svg, 'image/svg+xml');
    if (doc.querySelector('parsererror') || doc.documentElement.localName !== 'svg') throw new Error('Invalid diagram SVG');
    for (const element of doc.querySelectorAll('script, foreignObject, image')) element.remove();
    for (const element of doc.querySelectorAll('a')) element.replaceWith(...Array.from(element.childNodes));
    for (const element of doc.querySelectorAll('*')) for (const attribute of [...element.attributes]) {
      if (attribute.name.toLowerCase().startsWith('on') || (/href$/i.test(attribute.name) && !attribute.value.startsWith('#'))) element.removeAttribute(attribute.name);
    }
    const svg = new XMLSerializer().serializeToString(doc.documentElement); return { html: svg, svg };
  } finally { container.remove(); }
}
