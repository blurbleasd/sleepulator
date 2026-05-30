// SLEEPULATOR Service Worker — v2.0
// Dynamically caches the Vite app shell for offline use via Network-First.
// Audio episodes are managed directly by the App via Cache API (not intercepted here).

const CACHE_NAME  = 'sleepulator-shell-v2';

// ── Install ───────────────────────────────────────────────────────────────
self.addEventListener('install', event => {
  self.skipWaiting();
});

// ── Activate: clean up old caches ─────────────────────────────────────────
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k.startsWith('sleepulator-shell') && k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// ── Fetch strategy ────────────────────────────────────────────────────────
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // 1. Never intercept external APIs, audio, or podcasts here.
  //    (We handle offline audio explicitly in AppContext via Blobs to avoid iOS Range bugs).
  if (url.hostname !== self.location.hostname || url.pathname.endsWith('.mp3')) {
    return; // browser default (network)
  }

  // 2. Same-origin assets (index.html, JS, CSS, icons) -> Network-first with Cache fallback.
  //    This ensures Vite's dynamic filenames are cached automatically as they are requested.
  if (url.origin === self.location.origin) {
    event.respondWith(
      fetch(event.request)
        .then(response => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then(c => c.put(event.request, clone));
          }
          return response;
        })
        .catch(async () => {
          const cached = await caches.match(event.request);
          if (cached) return cached;
          
          // If we are offline and asking for the root or a route, serve index.html from cache
          if (event.request.mode === 'navigate') {
            return caches.match('/index.html') || caches.match('./index.html');
          }
          return undefined;
        })
    );
  }
});

// ── Background audio keep-alive ───────────────────────────────────────────
self.addEventListener('message', event => {
  if (event.data === 'keepalive') {
    event.ports[0]?.postMessage('ok');
  }
});
