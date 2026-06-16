import { describe, it, expect, afterEach } from 'vitest';
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
  it('is hidden until Feed Debug is opened, then exposes the teardown tools', async () => {
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });

    // Podcast controls (incl. Feed Debug) now live on a separate screen.
    expect(screen.queryByText('Audio Engine (dev)')).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
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
    await user.click(screen.getByRole('button', { name: 'Feed Debug' }));

    expect(screen.queryByText(/^state:/)).not.toBeInTheDocument();
    await user.click(screen.getByRole('button', { name: /refresh status/i }));

    // happy-dom has no AudioContext, so the engine reports unsupported/dead —
    // we only assert the readout rendered, not a specific state.
    const readout = await screen.findByText(/state:.*dead:/i);
    expect(readout).toBeInTheDocument();
  });
});

describe('Episode browser', () => {
  afterEach(() => { try { localStorage.clear(); } catch { /* ignore */ } });

  it('renders playlist episodes on the Playlist tab and filters them', async () => {
    localStorage.setItem('sleepulatorPlaylist', JSON.stringify([
      { id: 'e1', title: 'Sleepy Episode One', url: 'https://example.com/1.mp3' },
      { id: 'e2', title: 'Calm Episode Two', url: 'https://example.com/2.mp3' },
    ]));
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });

    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: /^playlist/i }));

    expect(screen.getByText('Sleepy Episode One')).toBeInTheDocument();
    expect(screen.getByText('Calm Episode Two')).toBeInTheDocument();

    // The filter input narrows the list by title.
    await user.type(screen.getByPlaceholderText(/filter episodes/i), 'calm');
    expect(screen.queryByText('Sleepy Episode One')).not.toBeInTheDocument();
    expect(screen.getByText('Calm Episode Two')).toBeInTheDocument();
  });

  it('reorders the playlist with the up/down buttons', async () => {
    localStorage.setItem('sleepulatorPlaylist', JSON.stringify([
      { id: 'e1', title: 'First Episode', url: 'https://example.com/1.mp3' },
      { id: 'e2', title: 'Second Episode', url: 'https://example.com/2.mp3' },
    ]));
    const user = userEvent.setup();
    render(<App />);
    await screen.findByRole('heading', { name: 'SLEEPULATOR' });
    await user.click(screen.getByRole('button', { name: /podcasts/i }));
    await user.click(screen.getByRole('button', { name: /^playlist/i }));

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
});
