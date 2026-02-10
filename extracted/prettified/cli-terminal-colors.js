/**
 * Obsidian CLI - Terminal Colors & Constants
 * Extracted from obsidian-1.12.0.asar/main.js
 * 
 * ANSI escape codes used by the interactive TUI and CLI output formatting.
 */

const os = require('os');

const ANSI = {
    reset: "\x1B[0m",
    bold: "\x1B[1m",
    faint: "\x1B[2m",
    muted: "\x1B[38;5;102m",
    green: "\x1B[32m",
    yellow: "\x1B[33m",
    blue: "\x1B[34m",
    purple: "\x1B[38;5;135m",
    cyan: "\x1B[36m",
    red: "\x1B[31m",
    clearLine: "\x1B[2K\r"
};

// Maximum number of suggestion lines visible in the TUI dropdown
const MAX_SUGGESTION_LINES = 10;

// Width of the horizontal divider in the TUI
const DIVIDER_WIDTH = 54;

/**
 * Renders the Obsidian ASCII art logo with version string.
 * @param {string} version - The version string to display
 * @returns {string} Multi-line ASCII art logo
 */
function renderLogo(version) {
    return `       \u2597\u2584\u259F\u2588\u2588
       \u2584\u2588\u2588\u2588\u2588\u2588\u259B \u2588\u2584
      \u2590\u2588\u2588\u2588\u2588\u2588\u259B \u259F\u2588\u2588\u2588
      \u2590\u2588\u2588\u2588\u2588\u259B \u259F\u2588\u2588\u2588\u2588\u258C
     \u2597 \u259C\u2588\u2588\u2588\u258E\u2590\u2588\u2588\u2588\u2588\u2588\u258C
    \u2597\u2588\u2599 \u259C\u2588\u2588\u258E\u2590\u2588\u2588\u2588\u2588\u2588\u2588
   \u2597\u2588\u2588\u2588\u2599 \u259C\u2588\u2599 \u259C\u2588\u2588\u2588\u2588\u2588\u2599
  \u2597\u2588\u2588\u2588\u2588\u2588\u2599 \u2584\u2584\u2584\u2584\u2583\u2594\u2580\u2588\u2588\u2588\u2599
  \u259D\u2588\u2588\u2588\u2588\u2588\u2588 \u2588\u2588\u2588\u2588\u2588\u2588\u2584 \u259C\u2588\u2598
   \u2580\u2588\u2588\u2588\u2588\u259B \u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2599 \u2598
     \u2580\u2588\u259B \u259F\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u2588\u258C  Obsidian ${version}
        \u259D\u2580\u2580\u2580\u2580\u2588\u2588\u2588\u2588\u2580`;
}

module.exports = { ANSI, MAX_SUGGESTION_LINES, DIVIDER_WIDTH, renderLogo };
