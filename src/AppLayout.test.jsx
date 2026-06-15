import { describe, it, expect } from 'vitest';
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
