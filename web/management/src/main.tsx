import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import '@/styles/global.scss';
import App from './App.tsx';

document.title = 'WGYC Proxy API Management Center';
document.documentElement.setAttribute('translate', 'no');
document.documentElement.classList.add('notranslate');

// The favicon is declared inline in index.html, so no runtime swap is needed here.

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>
);
