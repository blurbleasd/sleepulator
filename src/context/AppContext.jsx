import React, { createContext, useContext, useState, useEffect, useRef, useCallback } from 'react';
import {
  BookMarked, Clock, GripVertical, Moon, MoonStar, Pause, Play, Plus, RotateCcw, RotateCw, Rss, Search, Settings2, Shuffle, SlidersHorizontal, Square, Sun, Trash2, Volume2, VolumeX, Wind, X, HelpCircle
} from 'lucide-react';
import { mixBus } from '../audio/MixBus.js';

import {
  APP_CONFIG, LEGACY_DEFAULT_FEED_URL, DEFAULT_FEED_PROXY_URL, NATIVE_MEDIA_VOLUME_LOCK, hashUrl, FEED_TIMEOUT_MS, FEED_ACCEPT_HEADER, clamp01, shortenSecret, redactUrlForDisplay, normalizeConfigUrl, getDefaultFeedProxyUrl, buildSleepSafeAudioUrl, parseDuration, fmtTime, previewText, readStoredArray, deriveFeedName, inferPodcastTitle, dedupeEpisodes, describeError, mergeHeaders, withFeedHeaders, fetchWithTimeout, safeJsonParse, localNameOf, directElements, directMatches, descendantMatches, firstDirectText, firstDescendantText, firstAttrFromElements, firstText, firstAttr, resolveMaybeUrl, sniffMarkupType, looksLikeXmlFeed, extractEmbeddedFeedMarkup, discoverAlternateFeedUrl, normalizeFeedUrl, buildFeedSources, makeFeedError, formatFeedError, parseFeedEpisodes, nextEpisode, isIOSDevice, isStandaloneWebApp, generateBrown, generatePink, generateGreen, generateWhite, generateFan, generateRain, generateOcean, generateForest, NOISE_TYPES, BINAURAL, ARTWORK, LOOP_SAMPLE_RATE, BINAURAL_LOOP_SAMPLE_RATE, AMBIENT_LOOP_SECONDS, BINAURAL_LOOP_SECONDS, LOOP_TRANSITION_SECONDS, LOOP_MATCH_SECONDS, LOOP_SCALED_GAIN_EPSILON, LOOP_MUTED_GAIN_EPSILON, LOOP_SOURCE_TIME_FUZZ, LOOP_BUFFER_CACHE, LOOP_URL_CACHE, writeAscii, buildStereoWavUrl, buildLoopMeta, maybeWrapManualLoop, getAmbientLoopBuffer, getAmbientLoopMeta, getAmbientLoopUrl, getBinauralLoopBuffer, getBinauralLoopMeta, getBinauralLoopUrl, configureHiddenAudioElement
} from '../utils/core.js';

// Fallback glyphs for the imperative floating mute button. The app uses
// lucide-react components, so the `window.lucide` global isn't present and this
// fallback branch always runs — it must be defined or the button wiring throws.
const LUCIDE_FALLBACK_GLYPHS = { Volume2: '🔊', VolumeX: '🔇' };

export const AppContext = createContext(null);

export function AppProvider({ children }) {
  const [bm, setBm]               = useState(false); // bedtime mode
  const [muted, setMuted]         = useState(false);
  const [breathMode, setBreathMode]= useState(null); // null | '478' | 'box'
  const [masterVol, setMasterVol] = useState(()=>+localStorage.getItem('masterVolume')||1);

  // Ambient
  const [ambientOn,  setAmbientOn]  = useState(false);
  const [ambientVol, setAmbientVol] = useState(()=>+localStorage.getItem('brownVolume')||.5);
  const [noiseType,  setNoiseType]  = useState(()=>localStorage.getItem('noiseType')||'brown');
  const [ambientBypass, setAmbientBypass] = useState(()=>localStorage.getItem('ambientBypass')==='true');

  // Binaural
  const [binOn,  setBinOn]  = useState(false);
  const [binVol, setBinVol] = useState(()=>+localStorage.getItem('binauralVolume')||.5);
  const [binPreset, setBinPreset] = useState(()=>localStorage.getItem('binauralPreset')||'delta');
  const [binBypass, setBinBypass] = useState(()=>localStorage.getItem('binauralBypass')==='true');

  // Timer
  const [timerMins,   setTimerMins]  = useState(()=>parseInt(localStorage.getItem('timerMinutes'))||30);
  const [timerActive, setTimerActive]= useState(false);
  const [timeLeft,    setTimeLeft]   = useState(null);
  const timerEndRef  = useRef(null);
  const timerTickRef = useRef(null); // setInterval handle (not rAF — works in background)

  // Podcast
  const [episodes,      setEpisodes]      = useState([]);
  const [playlist,      setPlaylist]      = useState(()=>{
    // migrate legacy key
    const v=localStorage.getItem('sleepulatorPlaylist');
    if(v) return readStoredArray('sleepulatorPlaylist');
    const leg=localStorage.getItem('comedyPlaylist');
    if(leg){ localStorage.setItem('sleepulatorPlaylist',leg); localStorage.removeItem('comedyPlaylist'); return readStoredArray('sleepulatorPlaylist'); }
    return [];
  });
  const [eqOn, setEqOn] = useState(()=>localStorage.getItem('eqOn')==='true');
  const [compOn, setCompOn] = useState(()=>localStorage.getItem('compOn')==='true');
  const [panOn, setPanOn] = useState(()=>localStorage.getItem('panOn')==='true');
  const [duckOn, setDuckOn] = useState(()=>localStorage.getItem('duckAmbient')==='true');
  const [playingSrc,    setPlayingSrc]    = useState('feed');
  const [curEp,         setCurEp]         = useState(null);
  const [podPlaying,    setPodPlaying]    = useState(false);
  const [podVol,        setPodVol]        = useState(()=>+localStorage.getItem('podcastVolume')||+localStorage.getItem('comedyVolume')||.8);
  const [podSpeed,      setPodSpeed]      = useState(()=>+localStorage.getItem('playbackSpeed')||1);
  const [autoPlay,      setAutoPlay]      = useState(()=>localStorage.getItem('autoPlayEnabled')!=='false');
  const [shuffle,       setShuffle]       = useState(()=>localStorage.getItem('shuffleEnabled')==='true');
  const [preloadNext,   setPreloadNext]   = useState(()=>localStorage.getItem('preloadNext')!=='false');
  const [rssUrl,        setRssUrl]        = useState(()=>{
    const stored = (localStorage.getItem('rssUrl') || '').trim();
    return stored && stored !== LEGACY_DEFAULT_FEED_URL ? stored : '';
  });
  const [loading,       setLoading]       = useState(false);
  const [feedErr,       setFeedErr]       = useState('');
  const [feedNote,      setFeedNote]      = useState('');
  const [feedProxyUrl,  setFeedProxyUrl]  = useState(()=>{
    const stored = (localStorage.getItem('feedProxyUrl') || '').trim();
    return stored || getDefaultFeedProxyUrl();
  });
  const [audioProxyUrl, setAudioProxyUrl] = useState(()=>{
    const stored = (localStorage.getItem('audioProxyUrl') || '').trim();
    return stored || normalizeConfigUrl(APP_CONFIG.audioProxyUrl || '');
  });
  const [sleepSafeAudio, setSleepSafeAudio] = useState(()=>{
    const stored = localStorage.getItem('sleepSafeAudioEnabled');
    if (stored === 'true') return true;
    if (stored === 'false') return false;
    return APP_CONFIG.sleepSafeAudioEnabled === true;
  });
  const [feedDebug,     setFeedDebug]     = useState(null);
  const [showFeedDebug, setShowFeedDebug] = useState(()=>APP_CONFIG.feedDebug === true || localStorage.getItem('showFeedDebug') === 'true');
  const [subs,          setSubs]          = useState(()=>readStoredArray('feedSubs'));
  const [showSubs,      setShowSubs]      = useState(false);
  const [subName,       setSubName]       = useState('');
  const [savedPlaylists, setSavedPlaylists] = useState(()=>readStoredArray('savedPlaylists'));
  const [mixPresets, setMixPresets] = useState(()=>readStoredArray('mixPresets'));
  const [cachedEpisodes, setCachedEpisodes] = useState({});
  const [downloadProgress, setDownloadProgress] = useState({});
  // navigator.onLine is a soft hint (it lies on captive portals), so we use it
  // only to gray out un-downloaded episodes — never to block cached playback.
  const [online, setOnline] = useState(()=> typeof navigator === 'undefined' ? true : navigator.onLine !== false);

  // Initialize cachedEpisodes on mount
  useEffect(() => {
    caches.open('sleepulator-episodes').then(cache => {
      cache.keys().then(keys => {
        const urlMap = {};
        keys.forEach(req => { urlMap[req.url] = true; });
        setCachedEpisodes(urlMap);
      });
    });
  }, []);

  const [showPlaylistLibrary, setShowPlaylistLibrary] = useState(false);
  const [playlistName,  setPlaylistName]  = useState('');
  const [podProgress,   setPodProgress]   = useState({cur:0,dur:0});
  const dragSrcRef = useRef(null);
  const normalizedAudioProxyUrl = normalizeConfigUrl(audioProxyUrl);
  const sleepSafeConfigured = !!normalizedAudioProxyUrl;

  // Audio refs
  const ambientAudio = useRef(null);
  const binAudio     = useRef(null);
  const podAudio = useRef(null);
  const playNextRef   = useRef(null);
  const activeBlobUrlRef = useRef(null);
  const progInterval  = useRef(null);
  const wakeLock      = useRef(null);
  const iosAdvanceLock = useRef(false);
  const podStateRef    = useRef({});
  const iosPwaAudio    = useRef(isIOSDevice() && isStandaloneWebApp());
  const ambientManagedUrl = useRef('');
  const binManagedUrl = useRef('');
  const ambientSourceKey = useRef('');
  const binSourceKey = useRef('');
  const ambientLoopMeta = useRef(null);
  const binLoopMeta = useRef(null);
  const ambientWrapLock = useRef(false);
  const binWrapLock = useRef(false);
  // Last podcast playback URL + a snapshot of live state, used to recreate
  // elements after MixBus rebuilds a dead (iOS-closed) AudioContext.
  const lastPodUrl = useRef('');
  const liveRef = useRef({});
  const prefetchingRef = useRef(new Set()); // episode URLs currently being preloaded
  const prefetchedRef  = useRef(new Set()); // auto-cached URLs (evictable; not user downloads)
  const setNativeAudioLevel = useCallback((audio, volume, muteState) => {
    if (!audio) return;
    audio.muted = !!muteState || volume <= LOOP_MUTED_GAIN_EPSILON;
    if (!NATIVE_MEDIA_VOLUME_LOCK) {
      audio.volume = clamp01(volume);
    }
  }, []);

  // ── Multi-instance conflict resolution ────────────────────────────────────
  // A second open instance (e.g. the PWA plus a stray Safari tab) playing the
  // same brown noise causes phase-cancellation that ruins a night's sleep. Each
  // instance claims playback over a BroadcastChannel when it starts; any other
  // instance hearing that claim silences itself. stopAllForRemote is held in a
  // ref so the once-registered listener always calls the latest closures.
  const bcRef = useRef(null);
  const instanceId = useRef(Math.random().toString(36).slice(2));
  const stopAllForRemoteRef = useRef(() => {});
  const claimPlayback = useCallback(() => {
    try { bcRef.current?.postMessage({ type: 'PLAYING', id: instanceId.current, t: Date.now() }); } catch (e) {}
  }, []);
  const swapManagedLoopSource = useCallback((audio, nextUrl, managedRef, loopDuration, preservePosition = true, managed = false) => {
    if (!audio || !nextUrl) return;
    const currentSrc = audio.currentSrc || audio.src || '';
    const previousManaged = managedRef.current || '';
    if (currentSrc === nextUrl) {
      if (!managed && previousManaged) {
        URL.revokeObjectURL(previousManaged);
        managedRef.current = '';
      }
      return;
    }

    const wasPlaying = !audio.paused;
    const previousTime = preservePosition && Number.isFinite(audio.currentTime) ? audio.currentTime : 0;
    const resumeAt = loopDuration ? previousTime % loopDuration : previousTime;
    if (wasPlaying) audio.pause();
    audio.src = nextUrl;
    audio.load();
    if ((wasPlaying || resumeAt > LOOP_SOURCE_TIME_FUZZ) && (preservePosition || wasPlaying)) {
      const restore = () => {
        if (resumeAt > LOOP_SOURCE_TIME_FUZZ) {
          try { audio.currentTime = resumeAt; } catch(e){}
        }
        if (wasPlaying) audio.play().catch(()=>{});
      };
      audio.addEventListener('loadedmetadata', restore, { once: true });
    }

    if (previousManaged && previousManaged !== nextUrl) {
      URL.revokeObjectURL(previousManaged);
    }
    managedRef.current = managed ? nextUrl : '';
  }, []);
  const syncPodVolume = useCallback((scale = 1, muteState = muted) => {
    if (podAudio.current) {
      mixBus.setMasterVolume(muteState ? 0 : masterVol);
      mixBus.setSourceVolume('pod', podVol * scale);
      setNativeAudioLevel(podAudio.current, podVol * masterVol * scale, muteState);
    }
  }, [podVol, masterVol, muted, setNativeAudioLevel]);
  const syncAmbientVolume = useCallback((scale = 1, muteState = muted, options = {}) => {
    const audio = ambientAudio.current;
    if (!audio) return;
    const gain = clamp01(ambientVol * masterVol * scale);
    const preservePosition = options.preservePosition !== false;
    const allowSourceRebuild = options.allowSourceRebuild !== false;
    const baseSourceKey = `ambient:${noiseType}:base`;
    ambientLoopMeta.current = getAmbientLoopMeta(noiseType);
    mixBus.setMasterVolume(muteState ? 0 : masterVol);
    mixBus.setSourceVolume('ambient', ambientVol * scale);

    if (NATIVE_MEDIA_VOLUME_LOCK) {
      if (allowSourceRebuild && gain > LOOP_MUTED_GAIN_EPSILON) {
        const managed = Math.abs(gain - 1) >= LOOP_SCALED_GAIN_EPSILON;
        const sourceKey = managed ? `ambient:${noiseType}:${gain.toFixed(2)}` : baseSourceKey;
        const nextUrl = managed && ambientSourceKey.current === sourceKey && ambientManagedUrl.current
          ? ambientManagedUrl.current
          : getAmbientLoopUrl(noiseType, gain);
        swapManagedLoopSource(audio, nextUrl, ambientManagedUrl, AMBIENT_LOOP_SECONDS, preservePosition, managed);
        ambientSourceKey.current = sourceKey;
      }
      setNativeAudioLevel(audio, 1, muteState || gain <= LOOP_MUTED_GAIN_EPSILON);
      if (ambientOn && !audio.muted && audio.paused && gain > LOOP_MUTED_GAIN_EPSILON) {
        audio.play().catch(()=>{});
      }
      return;
    }

    swapManagedLoopSource(audio, getAmbientLoopUrl(noiseType), ambientManagedUrl, AMBIENT_LOOP_SECONDS, preservePosition, false);
    ambientSourceKey.current = baseSourceKey;
    setNativeAudioLevel(audio, gain, muteState);
    if (ambientOn && !audio.muted && audio.paused && gain > LOOP_MUTED_GAIN_EPSILON) {
      audio.play().catch(()=>{});
    }
  }, [ambientVol, masterVol, muted, noiseType, ambientOn, setNativeAudioLevel, swapManagedLoopSource]);
  const syncBinVolume = useCallback((scale = 1, muteState = muted, options = {}) => {
    const audio = binAudio.current;
    if (!audio) return;
    const gain = clamp01(binVol * masterVol * scale);
    const preservePosition = options.preservePosition !== false;
    const allowSourceRebuild = options.allowSourceRebuild !== false;
    const baseSourceKey = `binaural:${binPreset}:base`;
    binLoopMeta.current = getBinauralLoopMeta(binPreset);
    mixBus.setMasterVolume(muteState ? 0 : masterVol);
    mixBus.setSourceVolume('bin', binVol * scale);

    if (NATIVE_MEDIA_VOLUME_LOCK) {
      if (allowSourceRebuild && gain > LOOP_MUTED_GAIN_EPSILON) {
        const managed = Math.abs(gain - 1) >= LOOP_SCALED_GAIN_EPSILON;
        const sourceKey = managed ? `binaural:${binPreset}:${gain.toFixed(2)}` : baseSourceKey;
        const nextUrl = managed && binSourceKey.current === sourceKey && binManagedUrl.current
          ? binManagedUrl.current
          : getBinauralLoopUrl(binPreset, gain);
        swapManagedLoopSource(audio, nextUrl, binManagedUrl, BINAURAL_LOOP_SECONDS, preservePosition, managed);
        binSourceKey.current = sourceKey;
      }
      setNativeAudioLevel(audio, 1, muteState || gain <= LOOP_MUTED_GAIN_EPSILON);
      if (binOn && !audio.muted && audio.paused && gain > LOOP_MUTED_GAIN_EPSILON) {
        audio.play().catch(()=>{});
      }
      return;
    }

    swapManagedLoopSource(audio, getBinauralLoopUrl(binPreset), binManagedUrl, BINAURAL_LOOP_SECONDS, preservePosition, false);
    binSourceKey.current = baseSourceKey;
    setNativeAudioLevel(audio, gain, muteState);
    if (binOn && !audio.muted && audio.paused && gain > LOOP_MUTED_GAIN_EPSILON) {
      audio.play().catch(()=>{});
    }
  }, [binVol, masterVol, muted, binPreset, binOn, setNativeAudioLevel, swapManagedLoopSource]);
  const setPlaybackAudioSession = useCallback(() => {
    try {
      if (navigator.audioSession && navigator.audioSession.type !== 'playback') {
        navigator.audioSession.type = 'playback';
      }
    } catch(e){}
  }, []);
  const syncMediaPositionState = useCallback(() => {
    if (!('mediaSession' in navigator) || typeof navigator.mediaSession.setPositionState !== 'function') return;
    const audio = podAudio.current;
    if (!audio || !Number.isFinite(audio.duration) || audio.duration <= 0) return;
    try {
      navigator.mediaSession.setPositionState({
        duration: audio.duration,
        playbackRate: audio.playbackRate || 1,
        position: Math.min(audio.currentTime, audio.duration),
      });
    } catch(e){}
  }, []);
  const resumeSoundscapeAudio = useCallback(() => {
    mixBus.resumeContext();
    if (ambientOn) {
      syncAmbientVolume(1, false);
      ambientAudio.current?.play().catch(()=>{});
    }
    if (binOn) {
      syncBinVolume(1, false);
      binAudio.current?.play().catch(()=>{});
    }
  }, [ambientOn, binOn, eqOn, compOn, panOn, syncAmbientVolume, syncBinVolume]);
  const pauseSoundscapeAudio = useCallback(() => {
    ambientAudio.current?.pause();
    binAudio.current?.pause();
  }, []);

  useEffect(()=>{
    podStateRef.current = { autoPlay, shuffle, playingSrc, episodes, playlist, curEp };
  },[autoPlay, shuffle, playingSrc, episodes, playlist, curEp]);

  // ── Persist settings ──────────────────────────────────────────────────────
  // Apply podcast effects + ducking to the audio graph. Kept separate from the
  // persistence effect so toggling an effect only touches the audio graph (and
  // a graph command never rides on an unrelated setting change).
  useEffect(()=>{
    mixBus.setEffects('pod', { eqOn, compOn, panOn });
    mixBus.setDucking(duckOn);
  },[eqOn, compOn, panOn, duckOn]);

  useEffect(()=>{
    try {
      localStorage.setItem('masterVolume',            masterVol);
      localStorage.setItem('eqOn',                    eqOn);
      localStorage.setItem('compOn',                  compOn);
      localStorage.setItem('panOn',                   panOn);
      localStorage.setItem('duckAmbient',             duckOn);
      localStorage.setItem('brownVolume',             ambientVol);
      localStorage.setItem('noiseType',               noiseType);
      localStorage.setItem('ambientBypass',           ambientBypass);
      localStorage.setItem('binauralVolume',          binVol);
      localStorage.setItem('binauralPreset',          binPreset);
      localStorage.setItem('binauralBypass',          binBypass);
      localStorage.setItem('podcastVolume',           podVol);
      localStorage.setItem('playbackSpeed',           podSpeed);
      localStorage.setItem('autoPlayEnabled',         autoPlay);
      localStorage.setItem('preloadNext',             preloadNext);
      localStorage.setItem('shuffleEnabled',          shuffle);
      localStorage.setItem('timerMinutes',            timerMins);
      localStorage.setItem('rssUrl',                  rssUrl);
      localStorage.setItem('feedProxyUrl',            feedProxyUrl);
      localStorage.setItem('audioProxyUrl',           audioProxyUrl);
      localStorage.setItem('sleepSafeAudioEnabled',   sleepSafeAudio);
      localStorage.setItem('showFeedDebug',           showFeedDebug);
      localStorage.setItem('sleepulatorPlaylist',     JSON.stringify(playlist));
      localStorage.setItem('feedSubs',                JSON.stringify(subs));
      localStorage.setItem('savedPlaylists',          JSON.stringify(savedPlaylists));
      localStorage.setItem('mixPresets',              JSON.stringify(mixPresets));
    } catch(e){}
  },[masterVol,eqOn,compOn,panOn,duckOn,ambientVol,noiseType,ambientBypass,binVol,binPreset,binBypass,
     podVol,podSpeed,autoPlay,shuffle,preloadNext,
     timerMins,rssUrl,feedProxyUrl,audioProxyUrl,sleepSafeAudio,showFeedDebug,playlist,subs,savedPlaylists,mixPresets]);

  // ── Service Worker ────────────────────────────────────────────────────────
  useEffect(()=>{
    if('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js').catch(()=>{});
    const banner=(d)=>{ const el=document.getElementById('offline-banner'); if(el) el.style.display=d; };
    const show=()=>{ setOnline(false); banner('block'); };
    const hide=()=>{ setOnline(true);  banner('none'); };
    window.addEventListener('offline',show); window.addEventListener('online',hide);
    return ()=>{ window.removeEventListener('offline',show); window.removeEventListener('online',hide); };
  },[]);

  // ── Multi-instance playback channel ───────────────────────────────────────
  // Registered once. When another instance claims playback, silence this one.
  useEffect(()=>{
    if (typeof BroadcastChannel === 'undefined') return;
    const ch = new BroadcastChannel('sleepulator-playback');
    bcRef.current = ch;
    ch.onmessage = (e) => {
      if (e?.data?.type === 'PLAYING' && e.data.id !== instanceId.current) {
        stopAllForRemoteRef.current();
      }
    };
    return ()=>{ try { ch.close(); } catch(err){} bcRef.current = null; };
  },[]);

  // ── Bedtime mode class on root ────────────────────────────────────────────
  useEffect(()=>{
    document.documentElement.classList.toggle('bm', bm);
  },[bm]);

  // ── Wake Lock (keeps screen awake while audio plays) ─────────────────────
  const anyPlaying = ambientOn || binOn || podPlaying;
  useEffect(()=>{
    if (!('wakeLock' in navigator)) return;
    if (anyPlaying && !muted) {
      setPlaybackAudioSession();
      navigator.wakeLock.request('screen').then(wl=>{ wakeLock.current=wl; }).catch(()=>{});
    } else {
      wakeLock.current?.release().catch(()=>{});
      wakeLock.current = null;
    }
    return ()=>{ wakeLock.current?.release().catch(()=>{}); };
  },[anyPlaying, muted, setPlaybackAudioSession]);

  // Re-acquire wake lock after visibility change (it's released automatically on hide)
  useEffect(()=>{
    const handler = async () => {
      if (document.visibilityState==='visible' && anyPlaying && !muted && 'wakeLock' in navigator) {
        try { wakeLock.current = await navigator.wakeLock.request('screen'); } catch(e){}
      }
    };
    document.addEventListener('visibilitychange', handler);
    return ()=> document.removeEventListener('visibilitychange', handler);
  },[anyPlaying, muted]);

  // ── Headphone disconnect ──────────────────────────────────────────────────
  useEffect(()=>{
    if (!navigator.mediaDevices?.addEventListener) return;
    const handler = async () => {
      const devs = await navigator.mediaDevices.enumerateDevices().catch(()=>[]);
      const hasHP = devs.some(d=>d.kind==='audiooutput' && /head|ear|airpod|bluetooth/i.test(d.label));
      if (!hasHP && (podPlaying||ambientOn||binOn)) {
        ambientAudio.current?.pause();
        binAudio.current?.pause();
        podAudio.current?.pause();
        setPodPlaying(false);
      }
    };
    navigator.mediaDevices.addEventListener('devicechange', handler);
    return ()=> navigator.mediaDevices.removeEventListener('devicechange', handler);
  },[podPlaying, ambientOn, binOn]);

  // ── Floating mute button wiring ───────────────────────────────────────────
  useEffect(()=>{
    const btn = document.getElementById('mute-btn');
    if (!btn) return;
    btn.style.display = anyPlaying ? 'flex' : 'none';
    btn.classList.toggle('muted', muted);
    // render SVG icon
    const icon = muted ? 'VolumeX' : 'Volume2';
    const iconData = window.lucide?.[icon];
    if (iconData) {
      const children = iconData||[];
      const paths = children.map(([tag,attrs],i)=>{
        const aStr = Object.entries(attrs).map(([k,v])=>`${k}="${v}"`).join(' ');
        return `<${tag} ${aStr}/>`;
      }).join('');
      btn.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="${muted?'#f87171':'#94a3b8'}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${paths}</svg>`;
    } else {
      btn.innerHTML = `<span style="font-size:20px;line-height:1">${LUCIDE_FALLBACK_GLYPHS[icon] || '•'}</span>`;
    }
    const handler = () => setMuted(m=>!m);
    btn.addEventListener('click', handler);
    return ()=> btn.removeEventListener('click', handler);
  },[anyPlaying, muted]);

  // ── Mute: volume-only across all active audio ─────────────────────────────
  useEffect(()=>{
    syncAmbientVolume();
    syncBinVolume();
    syncPodVolume();
  },[muted, syncAmbientVolume, syncBinVolume, syncPodVolume]);

  // ── Media Session: ambient/binaural ──────────────────────────────────────
  useEffect(()=>{
    if (!('mediaSession' in navigator)) return;
    if ((ambientOn||binOn) && !podPlaying) {
      const label = ambientOn && binOn
        ? `${NOISE_TYPES[noiseType].label.replace(/^.{2}\s*/, '')} + ${BINAURAL[binPreset].name}`
        : ambientOn
          ? NOISE_TYPES[noiseType].label.replace(/^.{2}\s*/, '')
          : BINAURAL[binPreset].name;
      const sub = ambientOn && binOn
        ? 'Ambient Noise + Binaural Beats'
        : ambientOn
          ? 'Ambient Noise'
          : 'Binaural Beats';
      navigator.mediaSession.metadata = new MediaMetadata({title:label,artist:sub,album:'SLEEPULATOR',artwork:ARTWORK});
      navigator.mediaSession.playbackState = 'playing';
      navigator.mediaSession.setActionHandler('play',  ()=>{
        setPlaybackAudioSession();
        setMuted(false);
        resumeSoundscapeAudio();
        navigator.mediaSession.playbackState='playing';
      });
      navigator.mediaSession.setActionHandler('pause', ()=>{
        pauseSoundscapeAudio();
        setMuted(true);
        navigator.mediaSession.playbackState='paused';
      });
      navigator.mediaSession.setActionHandler('stop',  ()=>{ stopAmbient(); stopBin(); });
      navigator.mediaSession.setActionHandler('seekbackward', null);
      navigator.mediaSession.setActionHandler('seekforward',  null);
      navigator.mediaSession.setActionHandler('previoustrack',null);
      navigator.mediaSession.setActionHandler('nexttrack',    null);
    } else if (!ambientOn && !binOn && !podPlaying) {
      navigator.mediaSession.playbackState = 'none';
    }
  },[ambientOn, binOn, noiseType, binPreset, podPlaying, setPlaybackAudioSession, resumeSoundscapeAudio, pauseSoundscapeAudio]);

  // ── Media Session: podcast ────────────────────────────────────────────────
  useEffect(()=>{
    if (!('mediaSession' in navigator)) return;
    if (!curEp || (!podPlaying && (ambientOn || binOn))) return;
    const m = curEp.title.match(/^\[(.*?)\] (.*)$/);
    navigator.mediaSession.metadata = new MediaMetadata({
      title: m?m[2]:curEp.title, artist: m?m[1]:'Podcast', album:'SLEEPULATOR', artwork: ARTWORK
    });
    navigator.mediaSession.playbackState = podPlaying ? 'playing' : 'paused';
    navigator.mediaSession.setActionHandler('play',         ()=>{
      setPlaybackAudioSession();
      setMuted(false);
      syncPodVolume(1, false);
      podAudio.current?.play().catch(()=>{});
    });
    navigator.mediaSession.setActionHandler('pause',        ()=>{ podAudio.current?.pause(); });
    navigator.mediaSession.setActionHandler('seekbackward', ()=>skipPod(-15));
    navigator.mediaSession.setActionHandler('seekforward',  ()=>skipPod(15));
    navigator.mediaSession.setActionHandler('previoustrack',()=>{
      const list = playingSrc==='playlist'?playlist:episodes;
      const idx = list.findIndex(e=>e.id===curEp?.id);
      if(idx>0) playEp(list[idx-1], playingSrc);
    });
    navigator.mediaSession.setActionHandler('nexttrack', ()=>{ if(playNextRef.current) playNextRef.current(); });
    syncMediaPositionState();
  },[curEp, playlist, episodes, playingSrc, podPlaying, ambientOn, binOn, syncPodVolume, setPlaybackAudioSession, syncMediaPositionState]);

  
  useEffect(() => {
    const handleKeyDown = (e) => {
      // Don't intercept if user is typing in an input
      if (['INPUT', 'TEXTAREA'].includes(e.target.tagName)) return;
      
      if (e.code === 'Space') {
        e.preventDefault();
        if (podPlaying) podAudio.current?.pause();
        else podAudio.current?.play().catch(()=>{});
      } else if (e.code === 'ArrowRight') {
        e.preventDefault();
        skipPod(15);
      } else if (e.code === 'ArrowLeft') {
        e.preventDefault();
        skipPod(-15);
      }
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [podPlaying]);

  // Discard an orphaned element (its MediaElementSourceNode dies with the old
  // context and can't be reused) so a fresh one can take its place on rebuild.
  const discardAudioElement = (ref) => {
    const el = ref.current;
    if (!el) return;
    try { el.pause(); el.src = ''; el.load?.(); } catch (e) {}
    try { el.remove(); } catch (e) {}
    ref.current = null;
  };

  const ensureAmbientAudio = (force = false) => {
    if (ambientAudio.current && !force) return ambientAudio.current;
    if (force) discardAudioElement(ambientAudio);
    const audio = document.createElement('audio');
    configureHiddenAudioElement(audio);
    mixBus.addSource('ambient', audio);
    // Ambient loops are now natively seamless (makeSeamlessLoop), so native
    // <audio loop> handles the wrap with zero JS — which keeps it gapless even
    // when the screen is locked and timeupdate is throttled. No manual wrap.
    document.body.appendChild(audio);
    ambientAudio.current = audio;
    ambientSourceKey.current = '';
    syncAmbientVolume(1, muted, { preservePosition: false });
    return audio;
  };

  const ensureBinAudio = (force = false) => {
    if (binAudio.current && !force) return binAudio.current;
    if (force) discardAudioElement(binAudio);
    const audio = document.createElement('audio');
    configureHiddenAudioElement(audio);
    mixBus.addSource('bin', audio);
    audio.addEventListener('timeupdate', () => {
      if (NATIVE_MEDIA_VOLUME_LOCK) maybeWrapManualLoop(audio, binLoopMeta.current, binWrapLock);
    });
    document.body.appendChild(audio);
    binAudio.current = audio;
    binSourceKey.current = '';
    syncBinVolume(1, muted, { preservePosition: false });
    return audio;
  };

  // ── 1. Ambient Noise ──────────────────────────────────────────────────────
  const startAmbient = () => {
    mixBus.resumeContext();
    const audio = ensureAmbientAudio();
    setPlaybackAudioSession();
    syncAmbientVolume(1, muted, { preservePosition: false });
    try { audio.currentTime = 0; } catch(e){}
    audio.play().catch(()=>{});
    setAmbientOn(true);
    claimPlayback();
  };
  const stopAmbient = () => {
    if (ambientAudio.current) {
      ambientAudio.current.pause();
      ambientAudio.current.currentTime = 0;
    }
    ambientWrapLock.current = false;
    setAmbientOn(false);
  };
  const toggleAmbient = () => {
    if (ambientOn) stopAmbient();
    else {
      setMuted(false);
      startAmbient();
    }
  };

  useEffect(()=>{ if(ambientOn) startAmbient(); },[noiseType]);
  useEffect(()=>{ syncAmbientVolume(); },[ambientVol, masterVol, muted, syncAmbientVolume]);

  // ── 2. Binaural Beats ─────────────────────────────────────────────────────
  const startBin = () => {
    mixBus.resumeContext();
    const audio = ensureBinAudio();
    setPlaybackAudioSession();
    syncBinVolume(1, muted, { preservePosition: false });
    try { audio.currentTime = 0; } catch(e){}
    audio.play().catch(()=>{});
    setBinOn(true);
    claimPlayback();
  };
  const stopBin = () => {
    if (binAudio.current) {
      binAudio.current.pause();
      binAudio.current.currentTime = 0;
    }
    binWrapLock.current = false;
    setBinOn(false);
  };
  const toggleBin = () => {
    if (binOn) stopBin();
    else {
      setMuted(false);
      startBin();
    }
  };
  useEffect(()=>{ if(binOn) startBin(); },[binPreset]);
  useEffect(()=>{ syncBinVolume(); },[binVol, masterVol, muted, syncBinVolume]);

  // Keep the remote-claim handler pointing at the latest stop closures. Another
  // instance starting playback silences every layer here — stopping doesn't
  // re-broadcast, so there's no claim/stop feedback loop between instances.
  useEffect(()=>{
    stopAllForRemoteRef.current = () => {
      try { podAudio.current?.pause(); } catch(e){}
      setPodPlaying(false);
      stopAmbient();
      stopBin();
    };
  });

  // ── 3. Podcast ────────────────────────────────────────────────────────────
  const upsertFeedSub = nextSub => {
    const normalizedUrl = (nextSub?.url || '').trim();
    if (!normalizedUrl) return;
    setSubs(prev => {
      const index = prev.findIndex(entry => entry.url === normalizedUrl);
      const existing = index >= 0 ? prev[index] : null;
      const entry = {
        ...existing,
        ...nextSub,
        url: normalizedUrl,
        name: (nextSub?.name || '').trim() || existing?.name || deriveFeedName(normalizedUrl),
        updatedAt: new Date().toISOString(),
      };
      if (index >= 0) {
        const next = [...prev];
        next[index] = entry;
        return next;
      }
      return [entry, ...prev];
    });
  };

  const addEpisodesToPlaylist = nextEpisodes => {
    const additions = Array.isArray(nextEpisodes) ? nextEpisodes.filter(Boolean) : [];
    if (!additions.length) return;
    setPlaylist(prev => {
      const existingIds = new Set(prev.map(ep => ep.id));
      const uniqueAdditions = additions.filter(ep => ep?.id && !existingIds.has(ep.id));
      return uniqueAdditions.length ? [...prev, ...uniqueAdditions] : prev;
    });
  };

  const getDefaultPlaylistName = () => {
    const fromLibrary = subs.find(entry => entry.url === rssUrl.trim())?.name || '';
    const fromFeed = subName.trim() || inferPodcastTitle(playlist[0]?.title) || inferPodcastTitle(episodes[0]?.title);
    const base = fromLibrary || fromFeed;
    if (base) return `${base} Playlist`;
    return `Playlist ${new Date().toLocaleDateString(undefined, { month:'short', day:'numeric' })}`;
  };

  
  
  const downloadEpisode = async (epUrl) => {
    if (!epUrl) return;
    try {
      setDownloadProgress(prev => ({...prev, [epUrl]: 1})); // 1 means starting
      const cache = await caches.open('sleepulator-episodes');
      
      // Fetch manually to simulate progress if possible, but standard fetch is easier
      const response = await fetch(epUrl);
      if (!response.ok) throw new Error('Failed to fetch');
      
      // Store in cache
      await cache.put(epUrl, response.clone());

      prefetchedRef.current.delete(epUrl); // user download -> permanent, exempt from eviction
      setCachedEpisodes(prev => ({...prev, [epUrl]: true}));
      setDownloadProgress(prev => {
        const next = {...prev};
        delete next[epUrl];
        return next;
      });
    } catch(err) {
      console.error('Download failed:', err);
      setDownloadProgress(prev => {
        const next = {...prev};
        delete next[epUrl];
        return next;
      });
    }
  };

  // Silently warm the cache for an episode (the autoplay "next up") so it starts
  // instantly with no buffering. Mirrors downloadEpisode but shows no UI and
  // skips when already cached, in flight, or on a metered (Data Saver) connection.
  // Evict auto-prefetched episodes we no longer need so the cache can't grow
  // unbounded (episodes are 50–100 MB). Only touches URLs we prefetched —
  // never user-initiated downloads — and always keeps `keep` (the playing one).
  const evictStalePrefetch = useCallback(async (keep) => {
    const stale = [...prefetchedRef.current].filter(u => !keep.includes(u));
    if (!stale.length) return;
    try {
      const cache = await caches.open('sleepulator-episodes');
      for (const u of stale) {
        await cache.delete(u);
        prefetchedRef.current.delete(u);
      }
      setCachedEpisodes(prev => {
        const next = { ...prev };
        stale.forEach(u => { delete next[u]; });
        return next;
      });
    } catch (err) { /* non-fatal */ }
  }, []);

  const prefetchEpisode = useCallback(async (epUrl, keepUrl) => {
    if (!epUrl || prefetchingRef.current.has(epUrl)) return;
    if (navigator.connection?.saveData) return;
    // Drop previously-prefetched episodes except the new next-up and the
    // currently-playing one, capping the auto-cache at ~2 files.
    evictStalePrefetch([epUrl, keepUrl].filter(Boolean));
    if (cachedEpisodes[epUrl]) return;
    prefetchingRef.current.add(epUrl);
    try {
      const cache = await caches.open('sleepulator-episodes');
      if (await cache.match(epUrl)) {
        prefetchedRef.current.add(epUrl);
        setCachedEpisodes(prev => ({ ...prev, [epUrl]: true }));
        return;
      }
      const response = await fetch(epUrl);
      if (!response.ok) return; // opaque/cross-origin can't be replayed from cache
      await cache.put(epUrl, response.clone());
      prefetchedRef.current.add(epUrl);
      setCachedEpisodes(prev => ({ ...prev, [epUrl]: true }));
    } catch (err) {
      // Network/CORS failures are non-fatal — playback just streams normally.
    } finally {
      prefetchingRef.current.delete(epUrl);
    }
  }, [cachedEpisodes, evictStalePrefetch]);

  const deleteEpisode = async (epUrl) => {
    if (!epUrl) return;
    const cache = await caches.open('sleepulator-episodes');
    await cache.delete(epUrl);
    prefetchedRef.current.delete(epUrl);
    setCachedEpisodes(prev => {
      const next = {...prev};
      delete next[epUrl];
      return next;
    });
  };

  const saveCurrentMix = (name) => {
    if (!name.trim()) return;
    const newMix = {
      id: 'mix-' + Date.now(),
      name: name.trim(),
      masterVol, podVol, ambientVol, binVol,
      noiseType, binPreset, breathMode,
      ambientOn, binOn
    };
    setMixPresets(prev => [newMix, ...prev]);
  };

  const loadMix = (mix) => {
    setMasterVol(mix.masterVol ?? 1);
    setPodVol(mix.podVol ?? 0.8);
    setAmbientVol(mix.ambientVol ?? 0.5);
    setBinVol(mix.binVol ?? 0.5);
    setNoiseType(mix.noiseType ?? 'brown');
    setBinPreset(mix.binPreset ?? 'delta');
    setBreathMode(mix.breathMode ?? null);
    
    // We must call startAmbient / stopAmbient because just setting state won't trigger playback immediately.
    // Actually, AppContext has useEffects that trigger start/stop when ambientOn changes!
    // But setting them to true triggers the effect. 
    setAmbientOn(mix.ambientOn ?? false);
    setBinOn(mix.binOn ?? false);
    setEqOn(mix.eqOn ?? false);
    setCompOn(mix.compOn ?? false);
    setPanOn(mix.panOn ?? false);
    
    // Ensure muted is false
    setMuted(false);
  };

  const deleteMix = (id) => {
    setMixPresets(prev => prev.filter(m => m.id !== id));
  };

  const saveCurrentPlaylist = () => {
    if (!playlist.length) return;
    const name = (playlistName.trim() || getDefaultPlaylistName()).trim();
    if (!name) return;
    setSavedPlaylists(prev => {
      const existingIndex = prev.findIndex(entry => entry.name.toLowerCase() === name.toLowerCase());
      const nextEntry = {
        id: existingIndex >= 0 ? prev[existingIndex].id : `playlist-${Date.now()}`,
        name,
        episodes: playlist,
        count: playlist.length,
        updatedAt: new Date().toISOString(),
      };
      if (existingIndex >= 0) {
        const next = [...prev];
        next[existingIndex] = nextEntry;
        return next;
      }
      return [nextEntry, ...prev];
    });
    setPlaylistName(name);
  };

  const loadSavedPlaylist = (savedPlaylist, opts = {}) => {
    const savedEpisodes = Array.isArray(savedPlaylist?.episodes) ? savedPlaylist.episodes.filter(Boolean) : [];
    if (!savedEpisodes.length) return;
    setPlaylist(savedEpisodes);
    setPlaylistName(savedPlaylist?.name || '');
    setActiveTab('playlist');
    setShowPlaylistLibrary(false);
    if (opts.autoplay) playEp(savedEpisodes[0], 'playlist');
  };

  const loadFeed = async (urlOverride, options = {}) => {
    const requestedUrl = (urlOverride||rssUrl).trim();
    const configuredProxyUrl = normalizeConfigUrl(feedProxyUrl || getDefaultFeedProxyUrl());
    if(!requestedUrl) {
      setFeedErr('Please enter a valid RSS URL.');
      setFeedNote('');
      setFeedDebug({
        requestedUrl: '',
        normalizedUrl: '',
        proxyUrl: configuredProxyUrl,
        attempts: [],
        final: {
          status: 'error',
          code: 'empty-url',
          message: 'No feed URL provided.',
        },
      });
      return;
    }
    setLoading(true); setFeedErr(''); setFeedNote('');
    const normalized = normalizeFeedUrl(requestedUrl);
    let currentUrl = normalized.fetchUrl;
    let resolvedFeedUrl = requestedUrl;
    let lastError = null;
    const debugState = {
      requestedUrl,
      normalizedUrl: normalized.fetchUrl,
      proxyUrl: configuredProxyUrl,
      startedAt: new Date().toISOString(),
      attempts: [],
      final: null,
    };
    setFeedDebug(debugState);

    try {
      for (let hop = 0; hop < 3; hop++) {
        const sources = buildFeedSources(currentUrl, {
          authHeader: hop === 0 ? normalized.authHeader : '',
          proxyUrl: configuredProxyUrl,
        });

        let raw = '';
        let sourceLabel = '';
        for (const source of sources) {
          const attempt = {
            hop: hop + 1,
            via: source.label,
            targetUrl: currentUrl,
            requestUrl: source.url,
            method: source.init?.method || 'GET',
          };
          debugState.attempts.push(attempt);
          try {
            const response = await fetchWithTimeout(source.url, source.init);
            attempt.status = response.status;
            attempt.ok = response.ok;
            attempt.responseUrl = response.url || source.url;
            attempt.contentType = response.headers.get('content-type') || '';

            const responseText = await response.text();
            if (!response.ok) {
              attempt.error = `HTTP ${response.status}`;
              attempt.preview = previewText(responseText);
              continue;
            }

            raw = source.read(responseText);
            attempt.bodyLength = raw?.length || 0;
            attempt.markupType = sniffMarkupType(raw);
            if (attempt.markupType === 'html') {
              const embeddedFeed = extractEmbeddedFeedMarkup(raw);
              if (embeddedFeed) {
                attempt.embeddedFeed = true;
                attempt.embeddedMarkupType = sniffMarkupType(embeddedFeed);
              } else {
                attempt.preview = previewText(raw);
              }
            }
            if (raw) {
              attempt.used = true;
              sourceLabel = source.label;
              break;
            }
            attempt.error = 'Empty response body.';
          } catch (error) {
            const attemptError = error?.name === 'AbortError' ? makeFeedError('timeout') : error;
            lastError = attemptError;
            attempt.errorCode = attemptError?.code || '';
            attempt.error = describeError(attemptError);
          }
        }

        if (!raw) {
          throw lastError || makeFeedError(normalized.authHeader ? 'auth-cors' : 'network', { hasProxy: !!configuredProxyUrl });
        }

        try {
          const parsedFeed = parseFeedEpisodes(raw, currentUrl);
          const nextEpisodes = parsedFeed.episodes;
          const existingSub = subs.find(entry => entry.url === currentUrl);
          const nextFeedName = existingSub?.name || parsedFeed.feedTitle || deriveFeedName(currentUrl);
          setEpisodes(nextEpisodes);
          setActiveTab('feed');
          setRssUrl(currentUrl);
          setSubName(nextFeedName);
          upsertFeedSub({
            url: currentUrl,
            name: nextFeedName,
            episodeCount: nextEpisodes.length,
            latestEpisodeTitle: nextEpisodes[0]?.title || '',
          });
          if (options.closeLibrary) setShowSubs(false);
          if (options.autoplay && nextEpisodes[0]) playEp(nextEpisodes[0], 'feed');
          setFeedDebug({
            ...debugState,
            attempts: [...debugState.attempts],
            final: {
              status: 'success',
              via: sourceLabel,
              feedUrl: currentUrl,
              episodeCount: nextEpisodes.length,
            },
          });
          return;
        } catch (error) {
          lastError = error;
          if (error.code === 'alternate-feed' && error.alternateUrl) {
            debugState.attempts.push({
              hop: hop + 1,
              via: 'Alternate Feed',
              targetUrl: currentUrl,
              requestUrl: error.alternateUrl,
              message: `Retrying discovered feed URL ${redactUrlForDisplay(error.alternateUrl)}`,
            });
            currentUrl = error.alternateUrl;
            resolvedFeedUrl = error.alternateUrl;
            continue;
          }
          throw error;
        }
      }
      throw lastError || makeFeedError('network', { hasProxy: !!configuredProxyUrl });
    } catch (error) {
      if (error?.code === 'alternate-feed' && error.alternateUrl) {
        setRssUrl(error.alternateUrl);
      }
      const message = formatFeedError(error, resolvedFeedUrl);
      setShowFeedDebug(true);
      setFeedDebug({
        ...debugState,
        attempts: [...debugState.attempts],
        final: {
          status: 'error',
          code: error?.code || '',
          message,
          details: describeError(error),
          feedUrl: resolvedFeedUrl,
        },
      });
      setFeedErr(message);
      setFeedNote('');
    } finally {
      setLoading(false);
    }
  };

  const addToPlaylist = ep => addEpisodesToPlaylist([ep]);
  const removeFromPlaylist=id => setPlaylist(prev=>prev.filter(ep=>ep.id!==id));
  const saveSub = () => {
    const url = rssUrl.trim();
    if(!url) return;
    const existing = subs.find(entry => entry.url === url);
    const name = subName.trim() || existing?.name || deriveFeedName(url);
    upsertFeedSub({
      ...existing,
      url,
      name,
    });
    setSubName(name);
  };

  const ensurePodAudio = (force = false) => {
    if (podAudio.current && !force) return podAudio.current;
    if (force) discardAudioElement(podAudio);
    const audio = document.createElement('audio');
    configureHiddenAudioElement(audio);
    mixBus.addSource('pod', audio);
    audio.loop = false;
    audio.preload = 'metadata';
    // Disable pitch-preserving time-stretch at slow speeds: it's CPU-heavy and
    // choppy on mobile through a MediaElementSource. Resampling instead drops the
    // pitch naturally (a deeper, lethargic voice — fitting for a sleep app).
    audio.preservesPitch = false;
    audio.mozPreservesPitch = false;
    audio.webkitPreservesPitch = false;
    audio.addEventListener('play', () => {
      setPodPlaying(true);
      claimPlayback(); // tell other instances to stand down (covers every play path)
      if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'playing';
      syncMediaPositionState();
    });
    audio.addEventListener('pause', () => {
      setPodPlaying(false);
      if ('mediaSession' in navigator) navigator.mediaSession.playbackState = audio.ended ? 'none' : 'paused';
    });
    audio.addEventListener('ended', () => {
      iosAdvanceLock.current = false;
      setPodPlaying(false);
      if ('mediaSession' in navigator) navigator.mediaSession.playbackState = 'none';
      if (playNextRef.current) playNextRef.current();
    });
    audio.addEventListener('error', () => {
      setFeedErr('Could not play this episode. The source may be unavailable or block streaming.');
      setPodPlaying(false);
    });
    audio.addEventListener('loadedmetadata', syncMediaPositionState);
    audio.addEventListener('ratechange', syncMediaPositionState);
    audio.addEventListener('timeupdate', () => {
      syncMediaPositionState();
      setPodProgress({cur: audio.currentTime||0, dur: audio.duration||0});
      if (!iosPwaAudio.current || document.visibilityState === 'visible') return;
      const state = podStateRef.current;
      if (!state.autoPlay || !state.curEp) return;
      if (!Number.isFinite(audio.duration) || audio.duration <= 0) return;
      const remaining = audio.duration - audio.currentTime;
      if (remaining > 1.5) iosAdvanceLock.current = false;
      if (remaining > 0 && remaining < 0.35 && !iosAdvanceLock.current) {
        iosAdvanceLock.current = true;
        playNextRef.current?.({ iosHandoff: true });
      }
    });
    document.body.appendChild(audio);
    podAudio.current = audio;
    syncPodVolume();
    // On a forced recreate (context rebuild) the fresh element has no src and
    // is at 0:00 — restore the last episode and resume position once metadata
    // loads (seeking before that races to 0).
    if (force && lastPodUrl.current) {
      const resumeAt = liveRef.current.podPosition || 0;
      audio.src = lastPodUrl.current;
      audio.addEventListener('loadedmetadata', () => {
        try { if (resumeAt > 0) audio.currentTime = resumeAt; } catch (e) {}
      }, { once: true });
      audio.load();
    }
    return audio;
  };

  useEffect(()=>{ syncPodVolume(); },[syncPodVolume]);

  // Keep a snapshot of live state for the rebuild callback, which is registered
  // once but must read current values (not stale first-render closures).
  useEffect(() => {
    liveRef.current = {
      ambientOn, binOn, podPlaying,
      eqOn, compOn, panOn,
      podPosition: podProgress.cur || 0,
    };
  });

  // When MixBus rebuilds a dead (iOS-closed) AudioContext, recreate the
  // <audio> elements for whichever layers were active and re-apply pod effects.
  // Re-registered every render so it closes over the latest builders/state.
  // Resume is intentionally left to the next user gesture (iOS requires one).
  useEffect(() => {
    mixBus.onRebuild(async () => {
      const live = liveRef.current;
      if (live.ambientOn) ensureAmbientAudio(true);
      if (live.binOn) ensureBinAudio(true);
      if (live.podPlaying || lastPodUrl.current) ensurePodAudio(true);
      mixBus.setEffects('pod', {
        eqOn: live.eqOn, compOn: live.compOn, panOn: live.panOn,
      });
    });
  });

  const playEp = async (ep, source='feed', opts={}) => {
    mixBus.resumeContext();
    const audio = ensurePodAudio();
    const iosHandoff = !!opts.iosHandoff;
    const useSleepSafeAudio = sleepSafeAudio && sleepSafeConfigured;
    
    let playbackUrl = ep.url;
    if (cachedEpisodes[ep.url]) {
      try {
        const cache = await caches.open('sleepulator-episodes');
        const res = await cache.match(ep.url);
        
        if (res) {
          const blob = await res.blob();
          if (activeBlobUrlRef.current) URL.revokeObjectURL(activeBlobUrlRef.current);
          playbackUrl = URL.createObjectURL(blob);
          activeBlobUrlRef.current = playbackUrl;
          console.log("Playing from local Cache Blob URL");
        }

      } catch(e) {
        console.error("Cache playback failed", e);
        playbackUrl = useSleepSafeAudio ? buildSleepSafeAudioUrl(ep.url, normalizedAudioProxyUrl) : ep.url;
      }
    } else {
      playbackUrl = useSleepSafeAudio ? buildSleepSafeAudioUrl(ep.url, normalizedAudioProxyUrl) : ep.url;
    }

    const activeAudioUrl = audio.currentSrc || audio.src || '';
    const sourceChangedForEpisode = curEp?.id === ep.id && activeAudioUrl !== playbackUrl;
    setFeedErr('');
    setFeedNote(sleepSafeAudio && !sleepSafeConfigured
      ? 'Sleep Safe is enabled, but no proxy URL is configured yet. Playing this episode directly.'
      : '');
    setPlayingSrc(source);
    if(curEp?.id===ep.id && !sourceChangedForEpisode){
      if(podPlaying){ audio.pause(); }
      else{
        setPlaybackAudioSession();
        setMuted(false);
        setNativeAudioLevel(audio, podVol * masterVol, false);
        audio.play().catch(()=>{ setFeedErr('Could not resume this episode.'); });
      }
    } else {
      const prog=JSON.parse(localStorage.getItem('podcastProgress')||'{}');
      const resumeAt = sourceChangedForEpisode && Number.isFinite(audio.currentTime) && audio.currentTime > 0
        ? audio.currentTime
        : (prog[ep.id] ? Math.max(0, prog[ep.id]-90) : 0);
      if (!iosHandoff) audio.pause();
      audio.src=playbackUrl;
      lastPodUrl.current = playbackUrl;
      audio.playbackRate=podSpeed;
      audio.load();
      if (resumeAt > 0) {
        const onMeta = () => {
          try {
            const maxTime = Number.isFinite(audio.duration) && audio.duration > 1 ? audio.duration - 1 : resumeAt;
            audio.currentTime = Math.max(0, Math.min(resumeAt, maxTime));
          } catch(e){}
        };
        audio.addEventListener('loadedmetadata', onMeta, { once: true });
      }
      setCurEp(ep);
      setPodProgress({cur:0,dur:0});
      setPlaybackAudioSession();
      setMuted(false);
      setNativeAudioLevel(audio, podVol * masterVol, false);
      audio.play().catch(()=>{
        setFeedErr('Could not play this episode. The source may be unavailable or block streaming.');
        setPodPlaying(false);
      });
    }
  };

  useEffect(()=>{ if(podAudio.current) podAudio.current.playbackRate=podSpeed; },[podSpeed,curEp]);

  useEffect(()=>{
    playNextRef.current = (opts={})=>{
      const list=playingSrc==='playlist'?playlist:episodes;
      if(!autoPlay||!list.length){ setPodPlaying(false); return false; }
      const nextIdx=shuffle?Math.floor(Math.random()*list.length):(list.findIndex(e=>e.id===curEp?.id)+1)%list.length;
      const nextEp = list[nextIdx];
      if (!nextEp) { setPodPlaying(false); return false; }
      playEp(nextEp, playingSrc, opts);
      return true;
    };
  },[autoPlay,shuffle,episodes,playlist,curEp,playingSrc]);

  // Preload the autoplay "next up" episode while the current one plays, so it
  // starts instantly. Deterministic next only (skip shuffle — unpredictable).
  useEffect(()=>{
    if(!preloadNext||!autoPlay||shuffle||!curEp) return;
    const list = playingSrc==='playlist' ? playlist : episodes;
    const next = nextEpisode(list, curEp.id);
    if(next?.url && next.id!==curEp.id) prefetchEpisode(next.url, curEp.url);
  },[preloadNext,autoPlay,shuffle,curEp,playingSrc,episodes,playlist,prefetchEpisode]);

  // Progress save
  useEffect(()=>{
    if(podPlaying&&curEp){
      progInterval.current=setInterval(()=>{
        if(!podAudio.current) return;
        try{ const p=JSON.parse(localStorage.getItem('podcastProgress')||'{}'); p[curEp.id]=podAudio.current.currentTime; localStorage.setItem('podcastProgress',JSON.stringify(p)); }catch(e){}
      },5000);
    } else clearInterval(progInterval.current);
    return ()=>clearInterval(progInterval.current);
  },[podPlaying,curEp]);

  const skipPod = s => { if(podAudio.current) podAudio.current.currentTime+=s; };
  // ── 4. Sleep Timer (setInterval — works in background, unlike rAF) ────────
  const tickTimer = useCallback(()=>{
    const rem = Math.max(0, Math.round((timerEndRef.current-Date.now())/1000));
    setTimeLeft(rem);
    // Hand the ambient level entirely to the fade taper once it starts — pause
    // ducking so the two don't both ride the ambient gain at once (idempotent).
    mixBus.setDuckSuspended(rem<=600 && rem>0);
    if(rem<=600&&rem>0){
      // Perceptually-even fade: amplitude decays exponentially so loudness drops
      // by a roughly constant number of dB each second (hearing is logarithmic),
      // down to ~-48 dB over the final 10 minutes. Smoother than a linear or
      // quadratic amplitude taper, which lingers audibly then drops abruptly.
      const r=Math.pow(0.004, 1 - rem/600);
      if(podAudio.current) syncPodVolume(r, muted);
      if(!ambientBypass&&ambientAudio.current) syncAmbientVolume(r, muted, { allowSourceRebuild: false });
      if(!binBypass&&binAudio.current) syncBinVolume(r, muted, { allowSourceRebuild: false });
    }
    if(rem<=0){
      clearInterval(timerTickRef.current);
      setTimerActive(false); setTimeLeft(null);
      mixBus.setDuckSuspended(false);
      podAudio.current?.pause(); setPodPlaying(false);
      if(!ambientBypass) stopAmbient();
      if(!binBypass&&binOn) stopBin();
    }
  },[ambientBypass,binBypass,binOn,muted,syncAmbientVolume,syncBinVolume,syncPodVolume]);

  // Rebuild ticker when deps change
  useEffect(()=>{
    if(timerActive){ clearInterval(timerTickRef.current); timerTickRef.current=setInterval(tickTimer,1000); }
  },[timerActive,tickTimer]);

  const toggleTimer = ()=>{
    if(timerActive){
      clearInterval(timerTickRef.current); setTimerActive(false); setTimeLeft(null);
      mixBus.setDuckSuspended(false);
      syncPodVolume();
      syncAmbientVolume();
      syncBinVolume();
    } else {
      timerEndRef.current=Date.now()+timerMins*60000;
      setTimerActive(true);
      timerTickRef.current=setInterval(tickTimer,1000);
    }
  };

  const bumpTimer = ()=>{
    timerEndRef.current+=15*60000;
    syncPodVolume();
    if(!ambientBypass) syncAmbientVolume();
    if(!binBypass) syncBinVolume();
  };

  const fmt = s=>s===null?'':String(Math.floor(s/60))+':'+String(s%60).padStart(2,'0');

  useEffect(()=>()=>{
    clearInterval(timerTickRef.current); clearInterval(progInterval.current);
    ambientAudio.current?.pause();
    binAudio.current?.pause();
    if (podAudio.current) {
      podAudio.current.pause();
      podAudio.current.remove();
      podAudio.current = null;
    }
    if (ambientAudio.current) {
      ambientAudio.current.remove();
      ambientAudio.current = null;
    }
    if (binAudio.current) {
      binAudio.current.remove();
      binAudio.current = null;
    }
    if (ambientManagedUrl.current) {
      URL.revokeObjectURL(ambientManagedUrl.current);
      ambientManagedUrl.current = '';
    }
    if (binManagedUrl.current) {
      URL.revokeObjectURL(binManagedUrl.current);
      binManagedUrl.current = '';
    }
    ambientSourceKey.current = '';
    binSourceKey.current = '';
    ambientLoopMeta.current = null;
    binLoopMeta.current = null;
    ambientWrapLock.current = false;
    binWrapLock.current = false;
  },[]);

  // ── Breathing config ──────────────────────────────────────────────────────
  const BC = {
    '478':{label:'4-7-8 Relaxation',sub:'Inhale 4s · Hold 7s · Exhale 8s',cls:'anim-478',col:'#6366f1'},
    'box': {label:'Box Breathing',  sub:'In 4s · Hold 4s · Out 4s · Hold 4s',cls:'anim-box',col:'#14b8a6'},
  };
  const bc = breathMode ? BC[breathMode] : null;

  // ── Render helpers ────────────────────────────────────────────────────────
  const c_text  = 'var(--c-text)';
  const c_sub   = 'var(--c-sub)';
  const c_dim   = 'var(--c-dim)';
  const c_head  = 'var(--c-text)';
  const c_card  = 'var(--c-surface)';
  const c_bord  = 'var(--c-border)';
  const c_inner = 'rgba(0,0,0,0.2)';

  // ── Render ────────────────────────────────────────────────────────────────

  const value = {
    bm,
    setBm,
    muted,
    setMuted,
    breathMode,
    setBreathMode,
    masterVol,
    setMasterVol,
    ambientOn,
    setAmbientOn,
    ambientVol,
    setAmbientVol,
    noiseType,
    setNoiseType,
    ambientBypass,
    setAmbientBypass,
    binOn,
    setBinOn,
    binVol,
    setBinVol,
    binPreset,
    setBinPreset,
    binBypass,
    setBinBypass,
    timerMins,
    setTimerMins,
    timerActive,
    setTimerActive,
    timeLeft,
    setTimeLeft,
    episodes,
    setEpisodes,
    playlist,
    setPlaylist,
    playingSrc,
    setPlayingSrc,
    curEp,
    setCurEp,
    podPlaying,
    setPodPlaying,
    podVol,
    setPodVol,
    podSpeed,
    setPodSpeed,
    autoPlay,
    setAutoPlay,
    shuffle,
    setShuffle,
    preloadNext,
    setPreloadNext,
    rssUrl,
    setRssUrl,
    loading,
    setLoading,
    feedErr,
    setFeedErr,
    feedNote,
    setFeedNote,
    feedProxyUrl,
    setFeedProxyUrl,
    audioProxyUrl,
    setAudioProxyUrl,
    sleepSafeAudio,
    setSleepSafeAudio,
    feedDebug,
    setFeedDebug,
    showFeedDebug,
    setShowFeedDebug,
    duckOn,
    setDuckOn,
    forceAudioTeardown: () => mixBus.forceTeardown(),
    getAudioDiagnostics: () => mixBus.getDiagnostics(),
    subs,
    setSubs,
    showSubs,
    setShowSubs,
    subName,
    setSubName,
    savedPlaylists,
    setSavedPlaylists,
    mixPresets,
    setMixPresets,
    saveCurrentMix,
    loadMix,
    deleteMix,
    cachedEpisodes,
    downloadProgress,
    online,
    downloadEpisode,
    deleteEpisode,
    showPlaylistLibrary,
    setShowPlaylistLibrary,
    playlistName,
    setPlaylistName,
    podProgress,
    setPodProgress,
    timerEndRef,
    timerTickRef,
    dragSrcRef,
    normalizedAudioProxyUrl,
    sleepSafeConfigured,
    ambientAudio,
    binAudio,
    podAudio,
    playNextRef,
    progInterval,
    wakeLock,
    iosAdvanceLock,
    podStateRef,
    iosPwaAudio,
    ambientManagedUrl,
    binManagedUrl,
    ambientSourceKey,
    binSourceKey,
    ambientLoopMeta,
    binLoopMeta,
    ambientWrapLock,
    binWrapLock,
    setNativeAudioLevel,
    swapManagedLoopSource,
    syncPodVolume,
    syncAmbientVolume,
    syncBinVolume,
    setPlaybackAudioSession,
    syncMediaPositionState,
    resumeSoundscapeAudio,
    pauseSoundscapeAudio,
    anyPlaying,
    ensureAmbientAudio,
    ensureBinAudio,
    startAmbient,
    stopAmbient,
    toggleAmbient,
    startBin,
    stopBin,
    toggleBin,
    upsertFeedSub,
    addEpisodesToPlaylist,
    getDefaultPlaylistName,
    saveCurrentPlaylist,
    loadSavedPlaylist,
    loadFeed,
    addToPlaylist,
    removeFromPlaylist,
    saveSub,
    ensurePodAudio,
    playEp,
    skipPod,
    tickTimer,
    toggleTimer,
    bumpTimer,
    fmt,
    BC,
    bc,
    c_text,
    c_sub,
    c_dim,
    c_head,
    c_card,
    c_bord,
    c_inner,
  };

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useAppContext() {
  return useContext(AppContext);
}
