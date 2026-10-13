import { defineConfig } from 'vite';

export default defineConfig({
  build: {
    target: 'safari17',
    lib: {
      entry: 'src/main.ts',
      name: 'OpenTyporaEditor',
      formats: ['iife'],
      fileName: () => 'editor.js',
      cssFileName: 'editor',
    },
  },
});
