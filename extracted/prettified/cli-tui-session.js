/**
 * Obsidian CLI - TUI Session Handler
 * Extracted from obsidian-1.12.0.asar/main.js
 * 
 * The TUISession class (originally minified as `Me`) manages the interactive
 * terminal user interface. It provides:
 * - Command autocomplete with fuzzy matching
 * - History navigation (up/down arrows, Ctrl+R reverse search)
 * - Emacs-style keybindings (Ctrl+A/E/U/K/W, Alt+B/F)
 * - Tab completion for commands, flags, file paths, and vault names
 * - Suggestion dropdown with scrollable window
 * 
 * The TUI communicates over a Unix domain socket (macOS/Linux) or named pipe
 * (Windows) connected to the main Obsidian Electron process.
 */

const os = require('os');
const { ANSI, MAX_SUGGESTION_LINES, DIVIDER_WIDTH, renderLogo } = require('./cli-terminal-colors');
const { parseKeyInput } = require('./cli-key-parser');
const { tokenizeArguments, parseUsageFlags } = require('./cli-argument-parser');

class TUISession {
    constructor(socket, vaultId) {
        // Connection
        this.socket = socket;
        this.currentVaultId = vaultId;
        this.currentVaultName = "";

        // Input state
        this.inputBuffer = "";
        this.cursorPos = 0;

        // History
        this.history = [];
        this.historyIndex = -1;

        // Processing lock
        this.isProcessing = false;

        // Autocomplete state
        this.inputBeforeAutocomplete = "";
        this.suggestions = [];
        this.suggestionIndex = -1;
        this.suggestionWindowStart = 0;
        this.suggestionLines = 0;

        // Reverse search (Ctrl+R) state
        this.isSearchMode = false;
        this.searchQuery = "";
        this.searchMatchIndex = 0;
        this.searchMatches = [];
        this.inputBeforeSearch = "";

        // Completion function (initialized by initCompletions)
        this.getCompletions = () => [];
        this.maxCommandLen = 0;

        // Layout
        this.totalLines = 2 + MAX_SUGGESTION_LINES + 2;
    }

    /**
     * Initializes the completion engine by fetching available commands,
     * vaults, and file lists from the running Obsidian instance.
     */
    async initCompletions(api) {
        this.currentVaultName = api.getNameForVault(this.currentVaultId) || "";
        
        let completionData = {};
        let vaultNames = [];
        let fileList = [];

        // Fetch command definitions from the vault
        try {
            let result = await api.executeCliRequest(this.currentVaultId, ["__completions"]);
            if (result && result.startsWith("{")) {
                completionData = JSON.parse(result);
            }
        } catch (e) {}

        // Fetch vault names
        try {
            vaultNames = (await api.executeCliRequest(this.currentVaultId, ["vaults"]))
                .split("\n").filter(name => name.trim());
        } catch (e) {}

        // Fetch file list (limited to 1000)
        try {
            let result = await api.executeCliRequest(this.currentVaultId, ["__files", "limit=1000"]);
            if (result && result.startsWith("[")) {
                fileList = JSON.parse(result);
            }
        } catch (e) {}

        // Build lookup tables for commands, flags, descriptions, enum values
        let commandFlags = {};      // command → [flag names]
        let flagDescriptions = {};  // command → { flag → description }
        let flagEnumValues = {};    // command → { flag → [possible values] }
        let commandDescriptions = {};

        for (let [cmdName, cmdDef] of Object.entries(completionData)) {
            commandDescriptions[cmdName] = cmdDef.description;
            if (cmdDef.flags) {
                let flags = [];
                let descs = {};
                let enums = {};
                for (let [flagName, flagDef] of Object.entries(cmdDef.flags)) {
                    let key = flagDef.value ? `${flagName}=` : flagName;
                    flags.push(key);
                    descs[key] = flagDef.description;
                    if (flagDef.value && flagDef.value.includes("|")) {
                        enums[flagName] = flagDef.value.split("|");
                    }
                }
                commandFlags[cmdName] = flags;
                flagDescriptions[cmdName] = descs;
                flagEnumValues[cmdName] = enums;
            } else {
                commandFlags[cmdName] = parseUsageFlags(cmdDef.usage);
            }
        }

        // Add built-in TUI commands
        commandDescriptions.exit = "Exit the CLI";
        commandDescriptions.quit = "Exit the CLI";
        commandDescriptions["vault:open"] = "Switch to a different vault";

        let allCommands = Object.keys(completionData).concat(["exit", "quit", "vault:open"]).sort();
        this.maxCommandLen = Math.max(...allCommands.map(c => c.length));

        // Build the completion function
        this.getCompletions = (input) => {
            let trimmed = input.trim();
            let parts = trimmed.split(/\s+/);
            let hasTrailingSpace = input.length > 0 && input[input.length - 1] === " ";
            let currentWord = hasTrailingSpace ? "" : (parts[parts.length - 1] || "");

            // Phase 1: Command name completion
            if (parts.length <= 1 && !hasTrailingSpace) {
                let lower = currentWord.toLowerCase();
                let prefixMatches = allCommands.filter(cmd => cmd.toLowerCase().startsWith(lower));
                let descMatches = lower.length > 0 ? allCommands.filter(cmd => {
                    return !cmd.toLowerCase().startsWith(lower) &&
                           commandDescriptions[cmd]?.toLowerCase().includes(lower);
                }) : [];
                return [...prefixMatches, ...descMatches].map(cmd => ({
                    text: cmd,
                    description: commandDescriptions[cmd]
                }));
            }

            // Phase 2: Command-specific flag/argument completion
            let command = parts[0];
            let prefix = hasTrailingSpace ? trimmed : parts.slice(0, -1).join(" ");

            // Special case: vault:open
            if (command === "vault:open" && parts.length <= 2) {
                return vaultNames
                    .filter(name => name.toLowerCase().startsWith(currentWord.toLowerCase()))
                    .map(name => ({
                        text: "vault:open " + (name.includes(" ") ? `"${name}"` : name),
                        description: "Open vault"
                    }));
            }

            let flags = commandFlags[command];
            let descs = flagDescriptions[command] || {};
            let enums = flagEnumValues[command] || {};

            // If current word contains '=', complete the value
            if (currentWord.includes("=")) {
                let eqIdx = currentWord.indexOf("=");
                let flagName = currentWord.substring(0, eqIdx);
                let valuePrefix = currentWord.substring(eqIdx + 1).toLowerCase();
                let base = hasTrailingSpace ? trimmed : parts.slice(0, -1).join(" ");

                // File/path completion
                if (flagName === "file" || flagName === "path") {
                    let ext = command.startsWith("base:") ? ".base" : null;
                    return fileList
                        .filter(f => (!ext || f.endsWith(ext)) && f.toLowerCase().includes(valuePrefix))
                        .slice(0, 20)
                        .map(f => {
                            let display = flagName === "file" && f.endsWith(".md") ? f.slice(0, -3) : f;
                            return {
                                text: base + (base ? " " : "") + flagName + `="${display}"`,
                                description: ""
                            };
                        });
                }

                // Folder completion
                if (flagName === "folder") {
                    let folders = new Set();
                    for (let f of fileList) {
                        let sep = f.lastIndexOf("/");
                        if (sep > 0) folders.add(f.substring(0, sep));
                    }
                    return Array.from(folders)
                        .filter(f => f.toLowerCase().includes(valuePrefix))
                        .slice(0, 20)
                        .map(f => ({
                            text: base + (base ? " " : "") + flagName + `="${f}"`,
                            description: ""
                        }));
                }

                // Enum value completion
                let enumValues = enums[flagName];
                if (enumValues) {
                    return enumValues
                        .filter(v => v.toLowerCase().startsWith(valuePrefix))
                        .map(v => ({
                            text: base + (base ? " " : "") + flagName + "=" + v,
                            description: descs[flagName + "="]
                        }));
                }
            }

            // Flag name completion
            if (flags && flags.length > 0) {
                let usedFlags = parts.slice(1).map(p => {
                    let eq = p.indexOf("=");
                    return eq >= 0 ? p.substring(0, eq + 1) : p;
                });
                return flags
                    .filter(f => {
                        let key = f.indexOf("=") >= 0 ? f.substring(0, f.indexOf("=") + 1) : f;
                        return f.startsWith(currentWord) && !usedFlags.includes(key);
                    })
                    .map(f => ({
                        text: prefix + " " + f,
                        description: descs[f]
                    }));
            }

            return [];
        };
    }

    // --- Display methods ---

    writeWelcome(version) {
        this.socket.write("\x1B[2J\x1B[H"); // Clear screen
        this.socket.write(`${os.EOL}  ${ANSI.bold}${ANSI.purple}${renderLogo(version)}\n${ANSI.reset}${os.EOL}`);
        if (this.currentVaultName) {
            this.socket.write(`  ${ANSI.bold}${this.currentVaultName}${ANSI.reset}${os.EOL}`);
        }
        this.socket.write(`  ${ANSI.faint}Tab to autocomplete, \u2191/\u2193 for history, Ctrl+C to quit${ANSI.reset}${os.EOL}${os.EOL}`);
    }

    writeDivider() {
        this.socket.write(`${os.EOL}${ANSI.clearLine}${ANSI.faint}${"\u2500".repeat(DIVIDER_WIDTH)}${ANSI.reset}${os.EOL}`);
    }

    writePrompt(text) {
        if (this.isSearchMode) {
            let match = this.searchMatches[this.searchMatchIndex] || "";
            let display = match;
            if (match && this.searchQuery) {
                let idx = match.toLowerCase().indexOf(this.searchQuery.toLowerCase());
                if (idx >= 0) {
                    let before = match.slice(0, idx);
                    let highlight = match.slice(idx, idx + this.searchQuery.length);
                    let after = match.slice(idx + this.searchQuery.length);
                    display = `${before}${ANSI.yellow}${highlight}${ANSI.reset}${after}`;
                }
            }
            this.socket.write(`${ANSI.clearLine}${ANSI.purple}>${ANSI.reset} ${display || text}`);
            this.socket.write(`${os.EOL}${ANSI.clearLine}${ANSI.purple}search:${ANSI.reset} ${this.searchQuery}${this.searchMatches.length === 0 && this.searchQuery ? `${ANSI.faint} (no match)${ANSI.reset}` : ""}`);
        } else {
            this.socket.write(`${ANSI.clearLine}${ANSI.purple}>${ANSI.reset} ${text}`);
        }
    }

    writeSuggestions() {
        let { suggestions, suggestionIndex, suggestionWindowStart, maxCommandLen } = this;

        // Scroll window to keep selection visible
        if (suggestionIndex >= 0) {
            if (suggestionIndex < suggestionWindowStart) {
                this.suggestionWindowStart = suggestionIndex;
            } else if (suggestionIndex >= suggestionWindowStart + MAX_SUGGESTION_LINES) {
                this.suggestionWindowStart = suggestionIndex - MAX_SUGGESTION_LINES + 1;
            }
        }

        let end = Math.min(this.suggestionWindowStart + MAX_SUGGESTION_LINES, suggestions.length);
        let maxWidth = Math.max(maxCommandLen, ...suggestions.map(s => s.text.length));

        for (let i = 0; i < MAX_SUGGESTION_LINES; i++) {
            this.socket.write(os.EOL);
            let idx = this.suggestionWindowStart + i;
            if (idx < suggestions.length) {
                let { text, description } = suggestions[idx];
                let padded = description ? text.padEnd(maxWidth + 2) : text;
                let desc = description ? `${ANSI.faint}${description}${ANSI.reset}` : "";
                if (idx === suggestionIndex) {
                    this.socket.write(`  ${ANSI.bold}${ANSI.purple}> ${padded}${ANSI.reset}${desc}`);
                } else {
                    this.socket.write(`    ${ANSI.muted}${padded}${ANSI.reset}${desc}`);
                }
            }
            this.socket.write("\x1B[K"); // Clear to end of line
        }

        let remaining = suggestions.length - end;
        this.socket.write(os.EOL);
        if (remaining > 0) {
            this.socket.write(`    ${ANSI.faint}${remaining} more${ANSI.reset}`);
        }
        this.socket.write("\x1B[K");
        this.socket.write(os.EOL + "\x1B[K");
        this.suggestionLines = MAX_SUGGESTION_LINES + 2;
    }

    writeOutput(text, color) {
        let formatted = color ? `${color}${text}${ANSI.reset}` : text;
        this.socket.write(`${os.EOL}${os.EOL}${formatted}${os.EOL}`);
    }

    // --- Cursor & display management ---

    clearSuggestionDisplay() {
        if (this.suggestionLines > 0) {
            for (let i = 0; i < this.suggestionLines; i++) this.socket.write("\x1B[B");
            for (let i = 0; i < this.suggestionLines; i++) this.socket.write("\x1B[2K\x1B[A");
            this.suggestionLines = 0;
        }
    }

    reserveSpace() {
        for (let i = 0; i < this.totalLines; i++) this.socket.write(os.EOL);
        this.socket.write(`\x1B[${this.totalLines}A`);
    }

    moveCursorLeft() { this.socket.write("\x1B[D"); }
    moveCursorRight() { this.socket.write("\x1B[C"); }

    positionCursor() {
        let col = this.isSearchMode ? 8 + this.searchQuery.length : 2 + this.cursorPos;
        let rows = this.suggestionLines;
        if (rows > 0) this.socket.write(`\x1B[${rows}A`);
        this.socket.write(`\r\x1B[${col}C`);
    }

    clearAndEnd() {
        this.socket.write(os.EOL);
        this.socket.end();
    }

    prepareForOutput() {
        this.socket.write("\x1B[A\x1B[2K\x1B[A\x1B[2K");
        this.socket.write(os.EOL + os.EOL);
    }

    clearSuggestions() {
        this.clearSuggestionDisplay();
        this.suggestions = [];
        this.suggestionIndex = -1;
        this.suggestionWindowStart = 0;
    }

    updateSuggestions() {
        this.suggestions = this.getCompletions(this.inputBuffer);
        this.suggestionIndex = -1;
        this.suggestionWindowStart = 0;
        this.clearSuggestionDisplay();
        this.writePrompt(this.inputBuffer);
        this.writeSuggestions();
        this.positionCursor();
    }

    updateSearchMatches() {
        let query = this.searchQuery.toLowerCase();
        this.searchMatches = this.history.filter(h => h.toLowerCase().includes(query));
        this.searchMatchIndex = 0;
    }

    redraw() {
        if (this.isSearchMode) {
            this.socket.write("\x1B[A\x1B[2K\r");
            this.writePrompt(this.inputBuffer);
            this.socket.write(`\r\x1B[${8 + this.searchQuery.length}C`);
        } else {
            this.clearSuggestionDisplay();
            this.writePrompt(this.inputBuffer);
            this.writeSuggestions();
            this.positionCursor();
        }
    }

    resetPrompt() {
        this.inputBuffer = "";
        this.cursorPos = 0;
        this.historyIndex = -1;
        this.reserveSpace();
        this.writeDivider();
        this.updateSuggestions();
    }

    /**
     * Processes a key event and returns an action:
     * - { type: "continue" } - keep reading input
     * - { type: "exit" } - user wants to quit
     * - { type: "execute", command: string } - user submitted a command
     */
    handleKeyInput(key) {
        // Ctrl+C / Ctrl+D → exit
        if (key.ctrl && (key.name === "c" || key.name === "d")) {
            this.clearSuggestionDisplay();
            this.suggestions = [];
            this.suggestionIndex = -1;
            this.suggestionWindowStart = 0;
            return { type: "exit" };
        }

        // Ctrl+L → clear screen
        if (key.ctrl && key.name === "l") {
            this.socket.write("\x1B[2J\x1B[H");
            this.reserveSpace();
            this.writeDivider();
            this.redraw();
            return { type: "continue" };
        }

        // Ctrl+R → reverse search
        if (key.ctrl && key.name === "r") {
            if (this.isSearchMode) {
                if (this.searchMatches.length > 0) {
                    this.searchMatchIndex = (this.searchMatchIndex + 1) % this.searchMatches.length;
                }
                this.redraw();
            } else {
                this.isSearchMode = true;
                this.inputBeforeSearch = this.inputBuffer;
                this.searchQuery = "";
                this.searchMatchIndex = 0;
                this.searchMatches = this.history.slice();
                this.clearSuggestionDisplay();
                this.writePrompt(this.inputBuffer);
                this.socket.write(`\r\x1B[${8 + this.searchQuery.length}C`);
            }
            return { type: "continue" };
        }

        // --- Search mode key handling ---
        if (this.isSearchMode) {
            if (key.name === "escape") {
                this.isSearchMode = false;
                this.inputBuffer = this.inputBeforeSearch;
                this.cursorPos = this.inputBuffer.length;
                this.socket.write("\x1B[2K\x1B[A\x1B[2K\r");
                this.updateSuggestions();
                return { type: "continue" };
            }
            if (key.name === "return") {
                this.isSearchMode = false;
                let match = this.searchMatches[this.searchMatchIndex];
                if (match) {
                    this.inputBuffer = match.endsWith(" ") ? match : match + " ";
                    this.cursorPos = this.inputBuffer.length;
                } else {
                    this.inputBuffer = this.inputBeforeSearch;
                    this.cursorPos = this.inputBuffer.length;
                }
                this.socket.write("\x1B[2K\x1B[A\x1B[2K\r");
                this.updateSuggestions();
                return { type: "continue" };
            }
            if (key.name === "backspace") {
                if (this.searchQuery.length > 0) {
                    this.searchQuery = this.searchQuery.slice(0, -1);
                    this.updateSearchMatches();
                    this.redraw();
                }
                return { type: "continue" };
            }
            if (key.name.length === 1 && !key.ctrl) {
                this.searchQuery += key.name;
                this.updateSearchMatches();
                this.redraw();
                return { type: "continue" };
            }
            return { type: "continue" };
        }

        // --- Normal mode key handling ---
        // (Tab, Escape, Return, Arrow keys, Emacs bindings, character input)
        // [Full implementation in prettified main.js lines 523-627]
        // Abbreviated here for readability - see main.prettified.js for full logic

        if (key.name === "escape") {
            if (this.inputBeforeAutocomplete) {
                this.inputBuffer = this.inputBeforeAutocomplete;
                this.cursorPos = this.inputBuffer.length;
                this.inputBeforeAutocomplete = "";
                this.updateSuggestions();
            } else if (this.suggestionIndex >= 0) {
                this.suggestionIndex = -1;
                this.redraw();
            } else if (this.inputBuffer) {
                this.inputBuffer = "";
                this.cursorPos = 0;
                this.historyIndex = -1;
                this.updateSuggestions();
            }
            return { type: "continue" };
        }

        if (key.name === "return") {
            if (!this.inputBuffer.trim() && this.suggestionIndex < 0) {
                return { type: "continue" };
            }
            if (this.suggestionIndex >= 0 && this.suggestions[this.suggestionIndex]) {
                let suggestion = this.suggestions[this.suggestionIndex].text;
                if (suggestion !== this.inputBuffer.trim() || !this.inputBuffer.endsWith(" ")) {
                    this.inputBeforeAutocomplete = this.inputBuffer;
                    this.inputBuffer = suggestion.endsWith("=") ? suggestion : suggestion + " ";
                    this.cursorPos = this.inputBuffer.length;
                    this.updateSuggestions();
                    return { type: "continue" };
                }
            }
            let command = this.inputBuffer.trim();
            this.clearSuggestions();
            this.prepareForOutput();
            return { type: "execute", command };
        }

        // Character input
        if (key.name.length === 1 && !key.ctrl && !key.alt) {
            this.inputBuffer = this.inputBuffer.slice(0, this.cursorPos) + key.name + this.inputBuffer.slice(this.cursorPos);
            this.cursorPos++;
            this.updateSuggestions();
            return { type: "continue" };
        }

        return { type: "continue" };
    }

    /**
     * Executes a parsed command string against the Obsidian vault API.
     */
    async executeCommand(commandStr, api) {
        let { executeCliRequest, getIdForVault, openVaultById } = api;

        if (commandStr === "exit" || commandStr === "quit") {
            this.clearAndEnd();
            return;
        }

        // Add to history (avoid duplicates at top)
        if (this.history[0] !== commandStr) {
            this.history.unshift(commandStr);
        }

        let tokens = tokenizeArguments(commandStr);

        // Guard: user typed "obsidian ..." inside the TUI
        if (tokens[0] === "obsidian") {
            let msg = 'You are already in the Obsidian TUI. Commands can be typed directly, e.g. "help"';
            if (tokens.length > 1) {
                msg += `\nDid you mean: ${tokens.slice(1).join(" ")}`;
            }
            this.writeOutput(msg, ANSI.yellow);
            return;
        }

        // vault:open <name> - switch vault
        if (tokens[0] === "vault:open") {
            if (!tokens[1]) {
                this.writeOutput("Missing vault name: vault:open <vault-name>", ANSI.red);
                return;
            }
            let name = tokens[1];
            let id = getIdForVault(name);
            if (!id) {
                this.writeOutput(`Vault not found: ${name}`, ANSI.red);
                return;
            }
            openVaultById(id);
            this.currentVaultId = id;
            this.currentVaultName = name;
            this.writeOutput(`Opened vault: ${name}`);
            return;
        }

        // Check for vault= prefix override
        let vaultOverride = tokens[0]?.startsWith("vault=") ? tokens[0] : null;
        let targetVaultId = vaultOverride ? getIdForVault(vaultOverride.slice(6)) : this.currentVaultId;
        let args = vaultOverride ? tokens.slice(1) : tokens;

        let result = await executeCliRequest(targetVaultId || this.currentVaultId, args);
        if (result) this.writeOutput(result);
    }
}

/**
 * Starts the interactive TUI session.
 * Called when `obsidian` is invoked from a TTY without specific command arguments.
 * 
 * @param {net.Socket} socket - The socket connection to the main Obsidian process
 * @param {string} vaultId - The ID of the default vault to target
 * @param {object} api - API object with executeCliRequest, getIdForVault, etc.
 */
async function startTUISession(socket, vaultId, api) {
    let session = new TUISession(socket, vaultId);
    await session.initCompletions(api);
    session.writeWelcome(api.version);
    session.reserveSpace();
    session.writeDivider();
    session.updateSuggestions();

    let cleanup = () => {
        socket.removeListener("data", onData);
        socket.removeListener("error", onError);
        socket.removeListener("close", onClose);
    };

    let onClose = () => cleanup();
    let onError = () => { cleanup(); socket.destroy(); };

    let onData = async (rawInput) => {
        if (session.isProcessing) return;
        let key = parseKeyInput(rawInput);
        let action = session.handleKeyInput(key);

        if (action.type === "exit") {
            cleanup();
            session.clearAndEnd();
            return;
        }

        if (action.type === "execute") {
            session.isProcessing = true;
            try {
                await session.executeCommand(action.command, api);
            } catch (err) {
                session.writeOutput(
                    `Error: ${err instanceof Error ? err.message : String(err)}`,
                    ANSI.red
                );
            } finally {
                session.isProcessing = false;
            }
            if (socket.destroyed) {
                cleanup();
                return;
            }
            session.resetPrompt();
        }
    };

    socket.on("data", onData);
    socket.on("error", onError);
    socket.on("close", onClose);
}

module.exports = { TUISession, startTUISession };
