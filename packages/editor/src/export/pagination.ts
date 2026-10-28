import { Previewer } from 'pagedjs';
import { preparePrintTables } from './tables.ts';

interface Paper { width: number; height: number; top: number; right: number; bottom: number; left: number }
interface PageRect { top: number; left: number; width: number; height: number }
let cancelled = false;
export function cancel(): void { cancelled = true; }

/** Only loaded by the isolated native print surface, never by the editor. */
export async function paginate(paper: Paper): Promise<{ pages: number; rects: readonly PageRect[] }> {
  if (cancelled) throw new Error('Print preparation cancelled');
  if (![paper.width, paper.height, paper.top, paper.right, paper.bottom, paper.left].every(value => Number.isFinite(value) && value >= 0)
    || paper.width <= paper.left + paper.right || paper.height <= paper.top + paper.bottom) throw new Error('Invalid paper geometry');
  const color = getComputedStyle(document.documentElement).backgroundColor;
  const backdrop = document.querySelector<HTMLElement>('.export-backdrop');
  const image = backdrop?.querySelector('img');
  const source = image?.src;
  const opacity = backdrop ? Number(getComputedStyle(backdrop).opacity) : 0;
  if (source && (!/^data:image\/[a-z\d.+-]+;base64,[a-z\d+/=]+$/i.test(source) || !Number.isFinite(opacity) || opacity < 0 || opacity > 1)) throw new Error('Invalid print background');
  document.querySelector('.export-paper')?.remove(); backdrop?.remove();
  const settings = document.head.appendChild(document.createElement('style'));
  settings.textContent = `@page{size:${paper.width}pt ${paper.height}pt;margin:${paper.top}pt ${paper.right}pt ${paper.bottom}pt ${paper.left}pt;background:${color}}
    article{min-height:0;width:${(paper.width - paper.left - paper.right) * 4 / 3}px;max-width:100%;margin:0;padding:0;background:transparent}
    .pagedjs_page{box-sizing:border-box}
    .export-table-scroll{overflow:visible}td,th{overflow-wrap:anywhere}
    pre{white-space:pre-wrap;overflow:visible}thead{display:table-header-group}tr,img,svg{break-inside:avoid}`;
  await document.fonts.ready;
  if (cancelled) throw new Error('Print preparation cancelled');
  for (const article of document.querySelectorAll<HTMLElement>('article')) preparePrintTables(article, (paper.width - paper.left - paper.right) * 4 / 3, (paper.height - paper.top - paper.bottom) * 4 / 3);
  if (cancelled) throw new Error('Print preparation cancelled');
  const previewer = new Previewer();
  previewer.on('page', () => { if (cancelled) throw new Error('Print preparation cancelled'); });
  const flow = await previewer.preview();
  if (cancelled) throw new Error('Print preparation cancelled');
  const pages = [...document.querySelectorAll<HTMLElement>('.pagedjs_page')];
  if (!flow.total || pages.length !== flow.total) throw new Error('Incomplete print pagination');
  // Each page is a complete paper box. Background and content go through one
  // WebKit PDF page; no PDF underlay, annotation copying or image slicing.
  const style = document.head.appendChild(document.createElement('style'));
  style.textContent = `.pagedjs_page{position:relative}.pagedjs_sheet{position:relative;z-index:1}
    .export-page-background{position:absolute;inset:0;width:100%;height:100%;max-width:none;object-fit:cover;z-index:0;pointer-events:none}`;
  if (source && opacity > 0) for (const page of pages) {
    const background = document.createElement('img'); background.className = 'export-page-background';
    background.alt = ''; background.setAttribute('aria-hidden', 'true'); background.src = source; background.style.opacity = String(opacity);
    page.prepend(background);
  }
  await Promise.all([...document.images].map(image => image.decode().then(() => {
    if (!image.complete) throw new Error('Print image did not settle');
    return image;
  })));
  await document.fonts.ready;
  if (cancelled) throw new Error('Print preparation cancelled');
  const rects: PageRect[] = pages.map(page => {
    const rect = page.getBoundingClientRect();
    return { top: rect.top, left: rect.left, width: rect.width, height: rect.height };
  });
  if (rects.some(rect => ![rect.top, rect.left, rect.width, rect.height].every(Number.isFinite) || rect.width <= 0 || rect.height <= 0)) throw new Error('Invalid print page geometry');
  return { pages: flow.total, rects };
}
