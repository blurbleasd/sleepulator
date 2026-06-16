import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { render, screen, act } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { AppProvider, useAppContext } from './AppContext.jsx';

// Multi-instance conflict resolution: when a second instance broadcasts that it
// started playing, this instance must silence itself (overlapping brown noise
// phase-cancels and ruins sleep). We mock BroadcastChannel so one fake instance
// can deliver a PLAYING message to the provider's listener.

class MockBroadcastChannel {
  static channels = [];
  constructor(name) {
    this.name = name;
    this.onmessage = null;
    this.closed = false;
    MockBroadcastChannel.channels.push(this);
  }
  postMessage(data) {
    for (const ch of MockBroadcastChannel.channels) {
      if (ch !== this && !ch.closed && ch.name === this.name && ch.onmessage) {
        ch.onmessage({ data });
      }
    }
  }
  close() { this.closed = true; }
}

function Probe() {
  const ctx = useAppContext();
  return (
    <div>
      <span data-testid="ambient">{String(ctx.ambientOn)}</span>
      <button onClick={() => ctx.setAmbientOn(true)}>arm-ambient</button>
    </div>
  );
}

const CHANNEL = 'sleepulator-playback';

// AppProvider's mount kicks off an async caches.open() chain that ends in a
// setState. Flush it inside an act() so it doesn't resolve during cleanup and
// trip React's "Should not already be working" act guard.
const settle = () => act(async () => { await new Promise((r) => setTimeout(r)); });

beforeEach(() => {
  MockBroadcastChannel.channels = [];
  globalThis.BroadcastChannel = MockBroadcastChannel;
});

afterEach(() => {
  try { localStorage.clear(); } catch { /* ignore */ }
  delete globalThis.BroadcastChannel;
});

describe('multi-instance playback channel', () => {
  it('silences local ambient when another instance claims playback', async () => {
    const user = userEvent.setup();
    render(<AppProvider><Probe /></AppProvider>);
    await settle();
    await user.click(await screen.findByText('arm-ambient'));
    expect(screen.getByTestId('ambient').textContent).toBe('true');

    // A different instance on the same channel announces it started playing.
    const other = new MockBroadcastChannel(CHANNEL);
    await act(async () => { other.postMessage({ type: 'PLAYING', id: 'other-instance' }); });

    expect(screen.getByTestId('ambient').textContent).toBe('false');
    await settle();
  });

  it('ignores messages that are not a foreign PLAYING claim', async () => {
    const user = userEvent.setup();
    render(<AppProvider><Probe /></AppProvider>);
    await settle();
    await user.click(await screen.findByText('arm-ambient'));
    expect(screen.getByTestId('ambient').textContent).toBe('true');

    const other = new MockBroadcastChannel(CHANNEL);
    await act(async () => {
      other.postMessage({ type: 'SOMETHING_ELSE', id: 'other-instance' });
      other.postMessage({ id: 'other-instance' }); // no type at all
    });

    // Neither message is a foreign PLAYING claim, so playback is untouched.
    expect(screen.getByTestId('ambient').textContent).toBe('true');
    await settle();
  });
});
