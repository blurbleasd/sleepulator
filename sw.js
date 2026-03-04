// SLEEPULATOR Service Worker — v1.0
// Caches the app shell for offline use.
// Audio from external podcast feeds is NOT cached (too large/dynamic).

const CACHE_NAME  = 'sleepulator-v1';
const SHELL_URLS  = [
  './',
  './index.html',
  './manifest.json',
  './apple-touch-icon.png',
  './icon-192.png',
  './icon-512.png',
  './favicon.png',
  // CDN assets — cache on first fetch via stale-while-revalidate
];

// External CDN origins we'll cache
const CDN_ORIGINS = [
  'cdnjs.cloudflare.com',
];

// ── Install: pre-cache the app shell ────────────────────────────────────────
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => cache.addAll(SHELL_URLS))
  );
  self.skipWaiting();
});

// ── Activate: clean up old caches ────────────────────────────────────────────
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys =>
      Promise.all(keys.filter(k => k !== CACHE_NAME).map(k => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// ── Fetch strategy ───────────────────────────────────────────────────────────
self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);

  // 1. Podcast/RSS audio & proxy requests — always network-only (never cache)
  if (url.hostname === 'api.allorigins.win' ||
      event.request.destination === 'audio') {
    return; // fall through to browser default (network)
  }

  // 2. CDN assets — cache-first (fast loads, update in background)
  if (CDN_ORIGINS.includes(url.hostname)) {
    event.respondWith(
      caches.open(CACHE_NAME).then(async cache => {
        const cached = await cache.match(event.request);
        const fetchPromise = fetch(event.request).then(response => {
          if (response.ok) cache.put(event.request, response.clone());
          return response;
        }).catch(() => cached); // if offline, return stale
        return cached || fetchPromise;
      })
    );
    return;
  }

  // 3. App shell (same origin) — network-first with cache fallback
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
        .catch(() => caches.match(event.request))
    );
  }
});

// ── Background audio keep-alive ──────────────────────────────────────────────
// The service worker does NOT manage audio itself — playback continues in the
// page context via HTMLMediaElement audio as long as the browser keeps the
// media session active.
// This no-op message handler keeps the SW alive during audio sessions.
self.addEventListener('message', event => {
  if (event.data === 'keepalive') {
    event.ports[0]?.postMessage('ok');
  }
});
