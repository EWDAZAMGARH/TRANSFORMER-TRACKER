// TF-Tracker for Windows: opens the TF-Tracker site in its own window (no browser tab, no address bar).
// The site itself asks for the workshop code the first time; Electron keeps that choice and the login on this computer.
const { app, BrowserWindow, Menu, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');

let cfg = { url: 'https://ewdazamgarh.github.io/TRANSFORMER-TRACKER/', title: 'TF-Tracker' };
try { cfg = Object.assign(cfg, JSON.parse(fs.readFileSync(path.join(__dirname, 'app-config.json'), 'utf8'))); } catch (e) { }
if (process.env.TF_URL) cfg.url = process.env.TF_URL;   // for testing only
const HOME = new URL(cfg.url);

if (!app.requestSingleInstanceLock()) { app.quit(); }
let win = null;
app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });

function sameSite(u) { try { const x = new URL(u); return x.origin === HOME.origin; } catch (e) { return false; } }

function createWindow() {
  win = new BrowserWindow({
    width: 1280, height: 820, minWidth: 420, minHeight: 600, show: false, title: cfg.title, autoHideMenuBar: true,
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: { contextIsolation: true, nodeIntegration: false, sandbox: true, spellcheck: false }
  });
  Menu.setApplicationMenu(null);
  win.maximize();
  win.once('ready-to-show', () => win.show());
  win.loadURL(cfg.url);
  // links to other sites (for example the Supabase dashboard) open in the normal browser
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/i.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!sameSite(url) && !/^file:/.test(url)) { e.preventDefault(); if (/^https?:/i.test(url)) shell.openExternal(url); } });
  // no internet / site not reachable: show a small page with a Retry button
  win.webContents.on('did-fail-load', (e, code, desc, url, isMain) => {
    if (!isMain || code === -3) return;
    win.loadFile(path.join(__dirname, 'offline.html'), { query: { u: cfg.url } });
  });
  // Excel / file downloads: ask where to save
  win.webContents.session.on('will-download', (e, item) => {
    const p = dialog.showSaveDialogSync(win, { defaultPath: path.join(app.getPath('downloads'), item.getFilename()) });
    if (p) item.setSavePath(p); else item.cancel();
  });
  win.on('closed', () => { win = null; });
}

app.whenReady().then(() => {
  createWindow();
  app.on('activate', () => { if (!BrowserWindow.getAllWindows().length) createWindow(); });
});
app.on('window-all-closed', () => app.quit());
