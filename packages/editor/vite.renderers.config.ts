import { defineConfig } from 'vite';
const kind = process.env.OT_RENDERER;
if (kind !== 'math' && kind !== 'diagram' && kind !== 'print') throw new Error('Unknown renderer build');
export default defineConfig({ build: {
  target: 'safari17', emptyOutDir: false,
  lib: { entry: kind === 'print' ? 'src/export/pagination.ts' : `src/renderers/${kind}.ts`, name: kind === 'math' ? 'LinoMath' : kind === 'diagram' ? 'LinoDiagram' : 'LinoPrint', formats: ['iife'], fileName: () => `${kind}.js`, cssFileName: kind },
} });
