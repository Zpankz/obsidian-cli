# Symbol Map: Minified → Readable

Complete mapping of minified identifiers in `obsidian-1.12.0.asar/main.js` to their deduced readable names.

## Module Imports

| Minified | Module | Notes |
|----------|--------|-------|
| `s` | `electron` | Primary Electron API |
| `m` | `fs` | Via `ge(require("fs"))` — ESM compat wrapper |
| `lt` | `child_process` | Used for CLI PATH registration |
| `Ae` | `net` | TCP/Unix socket IPC |
| `ut` | `original-fs` | Used for asar copy (bypasses asar fs overlay) |
| `$` | `os` | Used in TUI code |
| `te` | `os` | Used in main app code (duplicate import) |
| `S` | `path` | Used in main app code |
| `ct` | `url` | `pathToFileURL` for Linux file opening |
| `ft` | `util` | `promisify` for CLI registration |

## Helper Functions

| Minified | Readable | Signature | Purpose |
|----------|----------|-----------|---------|
| `ge` | `esmCompat` | `(module) → module` | Wraps CJS modules for ESM-style default import |
| `St` | `copyProps` | `(target, source, exclude, descriptor)` | Object property copier |
| `re` | `conditionalArray` | `(condition, fn) → []` | Returns `fn()` if truthy, else `[]` |
| `Re` | `randomHex` | `(length) → string` | Generates random hex string |
| `se` | `trySafe` | `(fn, fallback) → result` | Try/catch wrapper returning fallback on error |
| `ot` | `isUNCPath` | `(path) → boolean` | Detects Windows UNC network paths |
| `rt` | `truncateString` | `(str, maxLen) → string` | Truncates with ellipsis character |
| `nt` | `stripProtocol` | `(url) → string` | Strips http(s)://www. prefix |
| `it` | `isSeparator` | `(char) → boolean` | Checks if char is URL separator (/:?=&) |

## CLI System

| Minified | Readable | Type | Purpose |
|----------|----------|------|---------|
| `Me` | `TUISession` | class | Interactive terminal session handler |
| `st` | `startTUISession` | async function | Initializes and runs TUI event loop |
| `Et` | `parseKeyInput` | function | Terminal raw bytes → key event object |
| `Ot` | `tokenizeArguments` | function | CLI string → token array (handles quotes) |
| `Bt` | `parseUsageFlags` | function | Usage pattern → flag name array |
| `O` | `ANSI` | object | Terminal color escape codes |
| `vt` | `renderLogo` | function | ASCII art Obsidian logo with version |
| `de` | `MAX_SUGGESTION_LINES` | const (10) | Max visible suggestions in dropdown |
| `At` | `DIVIDER_WIDTH` | const (54) | Horizontal rule width in TUI |
| `Ze` | `executeCliRequest` | async function | Runs CLI command via renderer JS injection |

## Ad-Block System

| Minified | Readable | Type | Purpose |
|----------|----------|------|---------|
| `me` | `AdBlockFilter` | class | EasyList-compatible ad block filter |
| `Ft` | `matchRule` | function | Tests single rule against URL |

## Application Core

| Minified | Readable | Type | Purpose |
|----------|----------|------|---------|
| `le` | `openVault` | function | Opens/focuses a vault BrowserWindow |
| `Pe` | `getVaultIdByName` | function | Vault name → vault ID lookup |
| `gt` | `getVaultNameById` | function | Vault ID → vault name lookup |
| `mt` | `getVaultIdByPath` | function | File path → containing vault ID |
| `at` | `showContextMenu` | function | Builds and shows right-click menu |
| `ke` | `setupWindowEvents` | function | Attaches event listeners to BrowserWindow |
| `We` | `secureWebContents` | function | Sets up webview security policies |
| `Ve` | `computeWindowBounds` | function | Calculates window position within displays |
| `Qe` | `createDialogWindow` | function | Creates non-resizable dialog windows |
| `Je` | `buildApplicationMenu` | function | Constructs the app menu bar |
| `Te` | `handleObsidianUri` | function | Processes `obsidian://` protocol URLs |
| `Xe` | `dispatchToVault` | function | Sends action object to vault renderer |
| `Se` | `getMostRecentVaultId` | function | Returns ID of last-focused vault |
| `ce` | `handleExternalUrl` | async function | Opens URLs with security checks |

## State Variables

| Minified | Readable | Purpose |
|----------|----------|---------|
| `M` | `userDataPath` | `app.getPath('userData')` |
| `K` | `documentsPath` | User's Documents folder |
| `Q` | `desktopPath` | User's Desktop folder |
| `I` | `vaults` | Vault registry `{ id: { path, ts, open } }` |
| `_` | `windows` | Active BrowserWindows `{ vaultId: BrowserWindow }` |
| `x` | `config` | `obsidian.json` settings object |
| `X` | `adBlockEngine` | Active AdBlockFilter instance |
| `G` | `sessions` | Web sessions registry |
| `J` | `appVersion` | Package version string |
| `ie` | `starterWindow` | Vault chooser/starter window |
| `fe` | `helpWindow` | Help dialog window |
| `we` | `isQuitting` | App shutdown flag |
| `Z` | `iconPath` | Custom app icon path |
| `T` | `updateStatus` | Update state string |
| `P` | `isCheckingUpdate` | Update check in progress flag |

## Platform Flags

| Minified | Readable | Value |
|----------|----------|-------|
| `U` | `isMac` | `process.platform === "darwin"` |
| `Y` | `isWindows` | `process.platform === "win32"` |
| `Pt` | `electronVersion` | `process.versions.electron` |
| `It` | `electronMajor` | `parseInt(electronVersion.split(".")[0])` |
