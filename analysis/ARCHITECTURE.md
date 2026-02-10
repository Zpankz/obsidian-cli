# Obsidian CLI Architecture

## Overview

The Obsidian CLI is not a standalone binary — it is the Obsidian Electron app itself, invoked from the command line. The same `obsidian` binary serves as both the GUI application and the CLI tool. The CLI subsystem is embedded in the app's main process code (`main.js` inside the asar package).

## Boot Sequence

### 1. Electron Bootstrap (`app.asar/main.js`)
- Located at `/Applications/Obsidian.app/Contents/Resources/app.asar`
- Reads `~/Library/Application Support/obsidian/` for updated asar files
- Loads the newest `obsidian-X.Y.Z.asar` via `require(asarPath + '/main.js')`
- The loaded module exports a function: `module.exports = function(resourcePath, updateEvents, isDev) { ... }`
- Handles auto-updates by downloading signed+hashed asar files from GitHub/releases.obsidian.md

### 2. App Initialization (`obsidian-1.12.0.asar/main.js`)
- The exported function receives `(resourcePath, updateEvents, isDev)` args
- Parses `process.argv` to extract CLI arguments
- Generates a random 16-char hex session ID
- Detects TTY mode via `process.stdin.isTTY && process.stdout.isTTY`

### 3. Single Instance Lock (critical for CLI)
- Calls `app.requestSingleInstanceLock()` with `{ argv, endpoint, tty }` data
- **If lock acquired** (first instance): continues full GUI startup
- **If lock denied** (CLI invocation while Obsidian running): enters CLI client mode

## CLI Communication Protocol

### Client Side (secondary process)
```
Process spawned → requestSingleInstanceLock(data) → DENIED
  → Create net.Server at endpoint path
  → Wait for connection from main instance
  → Pipe: stdin → socket → stdout
  → Exit when socket closes
```

### Server Side (main Obsidian instance)
```
Receives 'second-instance' event with { argv, endpoint, tty }
  → net.createConnection(endpoint) with retry (2s timeout)
  → If TTY mode & no specific command:
      → Start interactive TUI session (startTUISession)
  → If non-TTY or has command args:
      → executeCliRequest(vaultId, argv)
      → Write result to socket
      → Close socket
```

### Socket Endpoints
- **macOS/Linux**: `$TMPDIR/<hex16>.sock` (Unix domain socket)
- **Windows**: `\\.\pipe\<hex16>` (named pipe)

## Command Execution

### executeCliRequest(vaultId, argv)
1. Opens or finds the vault's BrowserWindow (without stealing focus)
2. Injects JavaScript into the renderer:
   ```javascript
   new Promise((resolve, reject) => {
       let argv = [...];
       if (window.handleCli) {
           Promise.resolve(window.handleCli(argv)).then(resolve, reject);
       } else {
           window.cliQueue = window.cliQueue || [];
           window.cliQueue.push({ argv, resolve, reject });
       }
   })
   ```
3. `window.handleCli` is defined in the renderer's `app.js` (not extracted here)
4. Returns the string result back through the socket

### CLI Enable Gate
- CLI is gated behind `Settings > General > Advanced > CLI`
- Stored as `x.cli` in `~/Library/Application Support/obsidian/obsidian.json`
- If disabled, all CLI requests return an error message

## Interactive TUI

### Session Lifecycle
1. `startTUISession(socket, vaultId, api)` creates a `TUISession`
2. Fetches completions via hidden `__completions` and `__files` commands
3. Renders welcome screen with ASCII logo
4. Enters event loop reading raw terminal bytes

### Key Features
- **Tab completion**: Commands, flags, file paths, folder paths, enum values, vault names
- **History**: Up/Down arrows navigate command history
- **Reverse search**: Ctrl+R with incremental search highlighting
- **Emacs bindings**: Ctrl+A/E (home/end), Ctrl+U/K (kill line), Ctrl+W (kill word), Alt+B/F (word jump)
- **Suggestion dropdown**: Scrollable window showing up to 10 suggestions with descriptions
- **vault:open**: Switch between vaults without leaving the TUI

### Completion Data Flow
```
TUI → executeCliRequest(vault, ["__completions"]) → JSON { command: { description, flags } }
TUI → executeCliRequest(vault, ["__files", "limit=1000"]) → JSON ["file1.md", "file2.md", ...]
TUI → executeCliRequest(vault, ["vaults"]) → "Vault1\nVault2\n..."
```

## Non-CLI Components in main.js

The minified `main.js` also contains these non-CLI systems (not decomposed):
- **Ad-block filter engine** (`me` class) — blocks ads in webviews
- **Context menu builder** (`at` function) — right-click menus with spellcheck
- **Window management** — BrowserWindow creation, positioning, state persistence
- **IPC handlers** — 40+ `ipcMain.on()` handlers for renderer communication
- **Protocol handler** — Custom `app://` protocol for loading vault files
- **Auto-update system** — Managed by the bootstrapper, events forwarded
- **URI handler** — `obsidian://` protocol for deep linking
- **Menu system** — Application menus with keyboard shortcuts
- **Vault management** — Creating, opening, moving, removing vaults
- **Security** — CSP enforcement, webview sandboxing, permission handlers
- **CLI registration** — `register-cli` IPC handler that adds the binary to PATH

## Symbol Map

Key minified identifiers → readable names:

| Minified | Readable | Type |
|----------|----------|------|
| `Me` | `TUISession` | class |
| `st` | `startTUISession` | function |
| `Et` | `parseKeyInput` | function |
| `Ot` | `tokenizeArguments` | function |
| `Bt` | `parseUsageFlags` | function |
| `O` | `ANSI` | object (color codes) |
| `vt` | `renderLogo` | function |
| `de` | `MAX_SUGGESTION_LINES` | constant (10) |
| `At` | `DIVIDER_WIDTH` | constant (54) |
| `Re` | `randomHex` | function |
| `Ze` | `executeCliRequest` | async function |
| `me` | `AdBlockFilter` | class |
| `at` | `showContextMenu` | function |
| `se` | `trySafe` | function (try/catch wrapper) |
| `le` | `openVault` | function |
| `Pe` | `getVaultIdByName` | function |
| `gt` | `getVaultNameById` | function |
| `mt` | `getVaultIdByPath` | function |
| `Ae` | `net` (module) | require |
| `s` | `electron` (module) | require |
| `m` | `fs` (module) | require |
| `S` | `path` (module) | require |
| `$` | `os` (module) | require |
| `te` | `os` (module, alt ref) | require |
| `lt` | `child_process` (module) | require |
