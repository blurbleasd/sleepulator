window.SLEEPULATOR_CONFIG = Object.assign(
  {
    feedProxyUrl: 'https://sleepulator-feed-proxy.chesteraarfer.workers.dev',
    feedDebug: false,
    // Sleep Safe audio proxy (the Render `sleepulator-audio-proxy` service:
    // loudness-normalizes + limits podcast audio so volume spikes don't wake you).
    // This pre-fills the Settings field. VERIFY this matches your Render dashboard
    // URL. Left disabled by default so a wrong/asleep URL can't block playback —
    // flip "Sleep Safe Audio" on in Settings once you've confirmed an episode plays.
    audioProxyUrl: 'https://sleepulator-audio-proxy.onrender.com',
    sleepSafeAudioEnabled: false,
  },
  window.SLEEPULATOR_CONFIG || {}
);
