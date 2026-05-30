
export function hashUrl(str) {
  let h = 0;
  for (let i = 0; i < str.length; i++) h = (Math.imul(31, h) + str.charCodeAt(i)) | 0;
  return 'ep_' + Math.abs(h).toString(36);
}

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

const DEFAULT_FEED_PROXY_URL = 'https://sleepulator-feed-proxy.chesteraarfer.workers.dev';
export function getDefaultFeedProxyUrl(APP_CONFIG = {}) {
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

export function isIOSDevice() {
  const ua = navigator.userAgent || '';
  return /iP(hone|ad|od)/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

export function isStandaloneWebApp() {
  return window.matchMedia?.('(display-mode: standalone)')?.matches || window.navigator.standalone === true;
}
