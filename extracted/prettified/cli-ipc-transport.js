/**
 * Obsidian CLI - IPC Transport Layer
 * Extracted from obsidian-1.12.0.asar/main.js
 * 
 * Handles the socket-based IPC between CLI invocations and the running
 * Obsidian Electron process.
 * 
 * ## Architecture
 * 
 * When `obsidian <command>` is invoked from the terminal:
 * 
 * 1. The new process tries `app.requestSingleInstanceLock()` with its argv
 *    and a random socket endpoint path.
 * 
 * 2. If another Obsidian instance is already running (lock denied):
 *    - The new process creates a TCP/Unix socket server at the endpoint
 *    - The main instance receives the `second-instance` event with the data
 *    - The main instance connects to the socket
 *    - For TTY mode: stdin is piped to socket, socket piped to stdout
 *    - For non-TTY mode: command output is written to socket, then closed
 * 
 * 3. The main instance executes CLI commands by running JavaScript in the
 *    vault's BrowserWindow via `webContents.executeJavaScript()`, calling
 *    `window.handleCli(argv)` in the renderer process.
 * 
 * ## Socket Endpoint Naming
 * - macOS/Linux: `$TMPDIR/<random16hex>.sock` (Unix domain socket)
 * - Windows: `\\.\pipe\<random16hex>` (named pipe)
 *   - Windows also supports a `session=<id>` argv prefix for session reuse
 * 
 * ## CLI Execution Flow (main instance side)
 * 
 *   executeCliRequest(vaultId, argv)
 *     → opens/focuses the vault BrowserWindow (without stealing focus)
 *     → injects JS: `window.handleCli(argv)` or queues to `window.cliQueue`
 *     → returns the string result or error message
 */

const net = require('net');
const os = require('os');
const path = require('path');

/**
 * Generates a random hex string of the specified length.
 * Used for socket endpoint naming and vault IDs.
 * @param {number} length
 * @returns {string}
 */
function randomHex(length) {
    let chars = [];
    for (let i = 0; i < length; i++) {
        chars.push((Math.random() * 16 | 0).toString(16));
    }
    return chars.join("");
}

/**
 * Computes the socket endpoint path for CLI IPC.
 * @param {string} sessionId - Random 16-char hex session identifier
 * @returns {string} Platform-appropriate socket path
 */
function getSocketEndpoint(sessionId) {
    if (process.platform === "win32") {
        return `\\\\.\\pipe\\${sessionId}`;
    }
    return path.join(os.tmpdir(), `${sessionId}.sock`);
}

/**
 * Creates a socket server for the secondary CLI process.
 * This is used when Obsidian is already running and a new CLI invocation
 * needs to communicate with it.
 * 
 * The server accepts a single connection, pipes stdin/stdout through it,
 * and exits when the connection closes.
 * 
 * @param {string} endpoint - Socket path to listen on
 * @param {boolean} isTTY - Whether the terminal supports raw mode
 * @returns {net.Server}
 */
function createCliSocketServer(endpoint, isTTY) {
    const server = net.createServer((socket) => {
        socket.setNoDelay(true);

        if (isTTY) {
            process.stdin.setRawMode(true);
        }

        // Bidirectional pipe: stdin → socket → stdout
        process.stdin.pipe(socket);
        socket.pipe(process.stdout);

        socket.on("end", async () => {
            // Clean up Unix socket file
            if (process.platform !== "win32") {
                try {
                    require("fs").unlinkSync(endpoint);
                } catch (e) {}
            }
            // Wait for stdout to drain before exiting
            await new Promise(resolve => {
                process.stdout.writableLength > 0
                    ? process.stdout.once("drain", resolve)
                    : process.nextTick(resolve);
            });
            process.exit(0);
        });

        socket.on("error", () => {
            server.close(() => process.exit(1));
        });

        server.close(); // Stop accepting new connections
    });

    server.listen(endpoint);
    return server;
}

/**
 * Connects to a CLI socket server from the main Obsidian process.
 * Retries connection until timeout (2 seconds).
 * 
 * @param {string} endpoint - Socket path to connect to
 * @returns {Promise<net.Socket|null>}
 */
async function connectToCliSocket(endpoint) {
    const deadline = Date.now() + 2000;

    return new Promise((resolve) => {
        const tryConnect = () => {
            const socket = net.createConnection(endpoint);
            socket.setNoDelay(true);

            socket.once("connect", () => resolve(socket));
            socket.once("error", () => {
                socket.destroy();
                if (Date.now() > deadline) {
                    console.error("Failed to process command line call, timed out.");
                    resolve(null);
                    return;
                }
                setTimeout(tryConnect, 10);
            });
        };
        tryConnect();
    });
}

/**
 * Executes a CLI request by injecting JavaScript into a vault's BrowserWindow.
 * This is the bridge between the CLI and the Obsidian renderer process.
 * 
 * The renderer exposes `window.handleCli(argv)` which processes commands
 * and returns string results. If the handler isn't ready yet, commands
 * are queued via `window.cliQueue`.
 * 
 * @param {string} vaultId - Target vault ID
 * @param {string[]} argv - CLI arguments
 * @param {object} context - { vaults, openVault, cliEnabled }
 * @returns {Promise<string>} Command output
 */
async function executeCliRequest(vaultId, argv, context) {
    if (!context.cliEnabled) {
        return "Command line interface is not enabled. Please turn it on in Settings > General > Advanced.";
    }
    if (!vaultId || !context.vaults[vaultId]) {
        return "No vault found.";
    }

    const win = context.openVault(vaultId, /* focus= */ false);

    try {
        return await win.webContents.executeJavaScript(`
            new Promise((resolve, reject) => {
                let argv = ${JSON.stringify(argv)};
                if (window.handleCli) {
                    Promise.resolve(window.handleCli(argv)).then(resolve, reject);
                } else {
                    window.cliQueue = window.cliQueue || [];
                    window.cliQueue.push({ argv, resolve, reject });
                }
            })
        `);
    } catch (err) {
        return typeof err === "string" ? "Error: " + err : String(err);
    }
}

module.exports = {
    randomHex,
    getSocketEndpoint,
    createCliSocketServer,
    connectToCliSocket,
    executeCliRequest
};
