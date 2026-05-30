import React from 'react';

// Top-level guard for render-time crashes. It is mounted *inside* AppProvider,
// so the context that owns audio playback stays alive even if the UI subtree
// throws — any sound that was playing keeps going while the user recovers.
export default class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { error: null };
  }

  static getDerivedStateFromError(error) {
    return { error };
  }

  componentDidCatch(error, info) {
    console.error('Sleepulator UI crashed:', error, info);
  }

  render() {
    if (!this.state.error) return this.props.children;

    return (
      <div
        role="alert"
        style={{
          position: 'fixed',
          inset: 0,
          zIndex: 10000,
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          gap: '1rem',
          padding: '2rem',
          textAlign: 'center',
          background: '#02040a',
          color: '#f8fafc',
          fontFamily: "'Outfit', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
        }}
      >
        <div style={{ fontSize: '2.5rem' }} aria-hidden="true">🌙</div>
        <div style={{ fontSize: '1.1rem', fontWeight: 600 }}>Something hiccuped.</div>
        <div style={{ maxWidth: 320, color: '#cbd5e1', fontSize: '0.9rem', lineHeight: 1.5 }}>
          Any audio that was playing should still be going. Reload to bring the controls back.
        </div>
        <button
          onClick={() => window.location.reload()}
          style={{
            marginTop: '0.5rem',
            padding: '0.75rem 1.5rem',
            fontSize: '1rem',
            fontWeight: 600,
            color: '#02040a',
            background: '#818cf8',
            border: 'none',
            borderRadius: 999,
            cursor: 'pointer',
          }}
        >
          Reload app
        </button>
      </div>
    );
  }
}
