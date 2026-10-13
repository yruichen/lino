import assert from 'node:assert/strict';
import { test } from 'node:test';
import { localImageSources } from '../../packages/editor/src/features/media/resources.ts';
test('Save As manifest comes from the frozen source, including table/reference images and excluding literal code/metadata', () => {
  const source = '---\ntitle: ![fake](meta.png)\n---\n\n![图][ref]\n\n| A |\n| - |\n| ![cell](cell.png) |\n\n![remote](https://example.org/a.png)\n\n`![literal](code.png)`\n\n```text\n![literal](fenced.png)\n```\n\n[ref]: <中文%20路径.svg>\n';
  assert.deepEqual(localImageSources(source), ['中文%20路径.svg', 'cell.png']);
});
test('footnote image bodies and their first reference definitions survive Save As while continuation fences stay literal', () => {
  const source = '![outside][shared]\n\n[^n]: ![note](note.png)\n\n    [shared]: first.svg\n\n    ```text\n    ![literal](code.png)\n    ```\n\n[shared]: later.svg\n\n[^n]: ![ignored](duplicate.png)';
  assert.deepEqual(localImageSources(source), ['first.svg', 'note.png']);
});
