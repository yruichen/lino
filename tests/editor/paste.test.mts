import assert from 'node:assert/strict';
import { test } from 'node:test';
import { setupDOM } from './dom.mts';
const fixture = setupDOM();
const { htmlToMarkdown } = await import('../../packages/editor/src/features/markdown/paste.ts');

test('rich clipboard markup converts to safe Markdown without carrying active content', () => {
  const result = htmlToMarkdown('<h2>Title</h2><p><strong>bold</strong> and <a href="javascript:alert(1)">unsafe</a></p><ul><li>one</li><li><em>two</em></li></ul><script>alert(1)</script>');
  assert.equal(result, '## Title\n\n**bold** and unsafe\n\n- one\n- *two*');
  fixture.dom.window.close();
});
