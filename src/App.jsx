import React from 'react';
import { AppProvider } from './context/AppContext.jsx';
import AppLayout from './AppLayout.jsx';
import ErrorBoundary from './ErrorBoundary.jsx';
import './index.css';

export default function App() {
  return (
    <AppProvider>
      <ErrorBoundary>
        <AppLayout />
      </ErrorBoundary>
    </AppProvider>
  );
}
