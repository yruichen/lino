import assert from 'node:assert/strict';
import { after, test } from 'node:test';
import { setupDOM } from './dom.mts';
const fixture = setupDOM();
const { ExportPlan } = await import('../../packages/editor/src/export/html.ts');
const { PreviewRenderer } = await import('../../packages/editor/src/renderers/previews.ts');
const { render: math } = await import('../../packages/editor/src/renderers/math.ts');
after(() => fixture.dom.window.close());
const prefs = { language: 'en', theme: 'system', theme_family: 'paper', custom_themes: [], body_font: '', background_image: '', background_opacity: 20, surface_opacity: 100, glass_style: 'solid', image_insertion: 'reference', use_theme_font_size: false, use_theme_line_height: false, auto_save: false, font_size: 17, line_height: 170, page_width: 820, content_width: 'adaptive', spell_check: false, continue_lists: true, code_wrap: true, code_numbers: false };
const source = (text: string) => ({ job_id: '1', session_id: '1', revision: '3', text, label: '测试.md', preferences: prefs });
test('fixed HTML renders structure, shared images, footnotes, TOC, actual math and nested extensions without executing literal HTML/code', async () => {
  const raw = '---\ntitle: hidden\n---\n\n# 标题\n\n[TOC]\n\n==**强调🙂** ^上标^ $x+1$[^n]== and ~下标~.\n\n- [x] done\n- [ ] later\n\n| A | B |\n| - | - |\n| 一 | 二 |\n\n![图][img]\n\n[img]: <assets/image.svg> "Title"\n\n[^n]: First note\n[^n]: Ignored duplicate\n\n```rust\nlet x = 1; // $literal$\n```\n\n<script>alert(1)</script>\n';
  const renderer = new PreviewRenderer(math), plan = new ExportPlan(source(raw), renderer);
  assert.deepEqual(plan.images, ['assets/image.svg']);
  const svg = 'data:image/svg+xml;base64,' + Buffer.from('<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12"><rect width="12" height="12"/></svg>').toString('base64');
  const html = await plan.render({ 'assets/image.svg': svg });
  const doc = new fixture.dom.window.DOMParser().parseFromString(html, 'text/html');
  assert.equal(doc.title, '测试.md'); assert(doc.querySelector('h1#标题')); assert.equal(doc.querySelector('.contents a')?.getAttribute('href'), '#标题');
  assert(doc.querySelector('mark strong')); assert.equal(doc.querySelector('mark sup')?.textContent, '上标'); assert(doc.querySelector('mark math')); assert(doc.querySelector('sub'));
  assert.equal(doc.querySelectorAll('input[type=checkbox]').length, 2); assert.equal(doc.querySelectorAll('input[checked]').length, 1);
  assert(doc.querySelector('table')); assert.equal(doc.querySelector('img')?.getAttribute('src'), svg); assert.equal(doc.querySelector('.image-caption')?.textContent, 'Title');
  assert.equal(doc.querySelector('.footnote-item p')?.textContent?.includes('First note'), true); assert(!doc.body.textContent!.includes('Ignored duplicate'));
  assert(!doc.body.textContent!.includes('title: hidden')); assert.equal(doc.querySelectorAll('script').length, 0);
  assert(doc.querySelector('pre code')?.textContent!.includes('$literal$')); assert(doc.querySelector('pre .tok-keyword'));
  assert(!html.includes('lino-slot:')); assert.equal(plan.source.text, raw);
});
test('missing images, remote image policy, renderer failure and cancellation cannot produce a partial successful export', async () => {
  await assert.rejects(new ExportPlan(source('![x](missing.png)')).render({}), /embed image/);
  assert.throws(() => new ExportPlan(source('![remote](https://example.org/a.png)')), /remote images/);
  const cancelled = new ExportPlan(source('$x$')); cancelled.cancel(); await assert.rejects(cancelled.render({}), /cancelled/);
  const failing = new ExportPlan(source('$invalid$'), new PreviewRenderer(async () => { throw new Error('renderer failed'); }));
  await assert.rejects(failing.render({}), /renderer failed/);
});
test('diagram rendering and late cancellation use the same bounded preview renderer', async () => {
  const input: unknown[] = [];
  const renderer = new PreviewRenderer(async value => { input.push(value); return { html: '<svg xmlns="http://www.w3.org/2000/svg"><text>actual diagram result</text></svg>' }; });
  const plan = new ExportPlan(source('```mermaid\ngraph TD; A-->B\n```'), renderer);
  const doc = new fixture.dom.window.DOMParser().parseFromString(await plan.render({}), 'text/html');
  assert(doc.querySelector('svg')); assert.equal(input.length, 1);
  let finish!: (value: { html: string }) => void;
  const waiting = new ExportPlan(source('$x$'), new PreviewRenderer(() => new Promise(resolve => { finish = resolve; })));
  const pending = waiting.render({}); waiting.cancel(); finish({ html: '<math></math>' }); await assert.rejects(pending);
});

test('export keeps the selected palette, font and table formatting in both appearances', async () => {
  const { builtinThemes } = await import('../../packages/editor/src/themes/catalog.ts');
  for (const theme of ['light', 'dark']) {
    const preferences = { ...prefs, theme, theme_family: 'grove', body_font: 'Georgia' };
    const plan = new ExportPlan({ ...source('| Model | Result |\n| --- | --- |\n| **Ours** | <u>37.5</u> |'), preferences });
    const html = await plan.render({}), doc = new fixture.dom.window.DOMParser().parseFromString(html, 'text/html');
    const palette = builtinThemes.find(t => t.id === 'grove')![theme as 'light' | 'dark'].colors;
    assert(html.includes(`background:${palette.bg}`)); assert(html.includes(`color:${palette.text}`)); assert(html.includes('Georgia'));
    assert.equal(doc.querySelector('td strong')!.textContent, 'Ours'); assert.equal(doc.querySelector('td u')!.textContent, '37.5');
    assert(html.includes('print-color-adjust:exact'));
  }
});


test('export captures captions, image sizes, reading width and an embedded backdrop', async () => {
  const text = 'before ![Alt](a.png "Caption") after', from = text.indexOf('![');
  const plan = new ExportPlan(source(text), undefined, { fontSize: 21, contentWidth: 760, padding: 24, imageScales: new Map([[from, .8]]) });
  const data = 'data:image/png;base64,AAAA';
  const html = await plan.render({ 'a.png': data }, '', data, { 'a.png': 400 });
  const doc = new fixture.dom.window.DOMParser().parseFromString(html, 'text/html');
  assert.equal(doc.querySelector('.image-caption')?.textContent, 'Caption');
  assert.equal(doc.querySelector('.export-image img')?.getAttribute('style'), 'width:320px');
  assert(html.includes('font-size:21px')); assert(html.includes('max-width:760px'));
  assert(html.includes('data:image/png;base64,AAAA')); assert.equal(doc.querySelectorAll('script').length, 0);
  assert.equal(plan.source.text, text);
});

test('official language catalogue highlights additional languages during export', async () => {
  const html = await new ExportPlan(source('```swift\nlet message = "hello"\n```')).render({});
  assert.match(html, /tok-keyword/); assert.match(html, /tok-string/);
});

test('captions export the same Markdown, escaped literals and actual inline math even when the only formula is in a caption', async () => {
  const caption = '**bold** *italic* ~~deleted~~ `code` \\*literal\\* <u>underlined</u> $x^2$ ![nested](https://example.invalid/image.png) <script>alert(1)</script>';
  const raw = `![alt](a.png "${caption}")\n\n![**fallback**](b.png)\n\n![reference][pic]\n\n[pic]: c.png "**Reference caption**"`;
  const plan = new ExportPlan(source(raw), new PreviewRenderer(math));
  assert.deepEqual(plan.images, ['a.png', 'b.png', 'c.png']);
  const data = 'data:image/png;base64,AAAA';
  const html = await plan.render({ 'a.png': data, 'b.png': data, 'c.png': data }, '/* caption-only-math-style */');
  const doc = new fixture.dom.window.DOMParser().parseFromString(html, 'text/html'), captions = doc.querySelectorAll('.image-caption'), first = captions[0];
  assert.equal(first.querySelector('strong')?.textContent, 'bold'); assert.equal(first.querySelector('em')?.textContent, 'italic');
  assert.equal(first.querySelector('s')?.textContent, 'deleted'); assert.equal(first.querySelector('code')?.textContent, 'code');
  assert.equal(first.querySelector('u')?.textContent, 'underlined'); assert(first.querySelector('.katex math'));
  assert(first.textContent?.includes('*literal*')); assert.equal(first.querySelectorAll('img,script').length, 0);
  assert.equal(captions[1].querySelector('strong')?.textContent, 'fallback');
  assert.equal(captions[2].querySelector('strong')?.textContent, 'Reference caption');
  assert(html.includes('caption-only-math-style')); assert.equal(plan.source.text, raw);
});
