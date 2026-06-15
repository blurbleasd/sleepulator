

export const APP_CONFIG = window.SLEEPULATOR_CONFIG || {};
export const LEGACY_DEFAULT_FEED_URL = 'https://feeds.simplecast.com/tOaZvgCO';
export const DEFAULT_FEED_PROXY_URL = 'https://sleepulator-feed-proxy.chesteraarfer.workers.dev';
export const NATIVE_MEDIA_VOLUME_LOCK = !!APP_CONFIG.forceNativeMediaVolumeLock || isIOSDevice();


// ─── Stable episode ID from URL hash ─────────────────────────────────────────
export function hashUrl(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) h = (Math.imul(31, h) + str.charCodeAt(i)) | 0;
  return 'ep_' + Math.abs(h).toString(36);
}

export const FEED_TIMEOUT_MS = 15000;
export const FEED_ACCEPT_HEADER = 'application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, text/plain;q=0.7, */*;q=0.1';

export function clamp01(value) {
  return Math.max(0, Math.min(1, value));
}

export function shortenSecret(value, keepStart = 5, keepEnd = 3) {
  if (!value) return '';
  if (value.length <= keepStart + keepEnd + 3) return value;
  return `${value.slice(0, keepStart)}...${value.slice(-keepEnd)}`;
}

export function redactUrlForDisplay(value) {
  const trimmed = (value || '').trim();
  if (!trimmed) return '';
  try {
    const parsed = new URL(trimmed, window.location.href);
    if (parsed.username) parsed.username = shortenSecret(parsed.username, 2, 1);
    if (parsed.password) parsed.password = '***';
    parsed.searchParams.forEach((paramValue, key) => {
      if (/token|key|auth|sig|signature|secret|pass|password|expires/i.test(key)) {
        parsed.searchParams.set(key, shortenSecret(paramValue));
      }
    });
    return parsed.toString();
  } catch {
    return trimmed.length > 140 ? `${trimmed.slice(0, 137)}...` : trimmed;
  }
}

export function normalizeConfigUrl(input) {
  const trimmed = (input || '').trim();
  if (!trimmed) return '';
  try { return new URL(trimmed, window.location.href).href; }
  catch { return trimmed; }
}

export function getDefaultFeedProxyUrl() {
  return normalizeConfigUrl(APP_CONFIG.feedProxyUrl || DEFAULT_FEED_PROXY_URL);
}

export function buildSleepSafeAudioUrl(sourceUrl, proxyUrl, profile = 'sleep-safe') {
  const trimmedSource = (sourceUrl || '').trim();
  const trimmedProxy = (proxyUrl || '').trim();
  if (!trimmedSource || !trimmedProxy) return trimmedSource;
  try {
    const next = new URL(trimmedProxy, window.location.href);
    if (!next.pathname || next.pathname === '/') next.pathname = '/audio';
    next.searchParams.set('url', trimmedSource);
    next.searchParams.set('profile', profile);
    return next.toString();
  } catch {
    return trimmedSource;
  }
}

export function parseDuration(raw) {
  if (!raw) return '';
  const t = raw.trim();
  let totalSeconds = NaN;
  if (/^\d+$/.test(t)) {
    totalSeconds = parseInt(t, 10);
  } else {
    const parts = t.split(':').map(part => Number(part));
    if (parts.length >= 2 && parts.every(Number.isFinite)) {
      totalSeconds = parts.reduce((sum, part) => (sum * 60) + part, 0);
    }
  }
  if (!Number.isFinite(totalSeconds) || totalSeconds <= 0) return '';
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return s > 0 ? `${m}m ${s}s` : `${m}m`;
  return `${s}s`;
}

export function fmtTime(s) {
  if (!s || !isFinite(s) || s < 0) return '0:00';
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
  if (h > 0) return `${h}:${String(m).padStart(2,'0')}:${String(sec).padStart(2,'0')}`;
  return `${m}:${String(sec).padStart(2,'0')}`;
}

export function previewText(text, maxLength = 140) {
  const normalized = (text || '').replace(/\s+/g, ' ').trim();
  if (!normalized) return '';
  return normalized.length > maxLength ? `${normalized.slice(0, maxLength - 3)}...` : normalized;
}

export function readStoredArray(key) {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || '[]');
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

export function deriveFeedName(rawUrl) {
  const trimmed = (rawUrl || '').trim();
  if (!trimmed) return 'Saved Feed';
  try {
    return new URL(trimmed, window.location.href).hostname.replace(/^www\./, '') || 'Saved Feed';
  } catch {
    return trimmed.replace(/^https?:\/\//, '').split('/')[0] || 'Saved Feed';
  }
}

export function inferPodcastTitle(episodeTitle) {
  const match = (episodeTitle || '').match(/^\[([^\]]+)\]\s*/);
  return match?.[1]?.trim() || '';
}

export function dedupeEpisodes(episodes) {
  const seen = new Set();
  return episodes.filter(episode => {
    const key = episode?.id || episode?.url;
    if (!key || seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

export function describeError(error) {
  if (!error) return '';
  if (typeof error === 'string') return error;
  const parts = [];
  if (error.code) parts.push(error.code);
  if (error.name && error.name !== 'Error' && error.name !== error.code) parts.push(error.name);
  if (error.message && error.message !== error.code) parts.push(error.message);
  return parts.join(': ') || 'Request failed.';
}

export function mergeHeaders(...headerSets) {
  const merged = new Headers();
  headerSets.filter(Boolean).forEach(headerSet => {
    new Headers(headerSet).forEach((value, key) => merged.set(key, value));
  });
  return merged;
}

export function withFeedHeaders(init = {}) {
  return {
    ...init,
    headers: mergeHeaders({ Accept: FEED_ACCEPT_HEADER }, init.headers),
  };
}

export function fetchWithTimeout(input, init = {}, timeoutMs = FEED_TIMEOUT_MS) {
  if (typeof AbortController === 'undefined') return fetch(input, init);
  const controller = new AbortController();
  const timer = window.setTimeout(() => controller.abort(), timeoutMs);
  return fetch(input, { ...init, signal: controller.signal }).finally(() => {
    window.clearTimeout(timer);
  });
}

export function safeJsonParse(text) {
  try { return JSON.parse(text); }
  catch { return null; }
}

export function localNameOf(node) {
  return (node?.localName || node?.nodeName || '').replace(/^.*:/, '').toLowerCase();
}

export function directElements(node) {
  return Array.from(node?.children || []);
}

export function directMatches(node, names) {
  const wanted = new Set(names.map(v => v.toLowerCase()));
  return directElements(node).filter(child => wanted.has(localNameOf(child)));
}

export function descendantMatches(node, names) {
  const wanted = new Set(names.map(v => v.toLowerCase()));
  return Array.from(node?.getElementsByTagName?.('*') || []).filter(child => wanted.has(localNameOf(child)));
}

export function firstDirectText(node, names) {
  for (const child of directMatches(node, names)) {
    const text = child.textContent?.trim();
    if (text) return text;
  }
  return '';
}

export function firstDescendantText(node, names) {
  return firstDirectText(node, names) || descendantMatches(node, names).map(el => el.textContent?.trim()).find(Boolean) || '';
}

export function firstAttrFromElements(elements, attrs, predicate = () => true) {
  for (const element of elements) {
    if (!predicate(element)) continue;
    for (const attr of attrs) {
      const value = element.getAttribute?.(attr)?.trim();
      if (value) return value;
    }
  }
  return '';
}

export function firstText(root, selectors) {
  for (const selector of selectors) {
    const value = root.querySelector(selector)?.textContent?.trim();
    if (value) return value;
  }
  return '';
}

export function firstAttr(root, selectorPairs) {
  for (const [selector, attr] of selectorPairs) {
    const value = root.querySelector(selector)?.getAttribute(attr)?.trim();
    if (value) return value;
  }
  return '';
}

export function resolveMaybeUrl(value, baseUrl) {
  if (!value) return '';
  try { return new URL(value, baseUrl).href; }
  catch { return value; }
}

export function sniffMarkupType(raw) {
  const text = (raw || '')
    .replace(/^\uFEFF/, '')
    .trimStart()
    .replace(/^(?:<!--[\s\S]*?-->\s*)+/, '');
  if (!text) return 'empty';
  if (/^<(?:\?xml\b|rss\b|feed\b|rdf:RDF\b)/i.test(text)) return 'xml';
  if (/^<(?:!doctype\s+html\b|html\b)/i.test(text)) return 'html';
  return 'unknown';
}

export function looksLikeXmlFeed(raw) {
  if (sniffMarkupType(raw) !== 'xml') return false;
  const xml = new DOMParser().parseFromString(raw, 'text/xml');
  if (xml.querySelector('parsererror')) return false;
  const root = xml.documentElement;
  if (!root) return false;
  const rootName = localNameOf(root);
  return ['rss', 'feed', 'rdf'].includes(rootName) || !!descendantMatches(root, ['item', 'entry']).length;
}

export function extractEmbeddedFeedMarkup(raw) {
  if (sniffMarkupType(raw) !== 'html') return '';
  const html = new DOMParser().parseFromString(raw, 'text/html');
  const body = html.body;
  const candidates = [
    ...(Array.from(html.querySelectorAll('pre, code, textarea')).map(node => node.textContent || '')),
    body?.textContent || '',
    body?.innerText || '',
  ];
  for (const candidate of candidates) {
    if (looksLikeXmlFeed(candidate)) return candidate.trim();
  }
  const bodyMarkup = body?.innerHTML || '';
  const inlineMarkup = bodyMarkup.match(/<(?:\?xml\b|rss\b|feed\b|rdf:RDF\b)[\s\S]*$/i)?.[0] || '';
  if (looksLikeXmlFeed(inlineMarkup)) return inlineMarkup.trim();
  return '';
}

export function discoverAlternateFeedUrl(raw, baseUrl) {
  if (sniffMarkupType(raw) !== 'html') return '';
  const html = new DOMParser().parseFromString(raw, 'text/html');
  const alternate = Array.from(html.querySelectorAll('link[rel~="alternate"][href]')).find(link => {
    const type = (link.getAttribute('type') || '').toLowerCase();
    return /rss|atom|xml/.test(type);
  })?.getAttribute('href');
  if (alternate) return resolveMaybeUrl(alternate, baseUrl);

  const candidate = Array.from(html.querySelectorAll('a[href]')).find(link => {
    const href = (link.getAttribute('href') || '').toLowerCase();
    return /(?:rss|feed|atom|xml)/.test(href);
  })?.getAttribute('href');
  return resolveMaybeUrl(candidate, baseUrl);
}

export function normalizeFeedUrl(input) {
  const trimmed = (input || '').trim();
  const normalized = { originalUrl: trimmed, fetchUrl: trimmed, authHeader: '' };
  try {
    const parsed = new URL(trimmed);
    if (parsed.username || parsed.password) {
      const user = decodeURIComponent(parsed.username);
      const pass = decodeURIComponent(parsed.password);
      normalized.authHeader = `Basic ${btoa(`${user}:${pass}`)}`;
      parsed.username = '';
      parsed.password = '';
      normalized.fetchUrl = parsed.toString();
    }
  } catch {}
  return normalized;
}

export function buildFeedSources(feedUrl, options = {}) {
  const proxyUrl = normalizeConfigUrl(options.proxyUrl);
  const authHeader = options.authHeader || '';
  const sources = [];

  if (proxyUrl) {
    sources.push({
      label: 'Private Proxy',
      url: proxyUrl,
      init: withFeedHeaders({
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: feedUrl, authHeader }),
      }),
      read: text => text,
    });
  }

  sources.push(
    {
      label: 'Direct',
      url: feedUrl,
      init: withFeedHeaders(authHeader ? { headers: { Authorization: authHeader } } : {}),
      read: text => text,
    },
    {
      label: 'AllOrigins',
      url: `https://api.allorigins.win/get?url=${encodeURIComponent(feedUrl)}`,
      init: withFeedHeaders(),
      read: text => {
        const parsed = safeJsonParse(text);
        return parsed?.contents || parsed?.data || '';
      }
    },
    {
      label: 'CORS Proxy',
      url: `https://corsproxy.io/?${encodeURIComponent(feedUrl)}`,
      init: withFeedHeaders(),
      read: text => text,
    }
  );

  return sources;
}

export function makeFeedError(code, details = {}) {
  const error = new Error(code);
  error.code = code;
  Object.assign(error, details);
  return error;
}

export function formatFeedError(error, fallbackUrl) {
  if (!error) return 'Feed unavailable. Check URL or try again.';
  if (error.code === 'html-auth') {
    return 'This URL returned a login or web page instead of a feed. Private feeds often block browser/proxy access.';
  }
  if (error.code === 'alternate-feed' && error.alternateUrl) {
    return `This URL looks like a webpage, not a feed. Try the discovered feed URL: ${error.alternateUrl}`;
  }
  if (error.code === 'empty-feed') {
    return 'The feed loaded, but no episodes with playable audio were found.';
  }
  if (error.code === 'auth-cors') {
    return 'This private feed likely needs auth or blocks browser access. If it uses username/password, the host must allow direct browser requests.';
  }
  if (error.code === 'network') {
    return error.hasProxy
      ? 'No feed route succeeded, including your private proxy. Open Feed Debug for the failing step.'
      : 'The browser could not read this feed directly. Member-only feeds usually need a private proxy URL.';
  }
  if (error.code === 'timeout') {
    return 'The feed request timed out before any source returned XML.';
  }
  if (error.code === 'parsererror') {
    return 'The response was not valid RSS/Atom XML.';
  }
  const details = describeError(error);
  return details || `Could not load this feed from ${fallbackUrl}.`;
}

export function parseFeedEpisodes(raw, feedUrl) {
  const embeddedFeed = extractEmbeddedFeedMarkup(raw);
  const source = embeddedFeed || raw;
  const markupType = sniffMarkupType(source);
  if (markupType === 'html') {
    const alternateUrl = discoverAlternateFeedUrl(source, feedUrl);
    if (alternateUrl && alternateUrl !== feedUrl) throw makeFeedError('alternate-feed', { alternateUrl });
    throw makeFeedError('html-auth');
  }
  const xml = new DOMParser().parseFromString(source, 'text/xml');
  if (xml.querySelector('parsererror')) throw makeFeedError('parsererror');

  const root = xml.documentElement;
  const container = directMatches(root, ['channel', 'feed'])[0] || root;
  const fallbackTitle = deriveFeedName(feedUrl) || 'Podcast';
  const podcastTitle = firstDirectText(container, ['title']) || firstDescendantText(container, ['title']) || fallbackTitle;

  const items = directMatches(container, ['item', 'entry']);
  const itemNodes = items.length ? items : descendantMatches(container, ['item', 'entry']);
  const episodes = dedupeEpisodes(itemNodes.map(item => {
    const title = firstDirectText(item, ['title']) || firstDescendantText(item, ['title']) || 'Untitled';
    const directAudio = firstAttrFromElements(directMatches(item, ['enclosure']), ['url']);
    const mediaAudio = firstAttrFromElements(descendantMatches(item, ['content']), ['url', 'href', 'src'], el => {
      const type = (el.getAttribute('type') || '').toLowerCase();
      return !type || type.startsWith('audio/');
    });
    const linkAudio = firstAttrFromElements(descendantMatches(item, ['link']), ['href', 'url'], el => {
      const rel = (el.getAttribute('rel') || '').toLowerCase();
      const type = (el.getAttribute('type') || '').toLowerCase();
      const href = (el.getAttribute('href') || '').toLowerCase();
      return rel === 'enclosure' || type.startsWith('audio/') || /\.(mp3|m4a|aac|mp4|m4b)([?#].*)?$/.test(href);
    });
    const audioUrl = resolveMaybeUrl(directAudio || mediaAudio || linkAudio, feedUrl);

    if (!audioUrl) return null;
    const rawDuration = firstDirectText(item, ['duration']) || firstDescendantText(item, ['duration']) || '';
    const duration = parseDuration(rawDuration);
    const rawDesc = firstDirectText(item, ['description','summary']) || firstDescendantText(item, ['description','summary']) || '';
    const description = previewText(rawDesc.replace(/<[^>]+>/g,' ').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/\s+/g,' ').trim(), 240);
    return {
      id: hashUrl(audioUrl),
      title: `[${podcastTitle}] ${title}`,
      url: audioUrl,
      duration,
      description,
    };
  }).filter(Boolean));
  if (!episodes.length) throw makeFeedError('empty-feed');
  return {
    feedTitle: podcastTitle,
    episodes,
  };
}

// Parse an OPML subscription export (Overcast, Apple Podcasts, Pocket Casts,
// etc.) into a de-duplicated list of { url, name }. Recurses through folder
// outlines and ignores outlines without a feed URL. Returns [] on bad input.
export function parseOpmlFeeds(raw) {
  if (!raw || typeof raw !== 'string') return [];
  let doc;
  try {
    doc = new DOMParser().parseFromString(raw, 'text/xml');
  } catch (e) {
    return [];
  }
  if (!doc || doc.querySelector('parsererror')) return [];

  const outlines = Array.from(doc.getElementsByTagName('outline'));
  const seen = new Set();
  const feeds = [];
  for (const node of outlines) {
    const xmlUrl = (
      node.getAttribute('xmlUrl') ||
      node.getAttribute('xmlurl') ||
      node.getAttribute('xmlURL') ||
      ''
    ).trim();
    if (!xmlUrl || seen.has(xmlUrl)) continue;
    seen.add(xmlUrl);
    const name = (node.getAttribute('text') || node.getAttribute('title') || '').trim();
    feeds.push({ url: xmlUrl, name });
  }
  return feeds;
}

export function isIOSDevice() {
  const ua = navigator.userAgent || '';
  return /iP(hone|ad|od)/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

export function isStandaloneWebApp() {
  return window.matchMedia?.('(display-mode: standalone)')?.matches || window.navigator.standalone === true;
}

// ─── Noise generators (all use sr param — no hardcoded 44100) ─────────────────
export function generateBrown(L, R, n) {
  let lL=0,lR=0;
  for (let i=0;i<n;i++) { const wL=Math.random()*2-1,wR=Math.random()*2-1; lL=(lL+.02*wL)/1.02; lR=(lR+.02*wR)/1.02; L[i]=lL*3.5; R[i]=lR*3.5; }
}
export function generatePink(L, R, n) {
  let b0L=0,b1L=0,b2L=0,b3L=0,b4L=0,b5L=0,b6L=0,b0R=0,b1R=0,b2R=0,b3R=0,b4R=0,b5R=0,b6R=0;
  for (let i=0;i<n;i++) {
    const wL=Math.random()*2-1,wR=Math.random()*2-1;
    b0L=.99886*b0L+wL*.0555179;b1L=.99332*b1L+wL*.0750759;b2L=.969*b2L+wL*.153852;b3L=.8665*b3L+wL*.310486;b4L=.55*b4L+wL*.532952;b5L=-.7616*b5L-wL*.016898;
    L[i]=(b0L+b1L+b2L+b3L+b4L+b5L+b6L+wL*.5362)*.11;b6L=wL*.115926;
    b0R=.99886*b0R+wR*.0555179;b1R=.99332*b1R+wR*.0750759;b2R=.969*b2R+wR*.153852;b3R=.8665*b3R+wR*.310486;b4R=.55*b4R+wR*.532952;b5R=-.7616*b5R-wR*.016898;
    R[i]=(b0R+b1R+b2R+b3R+b4R+b5R+b6R+wR*.5362)*.11;b6R=wR*.115926;
  }
}
export function generateGreen(L, R, n) {
  let g0L=0,g1L=0,g0R=0,g1R=0;
  for (let i=0;i<n;i++) { const wL=Math.random()*2-1,wR=Math.random()*2-1; g0L=.994*g0L+wL*.05;g1L=.9*g1L+wL*.05;L[i]=(g0L-g1L)*3;g0R=.994*g0R+wR*.05;g1R=.9*g1R+wR*.05;R[i]=(g0R-g1R)*3; }
}
export function generateWhite(L, R, n) {
  for (let i=0;i<n;i++) { L[i]=(Math.random()*2-1)*.5;R[i]=(Math.random()*2-1)*.5; }
}
export function generateFan(L, R, n, sr) {
  let lL=0,lR=0;
  for (let i=0;i<n;i++) {
    const wL=Math.random()*2-1,wR=Math.random()*2-1;
    lL=(lL+.015*wL)/1.015;lR=(lR+.015*wR)/1.015;
    const hum=Math.sin(2*Math.PI*60*i/sr)*.15;
    L[i]=lL*4.5+hum;R[i]=lR*4.5+hum;
  }
}
export function generateRain(L, R, n) {
  let b0L=0,b1L=0,b0R=0,b1R=0;
  for (let i=0;i<n;i++) {
    const wL=Math.random()*2-1,wR=Math.random()*2-1;
    b0L=.8*b0L+wL*.12;L[i]=(wL*.7+b0L*.2+b1L*.1)*.75;b1L=wL;
    b0R=.8*b0R+wR*.12;R[i]=(wR*.7+b0R*.2+b1R*.1)*.75;b1R=wR;
  }
}
export function generateOcean(L, R, n, sr) {
  let lL=0,lR=0;
  for (let i=0;i<n;i++) {
    const wL=Math.random()*2-1,wR=Math.random()*2-1;
    lL=(lL+.022*wL)/1.022;lR=(lR+.022*wR)/1.022;
    const lfo=Math.pow((Math.sin(2*Math.PI*.10*i/sr)+1)/2,1.8);
    L[i]=lL*4.5*lfo;R[i]=lR*4.5*lfo;
  }
}
export function generateForest(L, R, n, sr) {
  let b0L=0,b1L=0,b0R=0,b1R=0,phase=0;
  for (let i=0;i<n;i++) {
    const wL=Math.random()*2-1,wR=Math.random()*2-1;
    b0L=.88*b0L+wL*.2;L[i]=(wL*.5-b0L*.5+b1L*.22)*.85;b1L=wL;
    b0R=.88*b0R+wR*.2;R[i]=(wR*.5-b0R*.5+b1R*.22)*.85;b1R=wR;
    phase+=2*Math.PI*4.2*(1+(Math.random()-.5)*.15)/sr;
    if(phase>2*Math.PI)phase-=2*Math.PI;
    const e=.35+.65*Math.abs(Math.sin(phase));
    L[i]*=e;R[i]*=e;
  }
}

export const NOISE_TYPES = {
  brown:  { label:'🌊 Brown (Deep Waterfall)',  fn: (L,R,n,sr)=>generateBrown(L,R,n)  },
  pink:   { label:'🌧 Pink (Steady Rain)',       fn: (L,R,n,sr)=>generatePink(L,R,n)   },
  green:  { label:'💧 Green (Rushing River)',    fn: (L,R,n,sr)=>generateGreen(L,R,n)  },
  white:  { label:'📻 White (Classic Static)',   fn: (L,R,n,sr)=>generateWhite(L,R,n)  },
  fan:    { label:'🌀 Fan (Box Fan Hum)',         fn: generateFan  },
  rain:   { label:'☔ Rain (Gentle Shower)',      fn: (L,R,n,sr)=>generateRain(L,R,n)   },
  ocean:  { label:'🌊 Ocean (Rolling Waves)',     fn: generateOcean },
  forest: { label:'🌲 Forest (Night Crickets)',   fn: generateForest},
};

export const BINAURAL = {
  delta: { name:'Deep Sleep (4 Hz)',  beat:4,  carrier:180 },
  theta: { name:'Meditation (6 Hz)', beat:6,  carrier:200 },
  alpha: { name:'Relaxation (10 Hz)',beat:10, carrier:220 },
};

export const ARTWORK = [{ src:'icon-512.png', sizes:'512x512', type:'image/png' }];
export const LOOP_SAMPLE_RATE = 12000;
export const BINAURAL_LOOP_SAMPLE_RATE = 4000;
export const AMBIENT_LOOP_SECONDS = 60;
// iOS media-element looping is not reliably gapless, so keep this much longer.
export const BINAURAL_LOOP_SECONDS = 300;
export const LOOP_TRANSITION_SECONDS = 1.25;
export const LOOP_MATCH_SECONDS = 1.5;
export const LOOP_SCALED_GAIN_EPSILON = 0.01;
export const LOOP_MUTED_GAIN_EPSILON = 0.001;
export const LOOP_SOURCE_TIME_FUZZ = 0.05;
export const LOOP_BUFFER_CACHE = {
  ambient: new Map(),
  binaural: new Map(),
};
export const LOOP_URL_CACHE = {
  ambient: new Map(),
  binaural: new Map(),
};

export function writeAscii(view, offset, text) {
  for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i));
}

export function buildStereoWavUrl(left, right, sampleRate, gain = 1) {
  const frames = Math.min(left.length, right.length);
  const bytesPerSample = 2;
  const numChannels = 2;
  const dataSize = frames * numChannels * bytesPerSample;
  const buffer = new ArrayBuffer(44 + dataSize);
  const view = new DataView(buffer);
  writeAscii(view, 0, 'RIFF');
  view.setUint32(4, 36 + dataSize, true);
  writeAscii(view, 8, 'WAVE');
  writeAscii(view, 12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, numChannels, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * numChannels * bytesPerSample, true);
  view.setUint16(32, numChannels * bytesPerSample, true);
  view.setUint16(34, bytesPerSample * 8, true);
  writeAscii(view, 36, 'data');
  view.setUint32(40, dataSize, true);

  let offset = 44;
  for (let i = 0; i < frames; i++) {
    const l = Math.max(-1, Math.min(1, (left[i] || 0) * gain));
    const r = Math.max(-1, Math.min(1, (right[i] || 0) * gain));
    view.setInt16(offset, l < 0 ? l * 0x8000 : l * 0x7fff, true);
    view.setInt16(offset + 2, r < 0 ? r * 0x8000 : r * 0x7fff, true);
    offset += 4;
  }
  return URL.createObjectURL(new Blob([buffer], { type: 'audio/wav' }));
}

export function buildLoopMeta(sampleRate, loopStartFrames, loopWrapStartFrames, totalFrames) {
  return {
    sampleRate,
    loopStartFrames,
    loopWrapStartFrames,
    totalFrames,
    loopStartTime: loopStartFrames / sampleRate,
    loopWrapStartTime: loopWrapStartFrames / sampleRate,
    loopWindowSeconds: Math.max(0, (totalFrames - loopWrapStartFrames) / sampleRate),
  };
}

export function maybeWrapManualLoop(audio, loopMeta, wrapLockRef) {
  if (!audio || !loopMeta || !Number.isFinite(audio.currentTime)) return;
  const currentTime = audio.currentTime;
  const wrapStart = loopMeta.loopWrapStartTime;
  if (currentTime < wrapStart - LOOP_SOURCE_TIME_FUZZ) {
    wrapLockRef.current = false;
    return;
  }
  const offset = currentTime - wrapStart;
  if (offset < -LOOP_SOURCE_TIME_FUZZ || offset > loopMeta.loopWindowSeconds + LOOP_SOURCE_TIME_FUZZ) return;
  if (wrapLockRef.current) return;
  wrapLockRef.current = true;
  try {
    audio.currentTime = Math.max(0, loopMeta.loopStartTime + Math.max(0, offset));
  } catch (error) {}
}

export function getAmbientLoopBuffer(type) {
  if (LOOP_BUFFER_CACHE.ambient.has(type)) return LOOP_BUFFER_CACHE.ambient.get(type);
  const frames = LOOP_SAMPLE_RATE * AMBIENT_LOOP_SECONDS;
  const rawLeft = new Float32Array(frames);
  const rawRight = new Float32Array(frames);
  NOISE_TYPES[type].fn(rawLeft, rawRight, frames, LOOP_SAMPLE_RATE);

  const left = rawLeft.slice();
  const right = rawRight.slice();
  const transitionFrames = Math.min(
    Math.max(64, Math.round(LOOP_SAMPLE_RATE * LOOP_TRANSITION_SECONDS)),
    Math.max(64, Math.floor(frames / 4))
  );
  const matchFrames = Math.min(
    Math.max(64, Math.round(LOOP_SAMPLE_RATE * LOOP_MATCH_SECONDS)),
    Math.max(64, Math.floor(frames / 4))
  );
  const loopStartFrames = transitionFrames;
  const loopWrapStartFrames = Math.max(loopStartFrames + 1, frames - matchFrames);
  const transitionStart = Math.max(0, loopWrapStartFrames - transitionFrames);

  for (let i = 0; i < transitionFrames; i++) {
    const tailIndex = transitionStart + i;
    if (tailIndex >= loopWrapStartFrames) break;
    const blend = transitionFrames <= 1 ? 1 : i / (transitionFrames - 1);
    left[tailIndex] = rawLeft[tailIndex] * (1 - blend) + rawLeft[i] * blend;
    right[tailIndex] = rawRight[tailIndex] * (1 - blend) + rawRight[i] * blend;
  }
  for (let i = 0; i < matchFrames; i++) {
    const targetIndex = loopWrapStartFrames + i;
    const sourceIndex = loopStartFrames + i;
    if (targetIndex >= frames || sourceIndex >= frames) break;
    left[targetIndex] = rawLeft[sourceIndex];
    right[targetIndex] = rawRight[sourceIndex];
  }

  const buffer = {
    left,
    right,
    sampleRate: LOOP_SAMPLE_RATE,
    loopMeta: buildLoopMeta(LOOP_SAMPLE_RATE, loopStartFrames, loopWrapStartFrames, frames),
  };
  LOOP_BUFFER_CACHE.ambient.set(type, buffer);
  return buffer;
}

export function getAmbientLoopMeta(type) {
  return getAmbientLoopBuffer(type).loopMeta;
}

export function getAmbientLoopUrl(type, gain = 1) {
  const quantizedGain = clamp01(gain);
  if (Math.abs(quantizedGain - 1) < LOOP_SCALED_GAIN_EPSILON) {
    if (LOOP_URL_CACHE.ambient.has(type)) return LOOP_URL_CACHE.ambient.get(type);
    const { left, right, sampleRate } = getAmbientLoopBuffer(type);
    const url = buildStereoWavUrl(left, right, sampleRate);
    LOOP_URL_CACHE.ambient.set(type, url);
    return url;
  }
  const { left, right, sampleRate } = getAmbientLoopBuffer(type);
  return buildStereoWavUrl(left, right, sampleRate, quantizedGain);
}

export function getBinauralLoopBuffer(presetKey) {
  if (LOOP_BUFFER_CACHE.binaural.has(presetKey)) return LOOP_BUFFER_CACHE.binaural.get(presetKey);
  const coreFrames = BINAURAL_LOOP_SAMPLE_RATE * BINAURAL_LOOP_SECONDS;
  const matchFrames = Math.min(
    Math.max(64, Math.round(BINAURAL_LOOP_SAMPLE_RATE * LOOP_MATCH_SECONDS)),
    Math.max(64, Math.floor(coreFrames / 6))
  );
  const frames = coreFrames + matchFrames;
  const left = new Float32Array(frames);
  const right = new Float32Array(frames);
  const { beat, carrier } = BINAURAL[presetKey];
  const leftFreq = carrier - beat / 2;
  const rightFreq = carrier + beat / 2;
  for (let i = 0; i < coreFrames; i++) {
    const t = i / BINAURAL_LOOP_SAMPLE_RATE;
    left[i] = Math.sin(2 * Math.PI * leftFreq * t) * 0.32;
    right[i] = Math.sin(2 * Math.PI * rightFreq * t) * 0.32;
  }
  for (let i = 0; i < matchFrames; i++) {
    left[coreFrames + i] = left[i];
    right[coreFrames + i] = right[i];
  }
  const buffer = {
    left,
    right,
    sampleRate: BINAURAL_LOOP_SAMPLE_RATE,
    loopMeta: buildLoopMeta(BINAURAL_LOOP_SAMPLE_RATE, 0, coreFrames, frames),
  };
  LOOP_BUFFER_CACHE.binaural.set(presetKey, buffer);
  return buffer;
}

export function getBinauralLoopMeta(presetKey) {
  return getBinauralLoopBuffer(presetKey).loopMeta;
}

export function getBinauralLoopUrl(presetKey, gain = 1) {
  const quantizedGain = clamp01(gain);
  if (Math.abs(quantizedGain - 1) < LOOP_SCALED_GAIN_EPSILON) {
    if (LOOP_URL_CACHE.binaural.has(presetKey)) return LOOP_URL_CACHE.binaural.get(presetKey);
    const { left, right, sampleRate } = getBinauralLoopBuffer(presetKey);
    const url = buildStereoWavUrl(left, right, sampleRate);
    LOOP_URL_CACHE.binaural.set(presetKey, url);
    return url;
  }
  const { left, right, sampleRate } = getBinauralLoopBuffer(presetKey);
  return buildStereoWavUrl(left, right, sampleRate, quantizedGain);
}

export function configureHiddenAudioElement(audio) {
  audio.crossOrigin = 'anonymous';
  audio.playsInline = true;
  audio.loop = true;
  audio.preload = 'auto';
  audio.setAttribute('playsinline', '');
  audio.setAttribute('webkit-playsinline', '');
  audio.setAttribute('x-webkit-airplay', 'deny');
  if ('disableRemotePlayback' in audio) audio.disableRemotePlayback = true;
  Object.assign(audio.style, {
    position: 'fixed',
    width: '1px',
    height: '1px',
    bottom: '0',
    left: '0',
    opacity: '0.001',
    pointerEvents: 'none',
  });
}

// ─── App ──────────────────────────────────────────────────────────────────────