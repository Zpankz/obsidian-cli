# obsidian-cli

Extracted and decomposed Obsidian CLI code for analysis and reverse engineering.

This repo contains the CLI subsystem extracted from the Obsidian desktop app (v1.12.0), with the minified code split into readable, annotated modules.

## What is Obsidian CLI?

Obsidian 1.7+ includes a built-in command-line interface that allows interacting with vaults from the terminal. It supports:

- **80+ commands** covering file CRUD, search, tags, properties, tasks, plugins, sync, themes, bookmarks, and more
- **Interactive TUI mode** with tab completion, history, reverse search (Ctrl+R), and Emacs keybindings
- **One-shot command mode** for scripting (`obsidian read file="note.md"`)
- **Developer commands** including JS eval, DOM inspection, CDP debugging, and screenshots

## Architecture

See [`analysis/ARCHITECTURE.md`](analysis/ARCHITECTURE.md) for full technical details.

### TL;DR

```
Terminal                  Obsidian (main instance)
┌──────────┐  Unix sock  ┌─────────────────────┐
│ obsidian │────────────▶│  Electron Main Proc  │
│ <args>   │  (or named  │  (main.js in asar)   │
└──────────┘   pipe)     │                      │
                         │  executeCliRequest() │
                         │         │            │
                         │         ▼            │
                         │  BrowserWindow       │
                         │  .executeJavaScript  │
                         │  window.handleCli()  │
                         └─────────────────────┘
```

1. CLI invocation tries to acquire an Electron single-instance lock
2. If another instance is running, the new process creates a socket server
3. The main instance connects to that socket and processes commands
4. Commands execute as JavaScript in the vault's renderer process

## Repo Structure

```
extracted/
├── raw/                          # Unmodified files from the asar
│   ├── main.js                   # Minified app main process (from obsidian-1.12.0.asar)
│   ├── bootstrapper.js           # App bootstrapper (from app.asar)
│   └── package.json              # Package metadata
│
└── prettified/                   # Decomposed and annotated modules
    ├── main.prettified.js        # Full prettified main.js (js-beautify output)
    ├── cli-terminal-colors.js    # ANSI escape codes, logo renderer
    ├── cli-key-parser.js         # Terminal key input parser
    ├── cli-argument-parser.js    # CLI argument tokenizer + usage flag parser
    ├── cli-tui-session.js        # Interactive TUI session (REPL, completions, history)
    └── cli-ipc-transport.js      # Socket IPC layer between CLI and Electron

analysis/
├── ARCHITECTURE.md               # Full architecture documentation
└── SYMBOL_MAP.md                 # Minified → readable name mapping
```

## Key Modules

| Module | Original Symbol | Description |
|--------|----------------|-------------|
| `cli-terminal-colors.js` | `O`, `vt` | ANSI colors, ASCII logo |
| `cli-key-parser.js` | `Et` | Raw terminal input → key event objects |
| `cli-argument-parser.js` | `Ot`, `Bt` | Tokenizer for quoted CLI args, usage pattern parser |
| `cli-tui-session.js` | `Me`, `st` | Full interactive TUI with completions, history, search |
| `cli-ipc-transport.js` | `Re`, socket code | Unix domain socket / named pipe IPC |

## Source

Extracted from:
- `/Applications/Obsidian.app/Contents/Resources/app.asar` (bootstrapper)
- `~/Library/Application Support/obsidian/obsidian-1.12.0.asar` (app code)

## Disclaimer

This is a reverse-engineering study of proprietary software. The extracted code belongs to Dynalist Inc. / Obsidian. This repo is for educational analysis purposes only.
