const { app, BrowserWindow, shell, ipcMain } = require('electron');
const path = require('path');
const https = require('https');

const isDev = !app.isPackaged;

// CORS-free GitHub fetch in the main process (Node https — no browser origin).
function ghFetch({ url, method = 'GET', headers = {}, body }) {
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(url); } catch (e) { reject(e); return; }
    const req = https.request(
      {
        hostname: u.hostname,
        path: u.pathname + u.search,
        method,
        headers: { 'User-Agent': 'Mouse-Electron', ...headers },
      },
      (res) => {
        let data = '';
        res.on('data', (c) => { data += c; });
        res.on('end', () => {
          const flat = {};
          for (const [k, v] of Object.entries(res.headers)) flat[k] = Array.isArray(v) ? v.join(', ') : String(v);
          resolve({ status: res.statusCode || 0, statusText: res.statusMessage || '', headers: flat, body: data });
        });
      },
    );
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1280,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      sandbox: true,
      preload: path.join(__dirname, 'preload.cjs'),
    },
  });

  if (isDev) {
    win.loadURL('http://localhost:5173');
    win.webContents.openDevTools({ mode: 'detach' });
  } else {
    win.loadFile(path.join(__dirname, '../dist/index.html'));
  }

  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });
}

ipcMain.handle('open-external', (_e, url) => shell.openExternal(url));
ipcMain.handle('gh-fetch', (_e, req) => ghFetch(req));

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
