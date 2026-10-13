import { defineConfig } from 'vite';
const kind = process.env.OT_RENDERER;
if (kind !== 'math' && kind !== 'diagram') throw new Error('Unknown renderer build');
export default defineConfig({ build: {
  target: 'safari17', emptyOutDir: false,
  lib: { entry: `src/renderers/${kind}.ts`, name: kind === 'math' ? 'LinoMath' : 'LinoDiagram', formats: ['iife'], fileName: () => `${kind}.js`, cssFileName: kind },
} });
