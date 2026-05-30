// SLEEPULATOR Service Worker — v2.1
// Dynamically caches the Vite app shell for offline use via Network-First.
// Audio episodes are managed directly by the App via Cache API (not intercepted here).

const CACHE_NAME    = 'sleepulator-shell-v2';
const EPISODE_CACHE = 'sleepulator-episodes'; // downloaded podcasts — never purge

// ── Install ───────────────────────────────────────────────────────────────
self.addEventListener('install', event => {
  self.skipWaiting();
});

// ── Activate: clean up old caches ─────────────────────────────────────────
// Delete every cache except the current shell and the downloaded-episodes
// cache. This also retires the legacy precache (e.g. 'sleepulator-v5') from
// the old in-browser-Babel build, which the previous name-prefix filter missed.
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys
          .filter(k => k !== CACHE_NAME && k !== EPISODE_CACHE)
          .map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
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

          // Offline navigation: serve the cached app shell. Use a SW-relative
          // path so it resolves correctly whether the app is hosted at the
          // domain root or under a project-pages subpath (e.g. /sleepulator/).
          if (event.request.mode === 'navigate') {
            const shell = await caches.match('./index.html');
            if (shell) return shell;
          }
          return Response.error();
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
