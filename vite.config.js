import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { execSync } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';

// A short, human-checkable build id so the running app can show which commit it
// was built from (CI sets GITHUB_SHA; locally we read git; fall back to 'dev').
function buildId() {
  const sha = process.env.GITHUB_SHA;
  if (sha) return sha.slice(0, 7);
  try { return execSync('git rev-parse --short HEAD').toString().trim(); } catch { return 'dev'; }
}

const BUILD_ID = buildId();

// public/sw.js is copied verbatim (it never sees Vite's `define`), so stamp the
// build id into the emitted copy after the bundle is written. This makes the SW
// cache name unique per deploy — old shell auto-purged, no manual version bump.
function stampServiceWorker(id) {
  return {
    name: 'stamp-sw',
    apply: 'build',
    closeBundle() {
      const swPath = resolve(__dirname, 'dist/sw.js');
      try {
        const stamped = readFileSync(swPath, 'utf8').replaceAll('__BUILD_ID__', id);
        writeFileSync(swPath, stamped);
      } catch (e) {
        console.warn('stamp-sw: could not stamp dist/sw.js', e.message);
      }
    },
  };
}

export default defineConfig({
  plugins: [react(), stampServiceWorker(BUILD_ID)],
  base: './',
  define: {
    __BUILD_ID__: JSON.stringify(BUILD_ID),
    __BUILD_TIME__: JSON.stringify(new Date().toISOString()),
  },
});
