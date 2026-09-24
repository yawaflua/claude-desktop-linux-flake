// Stub implementation of claude-native for Linux
// Uses Electron's native Linux support where possible instead of no-ops
const fs = require('fs');
const path = require('path');

const KeyboardKey = { Backspace: 43, Tab: 280, Enter: 261, Shift: 272, Control: 61, Alt: 40, CapsLock: 56, Escape: 85, Space: 276, PageUp: 251, PageDown: 250, End: 83, Home: 154, LeftArrow: 175, UpArrow: 282, RightArrow: 262, DownArrow: 81, Delete: 79, Meta: 187 };
Object.freeze(KeyboardKey);

//=============================================================================
// safe-fs containment API (upstream ref CC-2885)
//
// Newer Claude Desktop performs all sensitive filesystem access through a
// native openat-style API that operates on path *segments* beneath a root
// directory file descriptor, and refuses to fall back to path-based opens.
// The Windows/macOS builds ship this as native code; on Linux we implement
// it in pure JS on top of real file descriptors so the app will start.
//
// The root fd is a genuine directory fd (from openRootDir); we recover its
// current path via /proc/self/fd so the same fd the app opened resolves
// correctly regardless of who created it. Each segment is validated to be a
// single, non-traversing path component, and the leaf is opened with
// O_NOFOLLOW so a symlinked final component surfaces as ELOOP — exactly the
// error the caller expects for a containment violation.
//=============================================================================
const O_DIRECTORY = fs.constants.O_DIRECTORY || 0;
const O_NOFOLLOW = fs.constants.O_NOFOLLOW || 0;

function rootPathOf(rootFd) {
  // /proc/self/fd/<fd> is a symlink to the fd's backing path on Linux.
  return fs.readlinkSync('/proc/self/fd/' + rootFd);
}

function assertSegment(seg) {
  if (typeof seg !== 'string' || seg === '' || seg === '.' || seg === '..'
      || seg.includes('/') || seg.includes('\\') || seg.includes('\0')) {
    const err = new Error('safe-fs: illegal path segment: ' + String(seg));
    err.code = 'EXDEV';
    throw err;
  }
  return seg;
}

function resolveBeneath(rootFd, segments) {
  const root = rootPathOf(rootFd);
  const segs = (segments || []).map(assertSegment);
  const target = path.join(root, ...segs);
  // Defense in depth: the joined path must stay under the root.
  const rel = path.relative(root, target);
  if (rel === '..' || rel.startsWith('..' + path.sep) || path.isAbsolute(rel)) {
    const err = new Error('safe-fs: path escapes containment root');
    err.code = 'EXDEV';
    throw err;
  }
  return target;
}

function openRootDir(rootPath) {
  return fs.openSync(path.resolve(rootPath), fs.constants.O_RDONLY | O_DIRECTORY);
}

function openBeneath(rootFd, segments, flags, mode) {
  const target = resolveBeneath(rootFd, segments);
  // O_NOFOLLOW on the leaf: a symlinked final component throws ELOOP, which
  // the caller maps to its own "not a real file" error.
  return fs.openSync(target, (flags | O_NOFOLLOW) >>> 0, mode == null ? 0o600 : mode);
}

function renameBeneath(rootFd, fromSegments, toSegments) {
  fs.renameSync(
    resolveBeneath(rootFd, fromSegments),
    resolveBeneath(rootFd, toSegments)
  );
}

function unlinkBeneath(rootFd, segments) {
  fs.unlinkSync(resolveBeneath(rootFd, segments));
}

function mkdirBeneath(rootFd, segments, mode) {
  fs.mkdirSync(resolveBeneath(rootFd, segments),
    mode == null ? undefined : { mode });
}

// Helper: get the focused BrowserWindow (lazy-loaded to avoid circular deps)
// Filters destroyed windows from fallback to avoid errors like
// flashFrame() on a destroyed window or getIsMaximized() on a popup.
// Note: isVisible() is intentionally NOT checked — flashFrame() must work
// on minimized (non-visible) windows, which is its primary use case.
function getWindow() {
  try {
    const { BrowserWindow } = require('electron');
    const focused = BrowserWindow.getFocusedWindow();
    if (focused) return focused;
    // TODO: Fallback may return a popup window; callers like
    // getIsMaximized() may behave unexpectedly on popups.
    const win = BrowserWindow.getAllWindows().find(
      (w) => !w.isDestroyed()
    );
    return win || null;
  } catch (e) {
    console.warn('[Claude Native Stub] getWindow() failed:', e);
    return null;
  }
}

// AuthRequest stub - not available on Linux, will cause fallback to system browser
class AuthRequest {
  static isAvailable() {
    return false;
  }

  async start(url, scheme, windowHandle) {
    throw new Error('AuthRequest not available on Linux');
  }

  cancel() {
    // no-op
  }
}

module.exports = {
  getWindowsVersion: () => "10.0.0",
  setWindowEffect: () => {},
  removeWindowEffect: () => {},

  // Called by the settings DesktopInfo.getSystemInfo handler as
  // `Si()?.getWindowsElevationType() ?? null` — no platform guard, so a
  // missing method throws on every settings read. null is the "unknown"
  // value the caller already handles.
  getWindowsElevationType: () => null,

  // The process-memory sampler only checks that the native module loaded,
  // not that this method exists, then calls .finally() on the result — so
  // it must return a Promise. One null per requested pid is the same shape
  // the caller pre-fills for the unavailable case.
  readProcessFootprints: (pids) =>
    Promise.resolve((pids || []).map(() => null)),

  // Windows registry / macOS plist readers — no equivalent on Linux.
  // readRegistryValues is called on the hot path without a platform guard
  // (result ?? []), so it must return an empty array rather than throw.
  readRegistryValues: () => [],
  writeRegistryValue: () => {},
  deleteRegistryKey: () => {},
  enumRegistrySubkeys: () => [],
  enumRegistryValues: () => [],
  readUserPathValueRaw: () => null,
  writeUserPathValueRaw: () => {},
  readPlistValue: () => null,

  // safe-fs containment API (openat-style, ref CC-2885)
  openRootDir,
  openBeneath,
  renameBeneath,
  unlinkBeneath,
  mkdirBeneath,

  // Functional on Linux via Electron's native support
  getIsMaximized: () => {
    const win = getWindow();
    return win ? win.isMaximized() : false;
  },

  // Fixes: #149 - KDE Plasma: Window demands attention
  // flashFrame is natively supported on Linux Electron.
  // frame-fix-wrapper.js auto-clears on window focus.
  flashFrame: (flash) => {
    const win = getWindow();
    if (win) win.flashFrame(typeof flash === 'boolean' ? flash : true);
  },
  clearFlashFrame: () => {
    const win = getWindow();
    if (win) win.flashFrame(false);
  },

  showNotification: () => {},

  // Progress bar is natively supported on Linux (Unity/KDE/GNOME)
  setProgressBar: (progress) => {
    const win = getWindow();
    if (win && typeof progress === 'number') {
      win.setProgressBar(Math.max(0, Math.min(1, progress)));
    }
  },
  clearProgressBar: () => {
    const win = getWindow();
    if (win) win.setProgressBar(-1);
  },

  setOverlayIcon: () => {},
  clearOverlayIcon: () => {},
  KeyboardKey,
  AuthRequest
};
