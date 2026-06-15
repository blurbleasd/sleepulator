// Guarantee a working Web Storage in the test environment.
//
// Node 22 ships an experimental global `localStorage` that throws unless started
// with `--localstorage-file`, and it can shadow the one happy-dom provides. To
// keep tests deterministic across machines, install a simple in-memory store
// whenever the present one is missing or non-functional.
function makeStorage() {
  const m = new Map();
  return {
    getItem: (k) => (m.has(k) ? m.get(k) : null),
    setItem: (k, v) => { m.set(k, String(v)); },
    removeItem: (k) => { m.delete(k); },
    clear: () => { m.clear(); },
    key: (i) => [...m.keys()][i] ?? null,
    get length() { return m.size; },
  };
}

for (const name of ['localStorage', 'sessionStorage']) {
  const cur = globalThis[name];
  if (!cur || typeof cur.getItem !== 'function') {
    Object.defineProperty(globalThis, name, {
      value: makeStorage(),
      configurable: true,
      writable: true,
    });
  }
}

// React Testing Library matchers + automatic DOM cleanup between tests.
import '@testing-library/jest-dom/vitest';
import { afterEach } from 'vitest';
import { cleanup } from '@testing-library/react';
afterEach(() => cleanup());

// Browser APIs the full app touches on mount/play that happy-dom doesn't
// provide. Stub them so <App/> can mount under RTL. These are no-ops for the
// pure-logic and server-render tests, which never reach them.
const define = (target, key, value) => {
  if (target[key] === undefined) {
    try { Object.defineProperty(target, key, { value, configurable: true, writable: true }); } catch { /* ignore */ }
  }
};

// CacheStorage — AppContext loads downloaded episodes from `caches` on mount.
const emptyCache = { match: async () => undefined, put: async () => {}, keys: async () => [], delete: async () => false };
define(globalThis, 'caches', { open: async () => emptyCache, keys: async () => [], match: async () => undefined, delete: async () => false });

// Media Session (lock-screen controls) — present but inert under test.
define(globalThis.navigator, 'mediaSession', {
  metadata: null,
  playbackState: 'none',
  setActionHandler: () => {},
  setPositionState: () => {},
});
define(globalThis, 'MediaMetadata', class { constructor(init = {}) { Object.assign(this, init); } });
