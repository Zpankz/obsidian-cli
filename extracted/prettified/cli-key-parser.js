/**
 * Obsidian CLI - Key Input Parser
 * Extracted from obsidian-1.12.0.asar/main.js
 * 
 * Parses raw terminal byte sequences into structured key event objects.
 * Handles arrow keys, control sequences, alt combos, and printable characters.
 */

/**
 * Parses a raw terminal input buffer into a key event object.
 * @param {Buffer} rawInput - Raw input from the terminal
 * @returns {{ name: string, ctrl?: boolean, alt?: boolean }} Parsed key event
 */
function parseKeyInput(rawInput) {
    let str = rawInput.toString();

    // Arrow keys
    if (str === "\x1B[A") return { name: "up" };
    if (str === "\x1B[B") return { name: "down" };
    if (str === "\x1B[C") return { name: "right" };
    if (str === "\x1B[D") return { name: "left" };

    // Special keys
    if (str === "\x1B[3~") return { name: "delete" };
    if (str === "\x1B[Z") return { name: "shift-tab" };
    if (str === "\r") return { name: "return" };
    if (str === "\t") return { name: "tab" };
    if (str === "\x7F" || str === "\b") return { name: "backspace" };

    // Ctrl+key combinations (ASCII control chars)
    if (str === "\x01") return { name: "a", ctrl: true };
    if (str === "\x02") return { name: "b", ctrl: true };
    if (str === "\x03") return { name: "c", ctrl: true };
    if (str === "\x04") return { name: "d", ctrl: true };
    if (str === "\x05") return { name: "e", ctrl: true };
    if (str === "\x06") return { name: "f", ctrl: true };
    if (str === "\x0B") return { name: "k", ctrl: true };  // Ctrl+K
    if (str === "\x0C") return { name: "l", ctrl: true };  // Ctrl+L
    if (str === "\x0E") return { name: "n", ctrl: true };
    if (str === "\x10") return { name: "p", ctrl: true };
    if (str === "\x12") return { name: "r", ctrl: true };
    if (str === "\x15") return { name: "u", ctrl: true };
    if (str === "\x17") return { name: "w", ctrl: true };

    // Alt+key combinations
    if (str === "\x1Bb") return { name: "b", alt: true };
    if (str === "\x1Bf") return { name: "f", alt: true };
    if (str === "\x1B\x7F" || str === "\x1B\b") return { name: "backspace", alt: true };

    // Escape
    if (str === "\x1B" || str === "\x1B\x1B" || str === "\x1B[") return { name: "escape" };

    // Printable character fallback
    return { name: str };
}

module.exports = { parseKeyInput };
