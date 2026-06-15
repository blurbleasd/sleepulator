import { describe, it, expect, beforeEach, vi } from 'vitest';
import { MixBus } from './MixBus.js';

// ── Minimal Web Audio mock ────────────────────────────────────────────────
// Just enough surface for MixBus: nodes that connect/disconnect, AudioParams
// with setTargetAtTime, and a context whose `state` we can force to 'closed'
// to simulate an iOS interruption teardown.
class FakeParam {
  constructor(v = 0) { this.value = v; }
  setTargetAtTime(v) { this.value = v; }
}
function node(extra = {}) {
  return { connect() {}, disconnect() {}, ...extra };
}
class FakeAudioContext {
  constructor() {
    this.state = 'running';
    this.currentTime = 0;
    this.destination = node();
    this.onstatechange = null;
    FakeAudioContext.instances.push(this);
  }
  createGain() { return node({ gain: new FakeParam(1) }); }
  createBiquadFilter() { return node({ type: '', frequency: new FakeParam(), gain: new FakeParam() }); }
  createDynamicsCompressor() {
    return node({ threshold: new FakeParam(), knee: new FakeParam(), ratio: new FakeParam(), attack: new FakeParam(), release: new FakeParam() });
  }
  createStereoPanner() { return node({ pan: new FakeParam() }); }
  createOscillator() { return node({ type: '', frequency: new FakeParam(), start() {}, stop() {} }); }
  createMediaElementSource() { return node(); }
  async resume() {
    if (this.state === 'closed') {
      const err = new Error('Cannot resume a closed AudioContext');
      err.name = 'InvalidStateError';
      throw err;
    }
    this.state = 'running';
  }
  async close() { this.state = 'closed'; }
}
FakeAudioContext.instances = [];

const fakeEl = () => ({ volume: 1, muted: false, pause() {}, play: () => Promise.resolve() });

beforeEach(() => {
  FakeAudioContext.instances = [];
  globalThis.AudioContext = FakeAudioContext;
  globalThis.window = globalThis.window || globalThis;
  globalThis.window.AudioContext = FakeAudioContext;
  globalThis.window.webkitAudioContext = undefined;
  vi.spyOn(console, 'log').mockImplementation(() => {});
  vi.spyOn(console, 'warn').mockImplementation(() => {});
});

describe('MixBus construction', () => {
  it('builds a supported context with master gain and an empty source map', () => {
    const mb = new MixBus();
    expect(mb.supported).toBe(true);
    expect(mb.context.state).toBe('running');
    expect(mb.sources.size).toBe(0);
    expect(FakeAudioContext.instances).toHaveLength(1);
  });

  it('reports unsupported when no AudioContext exists', () => {
    globalThis.window.AudioContext = undefined;
    const mb = new MixBus();
    expect(mb.supported).toBe(false);
    expect(mb.isDead()).toBe(true);
  });
});

describe('isDead', () => {
  it('is false for a running context and true once closed', async () => {
    const mb = new MixBus();
    expect(mb.isDead()).toBe(false);
    await mb.context.close();
    expect(mb.isDead()).toBe(true);
  });
});

describe('setMasterVolume', () => {
  it('clamps and stashes the value so a rebuild can re-apply it', () => {
    const mb = new MixBus();
    mb.setMasterVolume(2);
    expect(mb._lastMasterVolume).toBe(1);
    mb.setMasterVolume(0.3);
    expect(mb._lastMasterVolume).toBeCloseTo(0.3);
  });
});

describe('rebuild', () => {
  it('closes the dead context, builds a fresh one, and clears stale sources', async () => {
    const mb = new MixBus();
    mb.addSource('ambient', fakeEl());
    const oldContext = mb.context;
    expect(mb.sources.size).toBe(1);

    await mb.rebuild();

    expect(oldContext.state).toBe('closed');
    expect(mb.context).not.toBe(oldContext);
    expect(mb.context.state).toBe('running');
    expect(FakeAudioContext.instances).toHaveLength(2);
    // sources are cleared; AppContext's callback is responsible for re-adding
    expect(mb.sources.size).toBe(0);
  });

  it('passes captured per-layer settings to the onRebuild callback', async () => {
    const mb = new MixBus();
    mb.addSource('ambient', fakeEl());
    mb.addSource('pod', fakeEl());
    mb.setSourceVolume('pod', 0.4);
    mb.setEffects('pod', { eqOn: true, compOn: false, panOn: true });

    let captured = null;
    mb.onRebuild((layers) => { captured = layers; });
    await mb.rebuild();

    expect(captured).toHaveLength(2);
    const pod = captured.find((l) => l.id === 'pod');
    expect(pod).toMatchObject({ id: 'pod', volume: 0.4, eqOn: true, compOn: false, panOn: true });
  });

  it('lets the callback re-add sources onto the new context', async () => {
    const mb = new MixBus();
    mb.addSource('ambient', fakeEl());
    mb.onRebuild((layers) => {
      for (const l of layers) mb.addSource(l.id, fakeEl());
    });

    await mb.rebuild();
    expect(mb.sources.size).toBe(1);
    expect(mb.sources.has('ambient')).toBe(true);
  });

  it('re-applies the last master volume to the new context', async () => {
    const mb = new MixBus();
    mb.setMasterVolume(0.25);
    await mb.rebuild();
    expect(mb.masterGain.gain.value).toBeCloseTo(0.25);
  });

  it('does not run concurrently (rebuild storm guard)', async () => {
    const mb = new MixBus();
    const calls = [];
    mb.onRebuild(() => { calls.push(1); });
    mb._rebuilding = true;     // simulate an in-flight rebuild
    await mb.rebuild();
    expect(calls).toHaveLength(0);
  });
});

describe('state change handling', () => {
  it('rebuilds when the context transitions to closed', async () => {
    const mb = new MixBus();
    const spy = vi.spyOn(mb, 'rebuild');
    mb.context.state = 'closed';
    mb._handleStateChange();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('re-routes in place when the context returns to running', () => {
    const mb = new MixBus();
    mb.addSource('ambient', fakeEl());
    const spy = vi.spyOn(mb, 'reconnectAllSources');
    mb.context.state = 'running';
    mb._handleStateChange();
    expect(spy).toHaveBeenCalledTimes(1);
  });
});

describe('resumeContext', () => {
  it('rebuilds instead of resuming when the context is dead', async () => {
    const mb = new MixBus();
    await mb.context.close();
    const spy = vi.spyOn(mb, 'rebuild');
    await mb.resumeContext();
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it('resumes a suspended context without rebuilding', async () => {
    const mb = new MixBus();
    mb.context.state = 'suspended';
    const spy = vi.spyOn(mb, 'rebuild');
    await mb.resumeContext();
    expect(spy).not.toHaveBeenCalled();
    expect(mb.context.state).toBe('running');
  });

  it('falls back to rebuild when resume rejects with InvalidStateError', async () => {
    const mb = new MixBus();
    // Force a state that enters the resume branch but whose resume() throws.
    mb.context.state = 'suspended';
    mb.context.resume = async () => {
      const err = new Error('closed'); err.name = 'InvalidStateError'; throw err;
    };
    const spy = vi.spyOn(mb, 'rebuild').mockResolvedValue();
    await mb.resumeContext();
    expect(spy).toHaveBeenCalledTimes(1);
  });
});
