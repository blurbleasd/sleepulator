export class MixBus {
  constructor() {
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

    // A single shared LFO drives the pan param of every source's panner.
    // One oscillator can modulate many AudioParams, so this stays shared
    // even though the panner nodes themselves are per-source.
    if (this.context.createStereoPanner) {
      this.panLFO = this.context.createOscillator();
      this.panLFO.type = 'sine';
      this.panLFO.frequency.value = 0.05; // 20s sweep
      this.panLFO.start();
    } else {
      this.panLFO = null;
    }

    // Map of id -> { element, sourceNode, gainNode, eqNode, compNode,
    //               pannerNode, isConnected, volume, eqOn, compOn, panOn }
    this.sources = new Map();

    // Handle iOS AudioContext suspension
    this.context.onstatechange = () => {
      console.log(`MixBus: AudioContext state changed to ${this.context.state}`);
      if (this.context.state === 'running') {
        this.reconnectAllSources();
      }
    };
  }

  async resumeContext() {
    if (!this.supported) return;
    if (this.context.state === 'suspended' || this.context.state === 'interrupted') {
      try {
        await this.context.resume();
        console.log("MixBus: AudioContext resumed successfully.");
      } catch (err) {
        console.warn("MixBus: Failed to resume AudioContext", err);
      }
    }
  }

  setMasterVolume(value) {
    if (!this.supported) return;
    const clamped = Math.max(0, Math.min(1, value));
    this.masterGain.gain.setTargetAtTime(clamped, this.context.currentTime, 0.05);
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
    gainNode.connect(this.masterGain);

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
      volume: 1.0,
      eqOn: false,
      compOn: false,
      panOn: false
    });

    if (isConnected) {
      this._routeSource(this.sources.get(id));
    }

    return isConnected;
  }

  setSourceVolume(id, value) {
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
}

export const mixBus = new MixBus();
