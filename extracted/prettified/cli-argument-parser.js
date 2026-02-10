/**
 * Obsidian CLI - Argument Parser / Tokenizer
 * Extracted from obsidian-1.12.0.asar/main.js
 * 
 * Tokenizes CLI input strings, handling quoted strings, escape sequences,
 * and whitespace-delimited arguments.
 */

/**
 * Tokenizes a CLI input string into an array of arguments.
 * Handles single/double quotes and backslash escapes.
 * 
 * Examples:
 *   'read file="My Notes/test.md"'  → ['read', 'file=My Notes/test.md']
 *   "append content='hello world'"   → ['append', "content=hello world"]
 * 
 * @param {string} input - Raw input string from the TUI or CLI
 * @returns {string[]} Array of parsed argument tokens
 */
function tokenizeArguments(input) {
    let tokens = [];
    let current = "";
    let quoteChar = null;
    let escaped = false;

    for (let char of input) {
        if (escaped) {
            current += char;
            escaped = false;
            continue;
        }
        if (char === "\\") {
            escaped = true;
            continue;
        }
        if (quoteChar) {
            if (char === quoteChar) {
                quoteChar = null;
            } else {
                current += char;
            }
            continue;
        }
        if (char === '"' || char === "'") {
            quoteChar = char;
            continue;
        }
        if (char === " " || char === "\t") {
            if (current) {
                tokens.push(current);
                current = "";
            }
            continue;
        }
        current += char;
    }
    if (current) tokens.push(current);
    return tokens;
}

/**
 * Parses a usage string pattern to extract completion flag names.
 * Used to build autocomplete suggestions from command definitions.
 * 
 * Example: "[file=<name>] [path=<path>] [total]" → ["file=", "path=", "total"]
 * 
 * @param {string} usageString - Command usage pattern string
 * @returns {string[]} Array of flag names (with '=' suffix if they take values)
 */
function parseUsageFlags(usageString) {
    if (!usageString) return [];
    let flags = [];
    let matches = Array.from(usageString.matchAll(/\[?(\w+(?:=(?:<[^>]+>)?)?)\]?/g));
    for (let match of matches) {
        let flag = match[1];
        if (flag.startsWith("<")) continue; // Skip pure value placeholders
        if (flag.includes("=")) {
            flag = flag.replace(/<[^>]+>/, ""); // Remove value placeholder
        }
        flags.push(flag);
    }
    return flags;
}

module.exports = { tokenizeArguments, parseUsageFlags };
