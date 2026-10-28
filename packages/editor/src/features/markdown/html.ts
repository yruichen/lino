import MarkdownIt from 'markdown-it';
import DOMPurify from 'dompurify';
import { WidgetType } from '@codemirror/view';
import { t } from '../../localization/index.ts';

const markdown = new MarkdownIt({ html: true, linkify: false, typographer: false });
const voidTags = new Set(['area', 'base', 'br', 'col', 'embed', 'hr', 'img', 'input', 'link', 'meta', 'param', 'source', 'track', 'wbr']);
const safeURL = (url: string) => !/^[\s\u0000-\u001f]*\/\//.test(url)
  && (!/^[a-z][a-z\d+.-]*:/i.test(url) || /^(?:https?:|mailto:|data:image\/)/i.test(url));

export function replaceParsedHTML(root: Element, html: string): void {
  const Parser = document.defaultView?.DOMParser;
  if (!Parser) throw new Error(t('export.invalid'));
  const parsed = new Parser().parseFromString(`<body>${html}</body>`, 'text/html');
  root.replaceChildren(...Array.from(parsed.body.childNodes).map(node => document.importNode(node, true)));
}

export function sanitizeHTML(source: string, inline: boolean): string {
  const sanitized = String(DOMPurify.sanitize(source, {
    USE_PROFILES: { html: true },
    ALLOWED_TAGS: [
      'a', 'abbr', 'b', 'blockquote', 'br', 'caption', 'cite', 'code', 'col', 'colgroup', 'dd', 'del', 'details', 'div', 'dl', 'dt',
      'em', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'i', 'img', 'ins', 'kbd', 'li', 'mark', 'ol', 'p', 'pre', 'q', 's', 'small',
      'span', 'strong', 'sub', 'summary', 'sup', 'table', 'tbody', 'td', 'tfoot', 'th', 'thead', 'tr', 'u', 'ul',
    ],
    ALLOWED_ATTR: [
      'alt', 'aria-hidden', 'aria-label', 'class', 'cite', 'colspan', 'datetime', 'dir', 'height', 'href', 'id', 'lang', 'open', 'rel',
      'role', 'rowspan', 'scope', 'src', 'start', 'target', 'title', 'width',
    ],
    FORBID_ATTR: ['style', 'srcset'],
    FORBID_TAGS: ['audio', 'canvas', 'embed', 'form', 'iframe', 'object', 'script', 'style', 'svg', 'template', 'video'],
    ALLOW_DATA_ATTR: false,
    ADD_ATTR: inline ? ['data-math-from'] : [],
  }));
  const root = document.createElement(inline ? 'span' : 'div');
  replaceParsedHTML(root, sanitized);
  for (const element of root.querySelectorAll<HTMLElement>('*')) {
    if (element.tagName === 'A') {
      const href = element.getAttribute('href') ?? '';
      if (!safeURL(href)) element.removeAttribute('href');
      else {
        element.setAttribute('data-lino-html-link', href);
        element.setAttribute('rel', 'noopener noreferrer');
        element.removeAttribute('target');
      }
    }
    if (element.tagName === 'IMG') {
      const src = element.getAttribute('src') ?? '';
      if (!/^data:image\/[a-z\d.+-]+;base64,[a-z\d+/=]+$/i.test(src)) element.removeAttribute('src');
    }
  }
  return root.innerHTML;
}

/** Replace generated or already-sanitized markup without exposing an innerHTML sink. */
export function replaceChildrenWithSafeHTML(root: Element, html: string): void {
  const sanitized = String(DOMPurify.sanitize(html, {
    USE_PROFILES: { html: true, svg: true, svgFilters: true, mathMl: true },
    FORBID_TAGS: ['script', 'iframe', 'object', 'embed', 'form', 'style', 'template', 'audio', 'video', 'canvas'],
    FORBID_ATTR: ['srcset'], ALLOW_DATA_ATTR: false, ADD_ATTR: ['data-math-from'],
  }));
  replaceParsedHTML(root, sanitized);
}

/** Render raw HTML without allowing scripts, styles, active embeds or remote resources. */
export function renderHTML(source: string, block: boolean): string {
  const rendered = block ? markdown.render(source) : markdown.renderInline(source);
  return sanitizeHTML(rendered, !block);
}

export function inlineHTMLRange(source: string, from: number, to: number): { from: number; to: number } | undefined {
  const tag = source.slice(from, to);
  const opening = /^<([A-Za-z][\w:.-]*)(?:\s[\s\S]*?)?\/?\s*>$/.exec(tag);
  if (!opening || /^<\//.test(tag)) return undefined;
  const name = opening[1].toLowerCase();
  if (voidTags.has(name) || /\/\s*>$/.test(tag)) return { from, to };
  const closingPrefix = `</${name}`, lowerSource = source.toLowerCase();
  let closingStart = lowerSource.indexOf(closingPrefix, to), closingLength = 0;
  while (closingStart >= 0) {
    const suffix = /^\s*>/.exec(source.slice(closingStart + closingPrefix.length));
    if (suffix) { closingLength = closingPrefix.length + suffix[0].length; break; }
    closingStart = lowerSource.indexOf(closingPrefix, closingStart + closingPrefix.length);
  }
  if (closingStart < 0) return undefined;
  const end = closingStart + closingLength;
  if (source.slice(from, end).includes('\n')) return undefined;
  return { from, to: end };
}

export class HTMLWidget extends WidgetType {
  readonly source: string;
  readonly block: boolean;
  readonly from: number;
  readonly to: number;
  constructor(source: string, block: boolean, from: number, to: number) {
    super(); this.source = source; this.block = block; this.from = from; this.to = to;
  }
  override eq(other: HTMLWidget): boolean { return this.source === other.source && this.block === other.block && this.from === other.from && this.to === other.to; }
  override toDOM(): HTMLElement {
    const root = document.createElement(this.block ? 'div' : 'span');
    root.className = this.block ? 'ot-html-block' : 'ot-html-inline';
    root.dataset.htmlFrom = String(this.from); root.dataset.htmlTo = String(this.to);
    root.tabIndex = 0; root.setAttribute('aria-label', t('html.preview'));
    const html = renderHTML(this.source, this.block);
    if (html) replaceChildrenWithSafeHTML(root, html);
    else {
      root.classList.add('ot-html-suppressed');
      root.textContent = this.source;
      root.title = t('html.unsafe');
    }
    return root;
  }
  override ignoreEvent(): boolean { return false; }
}
