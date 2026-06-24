// Electron preload — exposes a minimal, CORS-free GitHub HTTP bridge and an
// "open external URL" helper to the sandboxed renderer. Without this, the web
// app's window.__electron__ is undefined, so GitHub fetches hit CORS and the
// device-flow "Open GitHub" link can't escape the app window.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('__electron__', {
  openExternal: (url) => ipcRenderer.invoke('open-external', url),
  // Mirrors the subset of fetch used for GitHub: returns {status,statusText,headers,body}.
  ghFetch: (req) => ipcRenderer.invoke('gh-fetch', req),
});
