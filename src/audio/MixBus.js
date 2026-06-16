export class MixBus {
  constructor() {
    // Cross-party hooks/flags must survive a rebuild, so they live on the
    // instance rather than inside _initContext().
    this._onRebuild = null;        // AppContext registers this (see onRebuild)
    this._rebuilding = false;      // guards against rebuild storms
    this._lastMasterVolume = 1;    // re-applied to a freshly built context

    // Ducking ("sidechain") config lives on the instance so it survives a
    // rebuild; the graph nodes (duckBus / analyser) are rebuilt in _initContext.
    this.duckEnabled = false;
    this.duckDepth = 0.45;     // ambient floor multiplier while voice present (~-7dB)
    this.duckThreshold = 0.04; // RMS gate above which the podcast counts as "talking"
    this.duckAttack = 0.12;    // s — time constant pulling ambient down (fast)
    this.duckRelease = 0.55;   // s — time constant letting it swell back (gentle)
    this._duckSuspended = false; // transient override (e.g. during the sleep-timer fade)
    this._duckRAF = null;

    this._initContext();
  }

  // Stand up a fresh AudioContext, master gain, shared pan LFO, and an empty
  // source map. Called once from the constructor and again from rebuild() after
  // iOS has torn the previous context down to 'closed'.
  _initContext() {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) {
      this.supported = false;
      return;
    }
    this.supported = true;
    this.context = new AudioContextClass();

    // Master gain controls overall volume
    this.masterGain = this.context.createGain();
    this.masterGain.connect(this.context.destination);

    // Ducking sub-bus: ambient + binaural pass through here so the podcast voice
    // can pull them down and let them swell back in the gaps. Pod routes straight
    // to master (it's the trigger, not a duck target).
    this.duckBus = this.context.createGain();
    this.duckBus.gain.value = 1;
    this.duckBus.connect(this.masterGain);
    this._duckCurrent = 1;     // last applied duck multiplier (1 = fully open)
    this._duckAnalyser = null; // tap on the pod trigger signal (set in addSource)
    this._duckData = null;     // reusable time-domain analysis buffer

    this._startPanLFO();

    // Map of id -> { element, sourceNode, gainNode, eqNode, compNode,
    //               pannerNode, isConnected, volume, eqOn, compOn, panOn }
    this.sources = new Map();

    this.context.onstatechange = () => this._handleStateChange();
  }

  // A single shared LFO drives the pan param of every source's panner.
  // One oscillator can modulate many AudioParams, so this stays shared
  // even though the panner nodes themselves are per-source.
  _startPanLFO() {
    if (this.context.createStereoPanner) {
      this.panLFO = this.context.createOscillator();
      this.panLFO.type = 'sine';
      this.panLFO.frequency.value = 0.05; // 20s sweep
      this.panLFO.start();
    } else {
      this.panLFO = null;
    }
  }

  // 'running'  -> the context survived a suspend/interrupt; re-route in place.
  // 'closed'   -> iOS tore the context down; the node graph is dead and the
  //               existing MediaElementSourceNodes can't be reused, so rebuild.
  _handleStateChange() {
    if (!this.context) return;
    const state = this.context.state;
    console.log(`MixBus: AudioContext state changed to ${state}`);
    if (state === 'running') {
      this.reconnectAllSources();
    } else if (state === 'closed') {
      this.rebuild();
    }
  }

  // True when there is no usable context to play through.
  isDead() {
    return !this.supported || !this.context || this.context.state === 'closed';
  }

  async resumeContext() {
    if (!this.supported) return;
    if (this.isDead()) {
      await this.rebuild();
      return;
    }
    if (this.context.state === 'suspended' || this.context.state === 'interrupted') {
      try {
        await this.context.resume();
        console.log("MixBus: AudioContext resumed successfully.");
      } catch (err) {
        // Some iOS builds reach 'closed' without firing onstatechange; a
        // resume() against a closed context rejects with InvalidStateError.
        if (err?.name === 'InvalidStateError') {
          await this.rebuild();
        } else {
          console.warn("MixBus: Failed to resume AudioContext", err);
        }
      }
    }
  }

  // Register a callback invoked after rebuild() stands up a new context. It
  // receives the captured per-layer settings and is responsible for recreating
  // the <audio> elements and re-adding them via addSource (AppContext owns the
  // elements, MixBus owns the context/nodes). May be async.
  onRebuild(cb) {
    this._onRebuild = cb;
  }

  // Discard a dead context and build a new one from scratch. The existing
  // source nodes can't migrate, so we snapshot each layer's logical settings,
  // tear down, re-init, and hand off to AppContext to recreate the elements.
  async rebuild() {
    if (!this.supported || this._rebuilding) return;
    this._rebuilding = true;
    try {
      // 1. Snapshot logical layer settings before discarding the dead nodes.
      const layers = [...this.sources.entries()].map(([id, s]) => ({
        id, volume: s.volume, eqOn: s.eqOn, compOn: s.compOn, panOn: s.panOn,
      }));

      // 2. Tear down the old context (it may already be 'closed' — ignore).
      this._stopDuckLoop();
      try { this.panLFO?.stop(); } catch (e) {}
      if (this.context && this.context.state !== 'closed') {
        try { await this.context.close(); } catch (e) {}
      }

      // 3. Stand up a fresh context + master + LFO; this clears this.sources.
      this._initContext();
      if (!this.supported) return;
      this.setMasterVolume(this._lastMasterVolume);

      // 4. Ask AppContext to recreate elements and re-addSource each layer.
      if (this._onRebuild) {
        try { await this._onRebuild(layers); }
        catch (e) { console.warn('MixBus: onRebuild callback failed', e); }
      }

      // 5. Resume ducking if it was on (addSource('pod') also restarts it once
      //    the trigger comes back, but cover the case where pod re-adds first).
      if (this.duckEnabled) this._startDuckLoop();
    } finally {
      this._rebuilding = false;
    }
  }

  setMasterVolume(value) {
    if (!this.supported) return;
    const clamped = Math.max(0, Math.min(1, value));
    this._lastMasterVolume = clamped;
    this.masterGain.gain.setTargetAtTime(clamped, this.context.currentTime, 0.05);
  }

  // DEV/TEST ONLY: simulate the iOS "context torn down to closed" interruption
  // so the rebuild path can be exercised on demand (see TESTING.md §3B). Closing
  // the context should fire onstatechange -> rebuild; we also trigger explicitly
  // in case a browser doesn't, guarded against a double run by _rebuilding / the
  // post-rebuild context already being 'running'.
  async forceTeardown() {
    if (!this.supported || !this.context) return;
    try { await this.context.close(); } catch (e) {}
    if (this.context.state === 'closed' && !this._rebuilding) {
      await this.rebuild();
    }
  }

  // Snapshot of engine health for a dev diagnostics readout.
  getDiagnostics() {
    return {
      supported: this.supported,
      state: this.context?.state ?? 'none',
      dead: this.isDead(),
      sources: this.sources ? [...this.sources.keys()] : [],
      rebuilding: this._rebuilding,
      ducking: { enabled: this.duckEnabled, gain: this._duckCurrent },
    };
  }

  // Build a dedicated effect chain for one source so that re-routing or
  // toggling effects on one source never disturbs another source's nodes.
  _createEffectNodes() {
    const eqNode = this.context.createBiquadFilter();
    eqNode.type = 'lowshelf';
    eqNode.frequency.value = 200;
    eqNode.gain.value = -12; // Cut booming bass

    const compNode = this.context.createDynamicsCompressor();
    compNode.threshold.value = -35;
    compNode.knee.value = 30;
    compNode.ratio.value = 12;
    compNode.attack.value = 0.005;
    compNode.release.value = 0.25;

    let pannerNode = null;
    if (this.context.createStereoPanner) {
      pannerNode = this.context.createStereoPanner();
      if (this.panLFO) this.panLFO.connect(pannerNode.pan);
    }

    return { eqNode, compNode, pannerNode };
  }

  addSource(id, audioElement) {
    if (!this.supported) return false;

    if (this.sources.has(id)) {
      return true; // Already added
    }

    const gainNode = this.context.createGain();
    // Ambient + binaural route through the duck sub-bus; the podcast (the duck
    // trigger) and anything else go straight to master.
    const duckable = id === 'ambient' || id === 'bin';
    gainNode.connect(duckable ? this.duckBus : this.masterGain);

    let sourceNode = null;
    let isConnected = false;

    try {
      sourceNode = this.context.createMediaElementSource(audioElement);
      isConnected = true;
    } catch (e) {
      // This can happen if the audio element is not CORS-enabled or already connected to another context
      console.warn(`MixBus: Could not create MediaElementSource for ${id}. Falling back to direct playback.`, e);
      isConnected = false;
    }

    const { eqNode, compNode, pannerNode } = this._createEffectNodes();

    this.sources.set(id, {
      element: audioElement,
      gainNode,
      sourceNode,
      eqNode,
      compNode,
      pannerNode,
      isConnected,
      isDuckTrigger: false,
      volume: 1.0,
      eqOn: false,
      compOn: false,
      panOn: false
    });

    const src = this.sources.get(id);
    // The podcast is the duck trigger: give it an analyser tap so the duck loop
    // can read its loudness. _routeSource (re)establishes the actual tap so it
    // survives iOS re-routes, which disconnect the source node.
    if (id === 'pod' && isConnected) this._attachDuckTrigger(src);
    if (isConnected) this._routeSource(src);
    if (id === 'pod' && isConnected && this.duckEnabled) this._startDuckLoop();

    return isConnected;
  }

  setSourceVolume(id, value) {
    if (!this.sources) return; // no context (e.g. unsupported env)
    const src = this.sources.get(id);
    if (!src) return;

    const clamped = Math.max(0, Math.min(1, value));
    src.volume = clamped;

    if (this.supported && src.isConnected) {
      src.gainNode.gain.setTargetAtTime(clamped, this.context.currentTime, 0.05);
    } else {
      // Fallback: apply volume directly if MixBus failed or isn't supported
      src.element.volume = clamped;
    }
  }

  setEffects(id, { eqOn, compOn, panOn }) {
    if (!this.supported || !this.sources) return; // no context (e.g. unsupported env)
    const src = this.sources.get(id);
    if (!src || !src.isConnected || !src.sourceNode) return;

    src.eqOn = !!eqOn;
    src.compOn = !!compOn;
    src.panOn = !!panOn;

    this._routeSource(src);
  }

  // Re-wire a single source's chain. Only this source's own nodes are
  // disconnected/reconnected, so sibling sources are never disturbed.
  _routeSource(src) {
    if (!src.isConnected || !src.sourceNode) return;

    // Disconnect only this source's nodes.
    src.sourceNode.disconnect();
    if (src.eqNode) src.eqNode.disconnect();
    if (src.compNode) src.compNode.disconnect();
    if (src.pannerNode) src.pannerNode.disconnect();

    let currentNode = src.sourceNode;

    if (src.eqOn && src.eqNode) {
      currentNode.connect(src.eqNode);
      currentNode = src.eqNode;
    }

    if (src.compOn && src.compNode) {
      currentNode.connect(src.compNode);
      currentNode = src.compNode;
    }

    if (src.panOn && src.pannerNode) {
      currentNode.connect(src.pannerNode);
      currentNode = src.pannerNode;
    }

    currentNode.connect(src.gainNode);

    // Re-establish the duck analyser tap (the leading disconnect cleared it).
    // Tapping the raw source node keeps detection independent of the podcast
    // volume slider and its effect chain.
    if (src.isDuckTrigger && this._duckAnalyser) {
      try { src.sourceNode.connect(this._duckAnalyser); } catch (e) {}
    }
  }

  reconnectAllSources() {
    if (!this.supported) return;

    // Workaround for iOS bug: disconnect and reconnect nodes
    for (const [id, src] of this.sources.entries()) {
      if (src.sourceNode && src.isConnected) {
        try {
          this._routeSource(src);
          console.log(`MixBus: Reconnected source ${id}`);
        } catch (e) {
          console.warn(`MixBus: Failed to reconnect source ${id}`, e);
        }
      }
    }
  }

  // ── Ducking ("sidechain"): pull ambient/binaural down under the podcast voice ─
  // Web Audio has no true sidechain, so we tap the podcast with an AnalyserNode,
  // measure its RMS each frame, and ride the duck sub-bus gain: fast down when the
  // host is talking, slow back up in the gaps. The tap itself is (re)connected in
  // _routeSource so it survives re-routes and rebuilds.
  _attachDuckTrigger(src) {
    src.isDuckTrigger = true;
    if (!this.context.createAnalyser) return; // older WebViews — ducking just no-ops
    this._duckAnalyser = this.context.createAnalyser();
    this._duckAnalyser.fftSize = 1024;
    this._duckData = new Float32Array(this._duckAnalyser.fftSize);
  }

  _duckTick() {
    if (!this.duckEnabled || this._duckSuspended || !this._duckAnalyser || !this._duckData || this.isDead()) {
      this._duckRAF = null;
      return;
    }
    this._duckAnalyser.getFloatTimeDomainData(this._duckData);
    let sum = 0;
    for (let i = 0; i < this._duckData.length; i++) {
      const v = this._duckData[i];
      sum += v * v;
    }
    const rms = Math.sqrt(sum / (this._duckData.length || 1));
    const target = rms > this.duckThreshold ? this.duckDepth : 1;
    // Asymmetric smoothing: duck quickly when speech starts, swell back gently.
    const tc = target < this._duckCurrent ? this.duckAttack : this.duckRelease;
    this._duckCurrent = target;
    try { this.duckBus.gain.setTargetAtTime(target, this.context.currentTime, tc); } catch (e) {}
    if (typeof requestAnimationFrame === 'function') {
      this._duckRAF = requestAnimationFrame(() => this._duckTick());
    } else {
      this._duckRAF = null;
    }
  }

  _startDuckLoop() {
    if (this._duckRAF != null || this._duckSuspended || typeof requestAnimationFrame !== 'function') return;
    this._duckRAF = requestAnimationFrame(() => this._duckTick());
  }

  // Temporarily pause ducking without forgetting the user's preference — used by
  // the sleep-timer fade so the duck loop and the fade taper don't both ride the
  // ambient level at once. Suspending opens the bus back to 1; lifting it resumes.
  setDuckSuspended(suspended) {
    const next = !!suspended;
    if (next === this._duckSuspended) return;
    this._duckSuspended = next;
    if (!this.supported) return;
    if (next) {
      this._stopDuckLoop();
      this._duckCurrent = 1;
      try { this.duckBus?.gain.setTargetAtTime(1, this.context.currentTime, 0.2); } catch (e) {}
    } else if (this.duckEnabled) {
      this._startDuckLoop();
    }
  }

  _stopDuckLoop() {
    if (this._duckRAF != null && typeof cancelAnimationFrame === 'function') {
      cancelAnimationFrame(this._duckRAF);
    }
    this._duckRAF = null;
  }

  // Toggle ducking and optionally tune depth/threshold/attack/release. Safe to
  // call before the podcast source exists — addSource starts the loop once the
  // trigger is present.
  setDucking(enabled, opts = {}) {
    this.duckEnabled = !!enabled;
    if (Number.isFinite(opts.depth))     this.duckDepth = Math.max(0, Math.min(1, opts.depth));
    if (Number.isFinite(opts.threshold)) this.duckThreshold = Math.max(0, opts.threshold);
    if (Number.isFinite(opts.attack))    this.duckAttack = Math.max(0.001, opts.attack);
    if (Number.isFinite(opts.release))   this.duckRelease = Math.max(0.001, opts.release);
    if (!this.supported) return;
    if (this.duckEnabled) {
      this._startDuckLoop();
    } else {
      this._stopDuckLoop();
      this._duckCurrent = 1;
      try { this.duckBus?.gain.setTargetAtTime(1, this.context.currentTime, 0.1); } catch (e) {}
    }
  }
}

export const mixBus = new MixBus();
