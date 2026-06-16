import { describe, it, expect } from 'vitest';
import {
  clamp01,
  shortenSecret,
  redactUrlForDisplay,
  buildSleepSafeAudioUrl,
  parseDuration,
  fmtTime,
  previewText,
  deriveFeedName,
  inferPodcastTitle,
  dedupeEpisodes,
  parseOpmlFeeds,
  nextEpisode,
  makeSeamlessLoop,
  NOISE_TYPES,
} from './core.js';

describe('clamp01', () => {
  it('clamps to the 0..1 range', () => {
    expect(clamp01(-5)).toBe(0);
    expect(clamp01(0)).toBe(0);
    expect(clamp01(0.42)).toBeCloseTo(0.42);
    expect(clamp01(1)).toBe(1);
    expect(clamp01(99)).toBe(1);
  });
});

describe('shortenSecret', () => {
  it('returns short values untouched', () => {
    expect(shortenSecret('abc')).toBe('abc');
    expect(shortenSecret('')).toBe('');
  });
  it('masks the middle of long secrets', () => {
    const out = shortenSecret('abcdefghijklmnop');
    expect(out.startsWith('abcde')).toBe(true);
    expect(out.endsWith('nop')).toBe(true);
    expect(out).toContain('...');
  });
});

describe('redactUrlForDisplay', () => {
  it('returns empty for blank input', () => {
    expect(redactUrlForDisplay('')).toBe('');
    expect(redactUrlForDisplay('   ')).toBe('');
  });
  it('hides passwords embedded in the URL', () => {
    const out = redactUrlForDisplay('https://user:supersecret@example.com/feed');
    expect(out).not.toContain('supersecret');
    expect(out).toContain('***');
  });
  it('shortens sensitive query params (token, auth, sig...)', () => {
    const out = redactUrlForDisplay('https://example.com/feed?token=abcdefghijklmnop&page=2');
    expect(out).not.toContain('abcdefghijklmnop');
    expect(out).toContain('page=2');
  });
});

describe('buildSleepSafeAudioUrl', () => {
  it('returns the source unchanged when proxy is missing', () => {
    expect(buildSleepSafeAudioUrl('https://cdn.example.com/ep.mp3', '')).toBe(
      'https://cdn.example.com/ep.mp3',
    );
  });
  it('defaults the proxy path to /audio and attaches url + profile', () => {
    const out = buildSleepSafeAudioUrl('https://cdn.example.com/ep.mp3', 'https://proxy.example.com');
    expect(out).toContain('https://proxy.example.com/audio');
    expect(out).toContain('profile=sleep-safe');
    // source url is carried as an encoded query param
    expect(decodeURIComponent(out)).toContain('https://cdn.example.com/ep.mp3');
  });
  it('preserves an explicit proxy path', () => {
    const out = buildSleepSafeAudioUrl('https://cdn.example.com/ep.mp3', 'https://proxy.example.com/x');
    expect(out).toContain('https://proxy.example.com/x?');
  });
});

describe('parseDuration', () => {
  it('returns empty string for falsy or non-positive input', () => {
    expect(parseDuration('')).toBe('');
    expect(parseDuration('0')).toBe('');
    expect(parseDuration('abc')).toBe('');
  });
  it('parses raw seconds', () => {
    expect(parseDuration('45')).toBe('45s');
    expect(parseDuration('90')).toBe('1m 30s');
    expect(parseDuration('3600')).toBe('1h 0m');
  });
  it('parses colon-delimited timecodes', () => {
    expect(parseDuration('1:30')).toBe('1m 30s');
    expect(parseDuration('1:02:03')).toBe('1h 2m');
  });
});

describe('fmtTime', () => {
  it('handles invalid input', () => {
    expect(fmtTime(0)).toBe('0:00');
    expect(fmtTime(-5)).toBe('0:00');
    expect(fmtTime(NaN)).toBe('0:00');
  });
  it('formats minutes:seconds', () => {
    expect(fmtTime(65)).toBe('1:05');
    expect(fmtTime(605)).toBe('10:05');
  });
  it('formats hours:minutes:seconds', () => {
    expect(fmtTime(3661)).toBe('1:01:01');
  });
});

describe('previewText', () => {
  it('collapses whitespace and trims', () => {
    expect(previewText('  hello   world \n there ')).toBe('hello world there');
  });
  it('truncates beyond maxLength with an ellipsis', () => {
    const out = previewText('abcdefghij', 8);
    expect(out).toBe('abcde...');
    expect(out.length).toBe(8);
  });
});

describe('deriveFeedName', () => {
  it('uses the hostname without www', () => {
    expect(deriveFeedName('https://www.example.com/feed.xml')).toBe('example.com');
    expect(deriveFeedName('https://feeds.simplecast.com/abc')).toBe('feeds.simplecast.com');
  });
  it('falls back for empty input', () => {
    expect(deriveFeedName('')).toBe('Saved Feed');
  });
});

describe('inferPodcastTitle', () => {
  it('extracts a [Bracketed] show prefix', () => {
    expect(inferPodcastTitle('[Sleep With Me] Episode 900')).toBe('Sleep With Me');
  });
  it('returns empty when no prefix is present', () => {
    expect(inferPodcastTitle('Just a title')).toBe('');
  });
});

describe('dedupeEpisodes', () => {
  it('removes duplicates by id or url and drops keyless items', () => {
    const input = [
      { id: 'a', title: 'one' },
      { id: 'a', title: 'one-dupe' },
      { url: 'u1', title: 'two' },
      { url: 'u1', title: 'two-dupe' },
      { title: 'no-key' },
    ];
    const out = dedupeEpisodes(input);
    expect(out.map(e => e.title)).toEqual(['one', 'two']);
  });
});

describe('NOISE_TYPES generators', () => {
  const N = 4096;
  const SR = 44100;

  for (const [key, def] of Object.entries(NOISE_TYPES)) {
    it(`${key} fills both channels with finite, audible, bounded samples`, () => {
      const L = new Float32Array(N);
      const R = new Float32Array(N);
      def.fn(L, R, N, SR);

      let nonZero = 0;
      let maxAbs = 0;
      for (let i = 0; i < N; i++) {
        expect(Number.isFinite(L[i])).toBe(true);
        expect(Number.isFinite(R[i])).toBe(true);
        if (L[i] !== 0) nonZero++;
        maxAbs = Math.max(maxAbs, Math.abs(L[i]), Math.abs(R[i]));
      }
      // Produces an actual signal...
      expect(nonZero).toBeGreaterThan(N / 2);
      // ...that never blows up into a clipping/NaN range.
      expect(maxAbs).toBeLessThan(16);
    });
  }
});

describe('parseOpmlFeeds', () => {
  const opml = `<?xml version="1.0" encoding="UTF-8"?>
    <opml version="1.0"><body>
      <outline text="Tech News" type="rss" xmlUrl="https://feeds.example.com/tech" htmlUrl="https://example.com/tech"/>
      <outline text="Folder">
        <outline title="Sleepy Stories" type="rss" xmlUrl="https://feeds.example.com/stories"/>
        <outline text="Tech News" type="rss" xmlUrl="https://feeds.example.com/tech"/>
      </outline>
      <outline text="A folder with no feed"/>
    </body></opml>`;

  it('extracts feed url + name, recurses folders, and de-dupes', () => {
    const feeds = parseOpmlFeeds(opml);
    expect(feeds).toEqual([
      { url: 'https://feeds.example.com/tech', name: 'Tech News' },
      { url: 'https://feeds.example.com/stories', name: 'Sleepy Stories' },
    ]);
  });

  it('ignores outlines without a feed URL', () => {
    const feeds = parseOpmlFeeds('<opml><body><outline text="Just a folder"/></body></opml>');
    expect(feeds).toEqual([]);
  });

  it('returns [] for empty or malformed input', () => {
    expect(parseOpmlFeeds('')).toEqual([]);
    expect(parseOpmlFeeds(null)).toEqual([]);
    expect(parseOpmlFeeds('not xml at all <<<')).toEqual([]);
  });
});

describe('nextEpisode', () => {
  const list = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];

  it('returns the episode after the current one', () => {
    expect(nextEpisode(list, 'a')).toEqual({ id: 'b' });
    expect(nextEpisode(list, 'b')).toEqual({ id: 'c' });
  });

  it('wraps from the last episode back to the first', () => {
    expect(nextEpisode(list, 'c')).toEqual({ id: 'a' });
  });

  it('falls back to the first episode when current is unknown', () => {
    expect(nextEpisode(list, 'zzz')).toEqual({ id: 'a' });
  });

  it('returns null for an empty or invalid list', () => {
    expect(nextEpisode([], 'a')).toBe(null);
    expect(nextEpisode(null, 'a')).toBe(null);
  });
});

describe('makeSeamlessLoop', () => {
  // A ramp 0,1,2,... makes the seam easy to reason about: a perfect loop means
  // out[frames-1] then out[0] are consecutive values (no discontinuity).
  const frames = 100, xfade = 10;
  const raw = Float32Array.from({ length: frames + xfade }, (_, i) => i);
  const { left, right } = makeSeamlessLoop(raw, raw, frames, xfade);

  it('returns buffers of the loop length', () => {
    expect(left).toHaveLength(frames);
    expect(right).toHaveLength(frames);
  });

  it('leaves the body past the crossfade untouched', () => {
    for (let i = xfade; i < frames; i++) expect(left[i]).toBe(i);
  });

  it('makes the loop boundary continuous (end flows into start)', () => {
    // Looping plays ...out[frames-1], out[0], out[1]...
    // For the ramp: out[frames-1] = frames-1, out[0] = raw[frames] = frames.
    expect(left[frames - 1]).toBe(frames - 1);
    expect(left[0]).toBe(frames);            // continuation, not a jump back to 0
    expect(left[0] - left[frames - 1]).toBe(1); // one clean step across the seam
  });
});
