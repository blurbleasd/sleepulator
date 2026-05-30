window.SLEEPULATOR_CONFIG = Object.assign(
  {
    feedProxyUrl: 'https://sleepulator-feed-proxy.chesteraarfer.workers.dev',
    feedDebug: false,
    audioProxyUrl: '',
    sleepSafeAudioEnabled: false,
  },
  window.SLEEPULATOR_CONFIG || {}
);
