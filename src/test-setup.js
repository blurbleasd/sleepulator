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
