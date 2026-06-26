import { defineConfig } from 'vite';

// Relative base so Capacitor native WebViews and Electron file:// loads resolve assets correctly.
//
// Dev/preview GitHub proxy: github.com / api.github.com do not send CORS headers,
// so a browser fetch() is blocked. We proxy them same-origin under /__gh and
// /__ghapi (see src/platform/githubHttp.ts). Native (Capacitor) and Electron use
// their own non-CORS transports instead.
const githubProxy = {
  '/__gh': {
    target: 'https://github.com',
    changeOrigin: true,
    secure: true,
    rewrite: (p: string) => p.replace(/^\/__gh/, ''),
  },
  '/__ghapi': {
    target: 'https://api.github.com',
    changeOrigin: true,
    secure: true,
    rewrite: (p: string) => p.replace(/^\/__ghapi/, ''),
  },
};

export default defineConfig({
  base: './',
  server: { proxy: githubProxy },
  preview: { proxy: githubProxy },
});
