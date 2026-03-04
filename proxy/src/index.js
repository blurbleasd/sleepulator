const FEED_ACCEPT_HEADER = 'application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9, text/plain;q=0.7, */*;q=0.1';

function splitCsv(value) {
  return (value || '')
    .split(',')
    .map(entry => entry.trim())
    .filter(Boolean);
}

function hostMatches(pattern, hostname) {
  const normalizedPattern = pattern.toLowerCase();
  const normalizedHost = hostname.toLowerCase();
  if (normalizedPattern.startsWith('*.')) {
    const suffix = normalizedPattern.slice(1);
    return normalizedHost.endsWith(suffix);
  }
  return normalizedHost === normalizedPattern;
}

function isAllowedHost(hostname, env) {
  const patterns = splitCsv(env.ALLOWED_FEED_HOSTS);
  if (!patterns.length) return false;
  return patterns.some(pattern => hostMatches(pattern, hostname));
}

function getAllowedOrigin(request, env) {
  const origin = request.headers.get('Origin') || '';
  const allowedOrigins = splitCsv(env.ALLOWED_ORIGINS);
  if (!allowedOrigins.length) return '';
  if (!origin) return allowedOrigins[0];
  return allowedOrigins.includes(origin) ? origin : '';
}

function corsHeaders(origin) {
  const headers = new Headers({
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Expose-Headers': 'Content-Type, X-Sleepulator-Final-Url, X-Sleepulator-Upstream-Status',
    'Cache-Control': 'no-store',
    'Vary': 'Origin',
  });
  if (origin) headers.set('Access-Control-Allow-Origin', origin);
  return headers;
}

function jsonResponse(body, status, headers) {
  const responseHeaders = new Headers(headers);
  responseHeaders.set('Content-Type', 'application/json; charset=utf-8');
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

export default {
  async fetch(request, env) {
    const allowedOrigin = getAllowedOrigin(request, env);
    const headers = corsHeaders(allowedOrigin);

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers });
    }

    if (!allowedOrigin) {
      return jsonResponse({ error: 'Origin not allowed.' }, 403, headers);
    }

    if (request.method !== 'POST') {
      return jsonResponse({ error: 'Use POST with JSON body { "url": "https://..." }.' }, 405, headers);
    }

    let payload;
    try {
      payload = await request.json();
    } catch {
      return jsonResponse({ error: 'Invalid JSON body.' }, 400, headers);
    }

    const targetUrl = (payload?.url || '').trim();
    if (!targetUrl) {
      return jsonResponse({ error: 'Missing feed URL.' }, 400, headers);
    }

    let parsedTarget;
    try {
      parsedTarget = new URL(targetUrl);
    } catch {
      return jsonResponse({ error: 'Feed URL must be absolute.' }, 400, headers);
    }

    if (!/^https?:$/.test(parsedTarget.protocol)) {
      return jsonResponse({ error: 'Only http and https feeds are supported.' }, 400, headers);
    }

    if (!isAllowedHost(parsedTarget.hostname, env)) {
      return jsonResponse({ error: `Host ${parsedTarget.hostname} is not allowed.` }, 403, headers);
    }

    const upstreamHeaders = new Headers({ Accept: FEED_ACCEPT_HEADER });
    const authHeader = (payload?.authHeader || '').trim();
    if (authHeader && /^Basic\s+/i.test(authHeader)) {
      upstreamHeaders.set('Authorization', authHeader);
    }

    let upstream;
    try {
      upstream = await fetch(parsedTarget.toString(), {
        method: 'GET',
        headers: upstreamHeaders,
        redirect: 'follow',
        cf: { cacheTtl: 0, cacheEverything: false },
      });
    } catch (error) {
      return jsonResponse({ error: 'Upstream request failed.', detail: error?.message || 'Unknown error.' }, 502, headers);
    }

    const body = await upstream.text();
    headers.set('Content-Type', upstream.headers.get('Content-Type') || 'text/plain; charset=utf-8');
    headers.set('X-Sleepulator-Final-Url', upstream.url || parsedTarget.toString());
    headers.set('X-Sleepulator-Upstream-Status', String(upstream.status));
    return new Response(body, { status: upstream.status, headers });
  },
};
