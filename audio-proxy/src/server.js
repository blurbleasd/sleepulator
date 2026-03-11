const http = require('node:http');
const { spawn } = require('node:child_process');

const PORT = Number.parseInt(process.env.PORT || '8788', 10);
const HOST = process.env.HOST || '0.0.0.0';
const FFMPEG_BIN = process.env.FFMPEG_BIN || 'ffmpeg';

const DEFAULT_ALLOWED_ORIGINS = [
  'https://blurbleasd.github.io',
  'http://127.0.0.1:4173',
  'http://localhost:4173',
  'http://127.0.0.1:4177',
  'http://localhost:4177',
].join(',');

const DEFAULT_ALLOWED_AUDIO_HOSTS = [
  'cbbworld.memberfulcontent.com',
].join(',');

const PROFILE_FILTERS = {
  'sleep-safe': [
    'loudnorm=I=-21:LRA=11:TP=-2:linear=false',
    'alimiter=limit=0.891251:attack=5:release=50:level=disabled:latency=1',
    'aresample=48000',
  ].join(','),
};

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

function isAllowedHost(hostname) {
  const patterns = splitCsv(process.env.ALLOWED_AUDIO_HOSTS || DEFAULT_ALLOWED_AUDIO_HOSTS);
  if (!patterns.length) return false;
  return patterns.some(pattern => hostMatches(pattern, hostname));
}

function getAllowedOrigin(request) {
  const origin = request.headers.origin || '';
  const allowedOrigins = splitCsv(process.env.ALLOWED_ORIGINS || DEFAULT_ALLOWED_ORIGINS);
  if (!allowedOrigins.length) return '';
  if (!origin) return allowedOrigins[0];
  return allowedOrigins.includes(origin) ? origin : '';
}

function corsHeaders(origin) {
  const headers = {
    'Access-Control-Allow-Methods': 'GET, HEAD, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
    'Access-Control-Expose-Headers': 'Content-Type, X-Sleepulator-Profile',
    'Cache-Control': 'no-store',
    'Vary': 'Origin',
    'X-Content-Type-Options': 'nosniff',
  };
  if (origin) headers['Access-Control-Allow-Origin'] = origin;
  return headers;
}

function writeJson(response, statusCode, body, headers = {}) {
  response.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    ...headers,
  });
  response.end(JSON.stringify(body));
}

function buildFfmpegArgs(sourceUrl, profile) {
  const filterGraph = PROFILE_FILTERS[profile];
  return [
    '-hide_banner',
    '-loglevel', 'error',
    '-nostdin',
    '-reconnect', '1',
    '-reconnect_streamed', '1',
    '-reconnect_delay_max', '5',
    '-i', sourceUrl,
    '-vn',
    '-map_metadata', '-1',
    '-map', '0:a:0',
    '-af', filterGraph,
    '-ac', '2',
    '-ar', '48000',
    '-c:a', 'libmp3lame',
    '-b:a', process.env.TARGET_BITRATE || '96k',
    '-f', 'mp3',
    'pipe:1',
  ];
}

function handleAudio(request, response, allowedOrigin, sourceUrl, profile) {
  const ffmpeg = spawn(FFMPEG_BIN, buildFfmpegArgs(sourceUrl, profile), {
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stderr = '';
  let headersSent = false;

  const headers = {
    ...corsHeaders(allowedOrigin),
    'Content-Type': 'audio/mpeg',
    'X-Sleepulator-Profile': profile,
  };

  const cleanUp = () => {
    if (!ffmpeg.killed) ffmpeg.kill('SIGTERM');
  };

  request.on('close', cleanUp);
  response.on('close', cleanUp);

  ffmpeg.stderr.on('data', chunk => {
    stderr += chunk.toString();
    if (stderr.length > 4000) stderr = stderr.slice(-4000);
  });

  ffmpeg.once('error', error => {
    if (headersSent) {
      response.destroy(error);
      return;
    }
    writeJson(response, 502, {
      error: 'Could not start ffmpeg.',
      detail: error.message,
    }, corsHeaders(allowedOrigin));
  });

  ffmpeg.stdout.once('data', firstChunk => {
    headersSent = true;
    response.writeHead(200, headers);
    response.write(firstChunk);
    ffmpeg.stdout.pipe(response);
  });

  ffmpeg.once('close', code => {
    request.off('close', cleanUp);
    response.off('close', cleanUp);

    if (!headersSent) {
      writeJson(response, 502, {
        error: 'Audio transcoding failed.',
        detail: stderr.trim() || `ffmpeg exited with code ${code}.`,
      }, corsHeaders(allowedOrigin));
      return;
    }

    if (!response.writableEnded) response.end();
  });
}

const server = http.createServer((request, response) => {
  const allowedOrigin = getAllowedOrigin(request);
  const baseHeaders = corsHeaders(allowedOrigin);

  if (request.method === 'OPTIONS') {
    response.writeHead(204, baseHeaders);
    response.end();
    return;
  }

  if (!allowedOrigin) {
    writeJson(response, 403, { error: 'Origin not allowed.' }, baseHeaders);
    return;
  }

  const requestUrl = new URL(request.url, `http://${request.headers.host}`);

  if (requestUrl.pathname === '/health') {
    writeJson(response, 200, {
      ok: true,
      ffmpeg: FFMPEG_BIN,
      profiles: Object.keys(PROFILE_FILTERS),
    }, baseHeaders);
    return;
  }

  if (requestUrl.pathname !== '/audio') {
    writeJson(response, 404, { error: 'Not found.' }, baseHeaders);
    return;
  }

  if (request.method !== 'GET' && request.method !== 'HEAD') {
    writeJson(response, 405, { error: 'Use GET /audio?url=https://...&profile=sleep-safe' }, baseHeaders);
    return;
  }

  const sourceUrl = (requestUrl.searchParams.get('url') || '').trim();
  const profile = (requestUrl.searchParams.get('profile') || 'sleep-safe').trim();

  if (!sourceUrl) {
    writeJson(response, 400, { error: 'Missing source url.' }, baseHeaders);
    return;
  }

  if (!PROFILE_FILTERS[profile]) {
    writeJson(response, 400, {
      error: 'Unknown profile.',
      supportedProfiles: Object.keys(PROFILE_FILTERS),
    }, baseHeaders);
    return;
  }

  let parsedSource;
  try {
    parsedSource = new URL(sourceUrl);
  } catch {
    writeJson(response, 400, { error: 'Source url must be absolute.' }, baseHeaders);
    return;
  }

  if (!/^https?:$/.test(parsedSource.protocol)) {
    writeJson(response, 400, { error: 'Only http and https audio sources are supported.' }, baseHeaders);
    return;
  }

  if (!isAllowedHost(parsedSource.hostname)) {
    writeJson(response, 403, { error: `Audio host ${parsedSource.hostname} is not allowed.` }, baseHeaders);
    return;
  }

  if (request.method === 'HEAD') {
    response.writeHead(200, {
      ...baseHeaders,
      'Content-Type': 'audio/mpeg',
      'X-Sleepulator-Profile': profile,
    });
    response.end();
    return;
  }

  handleAudio(request, response, allowedOrigin, parsedSource.toString(), profile);
});

if (require.main === module) {
  server.listen(PORT, HOST, () => {
    console.log(`Sleepulator audio proxy listening on http://${HOST}:${PORT}`);
  });
}

module.exports = { server, buildFfmpegArgs };
