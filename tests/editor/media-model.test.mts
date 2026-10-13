import assert from 'node:assert/strict';
import { test } from 'node:test';
import { EditorState } from '@codemirror/state';
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { ensureSyntaxTree } from '@codemirror/language';
import { mathSyntax } from '../../packages/editor/src/features/media/syntax.ts';
import { imageMarkdown, importedSource, previewSources } from '../../packages/editor/src/features/media/model.ts';
const state = (doc: string) => {
  const initial = EditorState.create({ doc, extensions: [markdown({ base: markdownLanguage, extensions: [mathSyntax] })] });
  // Model fixtures require the full small document. Production parsing has a
  // time slice and may return a partial tree when tests run concurrently.
  assert(ensureSyntaxTree(initial, doc.length, 1000));
  return initial.update({}).state;
};
test('math uses existing Markdown syntax, excludes code, escaped dollars and unclosed blocks', () => {
  const doc = 'inline $x^2$ and \\$plain\n\n$$\n\\frac{a}{b}\n$$\n\n`$code$`\n\n```tex\n$$\ncode\n$$\n```\n\n$$\nunclosed';
  const sources = previewSources(state(doc));
  assert.deepEqual(sources.map(s => [s.kind, s.block, s.text]), [['math', false, 'x^2'], ['math', true, '\\frac{a}{b}']]);
  for (const source of sources) assert(doc.slice(source.from, source.to).startsWith('$'));
  assert.equal(previewSources(state('Price $5 and $20.')).length, 0);
});
test('images preserve destination semantics, reference definitions, escaped labels and title entities', () => {
  const doc = '![a\\]b](<assets/a%20b.png> "A &amp; B")\n\n![other][pic]\n\n[pic]: images/test.png "title"\n\n`![code](no.png)`';
  const sources = previewSources(state(doc));
  assert.equal(sources.length, 2); assert.equal(sources[0].alt, 'a]b'); assert.equal(sources[0].text, 'assets/a%20b.png'); assert.equal(sources[0].title, 'A & B');
  assert.equal(sources[1].reference, true); assert.equal(sources[1].text, 'images/test.png'); assert.equal(sources[1].title, 'title');
  const syntax = imageMarkdown(importedSource('note.md.assets/中文 #%.png'), 'a]b', 'a"b');
  const image = previewSources(state(syntax))[0]; assert.equal(image.alt, 'a]b'); assert.equal(image.title, 'a"b'); assert.equal(image.text, 'note.md.assets/%E4%B8%AD%E6%96%87%20%23%25.png');
  assert.throws(() => imageMarkdown('bad\npath', ''));
  const amp = previewSources(state(imageMarkdown('https://example.invalid/a?a=1&copy;&x=2', '&copy;', '&amp;')))[0];
  assert.equal(amp.text, 'https://example.invalid/a?a=1&copy;&x=2'); assert.equal(amp.alt, '&copy;'); assert.equal(amp.title, '&amp;');
  assert.equal(previewSources(state('![x](https://example.invalid/?q=&copy)'))[0].text, 'https://example.invalid/?q=&copy');
});
test('only Mermaid fences become diagrams, container contents retain real code indentation', () => {
  const doc = '> ```mermaid\n> flowchart LR\n>   A --> B\n> ```\n\n```sequence\nA->B: old language\n```';
  const sources = previewSources(state(doc)); assert.equal(sources.length, 1); assert.equal(sources[0].kind, 'diagram'); assert.equal(sources[0].text, 'flowchart LR\n  A --> B\n');
});
