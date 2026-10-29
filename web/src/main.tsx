import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { VOYAGE_APP_DEFAULTS } from '@yiminlab/voyage';
import { VoyageProvider } from '@yiminlab/voyage/react';
import '@yiminlab/voyage/tokens.css';
import '@yiminlab/voyage/voyage.css';
import './style.css';
import App from './App';

createRoot(document.getElementById('root')!).render(
  <StrictMode><VoyageProvider defaults={VOYAGE_APP_DEFAULTS.quarry}><App /></VoyageProvider></StrictMode>,
);
