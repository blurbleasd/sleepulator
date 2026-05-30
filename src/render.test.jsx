import { describe, it, expect } from 'vitest';
import { renderToStaticMarkup } from 'react-dom/server';
import React from 'react';
import { AppProvider } from './context/AppContext.jsx';
import AppLayout from './AppLayout.jsx';
import ErrorBoundary from './ErrorBoundary.jsx';

// Smoke test: the whole point is to fail the build if the app can't even mount.
// This is exactly the class of bug (TDZ refs, leaked/undefined identifiers from
// the original auto-extraction) that shipped silently because the Vite app was
// never deployed. Keep it in the deploy gate.
describe('App render', () => {
  it('mounts the provider + layout without throwing', () => {
    const tree = React.createElement(
      AppProvider,
      null,
      React.createElement(ErrorBoundary, null, React.createElement(AppLayout, null)),
    );
    expect(() => renderToStaticMarkup(tree)).not.toThrow();
  });
});
