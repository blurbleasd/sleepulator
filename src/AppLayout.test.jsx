import { describe, it, expect, afterEach, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import App from './App.jsx';

// Integration tests that mount the whole app (provider + layout) and drive it
// the way a user would. The point is to give the planned AppContext/AppLayout
// refactor a safety net: if a split breaks the wiring between state and UI,
// these fail. They run under happy-dom with audio/cache APIs stubbed (see
// test-setup.js), so they exercise UI behavior, not real playback.

describe('App shell', () => {
  it('mounts and renders the core controls', async () => {
    render(<App />);
    // Header proves the tree mounted past the ErrorBoundary.
    expect(await screen.findByRole('heading', { name: 'SLEEPULATOR' })).toBeInTheDocument();
    // Primary mixer + timer sections are always present.
    expect(screen.getByText('Master')).toBeInTheDocument();
    expect(screen.getByText('Sleep Timer')).toBeInTheDocument();
    expect(screen.getByText('Ambient')).toBeInTheDocument();
    expect(screen.getByText('Binaural')).toBeInTheDocument();
    // With no episode loaded, the now-playing bar stays hidden.
    expect(screen.queryByText(/now playing|paused/i)).not.toBeInTheDocument();
  });
});

describe('Audio Engine dev panel (Feed Debug)', () => {
  // Opening Feed Debug persists showFeedDebug=true; clear it so the next test
  // starts from the closed state. (Persistence now works correctly — it used to
  // be silently aborted by an unsupported-env throw in the settings effect.)
  afterEach(() => { try { localStorage.clear(); } catch { /* ignore */ } });

  it('is hidden until Feed Debug is opened, then exposes the teardown tools', async () => {
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });

    // Podcast controls (incl. Feed Debug) now live on the Podcasts > Settings screen.
    expect(screen.queryByText('Audio Engine (dev)')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: 'Settings' }));
    expect(screen.queryByText('Audio Engine (dev)')).not.toBeInTheDocument();

    await user.click(screen.getByRole('button', { name: 'Feed Debug' }));

    // Panel + our rebuild dev tools are now visible.
    expect(screen.getByText('Audio Engine (dev)')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: /force teardown \+ rebuild/i })).toBeInTheDocument();
  });

  it('shows a diagnostics readout when Refresh status is clicked', async () => {
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: 'Settings' }));
    await user.click(screen.getByRole('button', { name: 'Feed Debug' }));

    expect(screen.queryByText(/^state:/)).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /refresh status/i }));

    // happy-dom has no AudioContext, so the engine reports unsupported/dead —
    // we only assert the readout rendered, not a specific state.
    const readout = await screen.findByText(/state:.*dead:/i);
    expect(readout).toBeInTheDocument();
  });
});

describe('Queue (Up next)', () => {
  afterEach(() => { try { localStorage.clear(); } catch { /* ignore */ } });

  it('renders queued episodes on the Up next screen', async () => {
    localStorage.setItem('sleepulatorPlaylist', JSON.stringify([
      { id: 'e1', title: 'Sleepy Episode One', url: 'https://example.com/1.mp3' },
      { id: 'e2', title: 'Calm Episode Two', url: 'https://example.com/2.mp3' },
    ]));
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });

    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: /up next/i }));

    expect(screen.getByText('Sleepy Episode One')).toBeInTheDocument();
    expect(screen.getByText('Calm Episode Two')).toBeInTheDocument();
  });

  it('reorders the queue with the up/down buttons', async () => {
    localStorage.setItem('sleepulatorPlaylist', JSON.stringify([
      { id: 'e1', title: 'First Episode', url: 'https://example.com/1.mp3' },
      { id: 'e2', title: 'Second Episode', url: 'https://example.com/2.mp3' },
    ]));
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: /up next/i }));

    // Initially First precedes Second.
    let first = screen.getByText('First Episode');
    let second = screen.getByText('Second Episode');
    expect(first.compareDocumentPosition(second) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();

    // Move the first item down; now Second should precede First.
    await user.click(screen.getAllByRole('button', { name: 'Move down' })[0]);
    first = screen.getByText('First Episode');
    second = screen.getByText('Second Episode');
    expect(second.compareDocumentPosition(first) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('renders episodes in chunks with a Load more button', async () => {
    const many = Array.from({ length: 45 }, (_, i) => ({ id: `e${i}`, title: `Episode ${i}`, url: `https://example.com/${i}.mp3` }));
    localStorage.setItem('sleepulatorPlaylist', JSON.stringify(many));
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: /up next/i }));

    // First chunk only (40) — episode 44 is not rendered yet.
    expect(screen.getByText('Episode 0')).toBeInTheDocument();
    expect(screen.queryByText('Episode 44')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /load more/i }));
    expect(screen.getByText('Episode 44')).toBeInTheDocument();
  });
});

describe('Offline UX', () => {
  afterEach(() => {
    try { localStorage.clear(); } catch { /* ignore */ }
    try { Object.defineProperty(navigator, 'onLine', { value: true, configurable: true }); } catch { /* ignore */ }
  });

  it('disables Play for un-downloaded episodes when offline', async () => {
    Object.defineProperty(navigator, 'onLine', { value: false, configurable: true });
    localStorage.setItem('sleepulatorPlaylist', JSON.stringify([
      { id: 'e1', title: 'Uncached Episode', url: 'https://example.com/1.mp3' },
    ]));
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: /up next/i }));

    // The caches stub reports nothing cached, so an offline Play is locked.
    const lockedPlay = screen.getByRole('button', { name: /unavailable offline/i });
    expect(lockedPlay).toBeDisabled();
  });
});

describe('Podcast library', () => {
  afterEach(() => { try { localStorage.clear(); } catch { /* ignore */ } });

  it('removes a saved podcast from the library', async () => {
    localStorage.setItem('feedSubs', JSON.stringify([
      { url: 'https://example.com/feed', name: 'Test Feed', episodeCount: 5 },
    ]));
    window.confirm = () => true;
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });
    await user.click(screen.getByRole('button', { name: /podcasts/i }));

    expect(screen.getByText('Test Feed')).toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: 'Remove Test Feed' }));
    expect(screen.queryByText('Test Feed')).not.toBeInTheDocument();
  });
});
