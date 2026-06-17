import React from 'react';
import ReactDOM from 'react-dom/client';
// Self-hosted Outfit (was a render-blocking Google Fonts <link>). Bundled by
// Vite so first paint and offline both work with no network dependency. Weights
// match what the UI uses: 300/400/600/700/900.
import '@fontsource/outfit/300.css';
import '@fontsource/outfit/400.css';
import '@fontsource/outfit/600.css';
import '@fontsource/outfit/700.css';
import '@fontsource/outfit/900.css';
import App from './App';
import './index.css';

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
