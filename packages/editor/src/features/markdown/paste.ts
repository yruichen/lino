const safeURL = (url: string): boolean => !/^[\s\u0000-\u001f]*\/\//.test(url)
  && (!/^[a-z][a-z\d+.-]*:/i.test(url) || /^(?:https?:|mailto:)/i.test(url));

function escapeText(value: string): string {
  return value.replace(/[\\`*_[\]{}#+.!|<>-]/g, '\\$&');
}

function inline(node: Node): string {
  if (node.nodeType === Node.TEXT_NODE) return escapeText(node.nodeValue ?? '');
  if (!(node instanceof Element)) return '';
  const content = Array.from(node.childNodes).map(inline).join('');
  switch (node.tagName.toLowerCase()) {
    case 'strong': case 'b': return `**${content.trim()}**`;
    case 'em': case 'i': return `*${content.trim()}*`;
    case 'del': case 's': return `~~${content.trim()}~~`;
    case 'code': return `\`${(node.textContent ?? '').replace(/`/g, '\\`')}\``;
    case 'br': return '\n';
    case 'a': {
      const href = node.getAttribute('href') ?? '';
      return safeURL(href) ? `[${content.trim()}](${href.replace(/[()\\]/g, '\\$&')})` : content;
    }
    case 'img': return node.getAttribute('alt') ? `![${escapeText(node.getAttribute('alt')!)}]()` : '';
    default: return content;
  }
}

function block(node: Node, depth = 0): string {
  if (node.nodeType === Node.TEXT_NODE) return escapeText(node.nodeValue ?? '').trim();
  if (!(node instanceof Element)) return '';
  const tag = node.tagName.toLowerCase();
  if (tag === 'script' || tag === 'style' || tag === 'iframe' || tag === 'object' || tag === 'embed' || tag === 'form') return '';
  if (/^h[1-6]$/.test(tag)) return `${'#'.repeat(Number(tag[1]))} ${inline(node).trim()}`;
  if (tag === 'p') return inline(node).trim();
  if (tag === 'div' || tag === 'section' || tag === 'article') {
    return Array.from(node.childNodes).map(child => block(child, depth)).filter(Boolean).join('\n\n');
  }
  if (tag === 'blockquote') return inline(node).trim().split('\n').map(line => `> ${line}`).join('\n');
  if (tag === 'pre') return `\`\`\`\n${node.textContent ?? ''}\n\`\`\``;
  if (tag === 'hr') return '---';
  if (tag === 'ul' || tag === 'ol') {
    let index = 1;
    return Array.from(node.children).filter(child => child.tagName.toLowerCase() === 'li').map(child => {
      const marker = tag === 'ol' ? `${index++}.` : '-';
      return `${'  '.repeat(depth)}${marker} ${inline(child).trim()}`;
    }).join('\n');
  }
  if (tag === 'li') return inline(node).trim();
  if (tag === 'table') {
    const rows = Array.from(node.querySelectorAll('tr')).map(row => Array.from(row.children).map(cell => inline(cell).trim().replace(/\|/g, '\\|')).join(' | '));
    if (!rows.length) return '';
    const columns = rows[0].split(' | ').length;
    return [`| ${rows[0]} |`, `| ${Array.from({ length: columns }, () => '---').join(' | ')} |`, ...rows.slice(1).map(row => `| ${row} |`)].join('\n');
  }
  return inline(node).trim();
}

/** Convert common rich-text clipboard markup to Markdown without executing it. */
export function htmlToMarkdown(source: string): string | undefined {
  if (!source.trim() || typeof document === 'undefined') return undefined;
  const Parser = document.defaultView?.DOMParser;
  if (!Parser) return undefined;
  const body = new Parser().parseFromString(source, 'text/html').body;
  const result = Array.from(body.childNodes).map(node => block(node)).filter(Boolean).join('\n\n').trim();
  return result || undefined;
}
