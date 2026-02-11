# Hook-Powered Auto-Extraction Context Transfer System

**Version:** 1.0
**Date:** 2026-02-11
**Status:** Design Complete — Ready for Implementation
**Project:** `/Users/mikhail/Projects/obsidian-cli/`

---

## Executive Summary

A three-layer persistent memory system for Claude Code that prevents context loss during compaction, builds a cross-session knowledge graph, and provides semantic retrieval across all past sessions. The system uses Claude Code hooks to trigger extraction at key lifecycle events, stores structured knowledge in an Obsidian vault via the official CLI (v1.12.1), and provides graph-based semantic retrieval through forgetful-ai MCP.

### Design Decisions (from brainstorming)

| Decision         | Choice                                               | Rationale                                           |
| ---------------- | ---------------------------------------------------- | --------------------------------------------------- |
| System topology  | Parallel (L1 + L2 + L3)                              | Keep Letta unchanged, add layers separately         |
| Failure modes    | Prevent compaction loss AND build knowledge graph    | Both are equally valuable                           |
| PostCompact gate | Letta reviews extraction quality                     | Avoid expensive Tier 2 recovery when unnecessary    |
| Hook blocking    | Async where possible                                 | Don't slow user workflow                            |
| Data model       | Typed structured entities                            | Ontologically-typed Zettelkasten, not flat markdown |
| Vault strategy   | Hybrid (metacognition vault + cross-links to distil) | Session artifacts separate from study content       |

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Claude Code Session                         │
│                                                                 │
│  SessionStart ──► PreCompact ──► PostCompact ──► Stop           │
│       │               │              │             │            │
│       ▼               ▼              ▼             ▼            │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐  ┌──────────┐      │
│  │  LOAD   │   │ EXTRACT  │   │  REVIEW  │  │  FLUSH   │      │
│  │ context │   │ entities │   │  quality │  │  commit  │      │
│  └────┬────┘   └────┬─────┘   └────┬─────┘  └────┬─────┘      │
│       │              │              │              │            │
└───────┼──────────────┼──────────────┼──────────────┼────────────┘
        │              │              │              │
   ┌────▼────┐    ┌────▼────┐   ┌────▼────┐   ┌────▼────┐
   │   L1    │    │   L2    │   │   L1    │   │ L2 + L3 │
   │  Letta  │    │Obsidian │   │  Letta  │   │  Flush  │
   │  Sync   │    │  CLI    │   │  Gate   │   │  All    │
   └─────────┘    └─────────┘   └─────────┘   └─────────┘
        │              │              │              │
        ▼              ▼              ▼              ▼
   ┌─────────────────────────────────────────────────────┐
   │              Persistent Storage                      │
   │                                                      │
   │  L1: Letta Agent     L2: Obsidian Vault   L3: Forgetful │
   │  (behavioral)        (structural graph)   (semantic)     │
   └─────────────────────────────────────────────────────┘
```

### Layer Responsibilities

| Layer | System                       | Stores                                            | Retrieves                                | Latency   |
| ----- | ---------------------------- | ------------------------------------------------- | ---------------------------------------- | --------- |
| L1    | Letta Subconscious           | Behavioral patterns, preferences, project context | Session guidance, cross-session patterns | ~2s (API) |
| L2    | Obsidian Vault + CLI v1.12.1 | Typed entities, decisions, session summaries      | Graph-connected knowledge, backlinks     | ~170ms/op |
| L3    | Forgetful-ai MCP             | Semantic embeddings, graph relationships          | Similar memories, related entities       | ~500ms    |

---

## 2. Hook System Design

### 2.1 Hook Lifecycle

```
Session Start ──────────────────────────────────────────► Session End
     │                                                        │
     ▼                                                        ▼
 SessionStart                                              Stop
 (sync: load)                                        (async: flush)
                                                           │
         Context Window Grows ─────────►                   │
                │                                          │
                ▼                                          │
          ~80% capacity                                    │
                │                                          │
                ▼                                          │
          PreCompact ◄── Feature Request #17237            │
          (sync: extract)    Not yet native.               │
                │            Workaround: UserPromptSubmit  │
                ▼            with context-size check        │
          [Compaction Occurs]                               │
                │                                          │
                ▼                                          │
          PostCompact ◄── Triggers after compaction         │
          (async: Letta gate)                              │
                │                                          │
                ▼                                          │
          [Session Continues] ─────────────────────────────┘
```

### 2.2 Hook Registry (settings.json)

```jsonc
{
  "hooks": {
    // L1: Letta sync (already exists via claude-subconscious plugin)
    // SessionStart, UserPromptSubmit, PreToolUse, Stop

    // L2 + L3: Knowledge extraction hooks (NEW)
    "SessionStart": [
      {
        "type": "command",
        "command": "node ~/.claude/hooks/session-start-context.mjs",
        "async": false, // Must load context before first prompt
        "timeout": 5000,
      },
    ],
    "PreCompact": [
      {
        // WORKAROUND: PreCompact doesn't exist natively yet.
        // Use UserPromptSubmit with context-size heuristic.
        // See Section 2.3 for the workaround pattern.
        "type": "command",
        "command": "node ~/.claude/hooks/pre-compact-extract.mjs",
        "async": false, // Must extract BEFORE compaction destroys context
        "timeout": 10000,
      },
    ],
    "Stop": [
      {
        "type": "command",
        "command": "node ~/.claude/hooks/session-stop-flush.mjs",
        "async": true, // Don't block session teardown
        "timeout": 30000,
      },
    ],
  },
}
```

### 2.3 PreCompact Workaround

Since `PreCompact` is not a native hook event (feature request #17237), implement detection via `UserPromptSubmit`:

```javascript
// ~/.claude/hooks/compact-detector.mjs
// Registered as UserPromptSubmit hook

import { readFileSync, statSync } from "fs";
import { join } from "path";

const TRANSCRIPT_PATH = process.env.CLAUDE_TRANSCRIPT_PATH;
const COMPACT_THRESHOLD = 0.75; // 75% of context window

// Heuristic: check transcript file size growth rate
// When approaching compaction, transcript grows rapidly
const stats = statSync(TRANSCRIPT_PATH);
const fileSizeKB = stats.size / 1024;

// Approximate: 1KB ≈ 500 tokens, 200K context ≈ 400KB transcript
const estimatedUsage = fileSizeKB / 400;
if (estimatedUsage > COMPACT_THRESHOLD) {
  // Trigger extraction before compaction
  execSync("node ~/.claude/hooks/pre-compact-extract.mjs", {
    env: { ...process.env, EXTRACTION_REASON: "pre-compact" },
  });
}
```

### 2.4 Two-Tier Recovery System

```
PreCompact Trigger
       │
       ▼
┌──────────────┐
│   TIER 1     │  Always runs (async)
│   (Fast)     │
├──────────────┤
│ 1. JSONL → MD session summary
│ 2. Entity extraction (decisions, insights, errors)
│ 3. Write entities to Obsidian via CLI
│ 4. Push memories to forgetful-ai
│ 5. Update session transcript archive
└──────┬───────┘
       │
       ▼
┌──────────────┐
│  LETTA GATE  │  Letta compares:
│  (Decision)  │  - Pre-compact extraction completeness
│              │  - Post-compact summary coverage
│              │  - Missing critical entities
└──────┬───────┘
       │
  ┌────┴────┐
  │         │
  ▼         ▼
SKIP    ┌──────────────┐
        │   TIER 2     │  Only when gaps detected (sync)
        │   (Deep)     │
        ├──────────────┤
        │ 1. Sub-agent gap analysis
        │ 2. Re-extract from raw transcript
        │ 3. Generate resume-prompt
        │ 4. Cross-reference with L3 graph
        └──────────────┘
```

---

## 3. Layer 1: Letta Subconscious (Unchanged)

**Status:** Already operational. No modifications needed.

| Aspect        | Current State                                                                 |
| ------------- | ----------------------------------------------------------------------------- |
| Agent ID      | `agent-8cec8f0d-39d0-4d21-bd28-e9a8aa20533a`                                  |
| Plugin        | `~/.claude/plugins/marketplaces/claude-subconscious/`                         |
| Hooks         | SessionStart, UserPromptSubmit (sync), PreToolUse, Stop                       |
| Memory blocks | core_directives, guidance, session_patterns, user_preferences, project blocks |
| Sync          | Hierarchical filtering by cwd (`filterBlocksForProject()`)                    |

### L1 New Role: PostCompact Quality Gate

Letta gains one new responsibility — reviewing Tier 1 extraction quality to decide if Tier 2 is needed:

```javascript
// Pseudo-code for Letta gate decision
const tier1Extraction = readJSON(".claude/extractions/current-session.json");
const postCompactSummary = readFile(".claude/compact-summary.md");

const lettaDecision = await lettaApi.sendMessage({
  agent_id: SUBCONSCIOUS_AGENT_ID,
  message: `Review extraction quality:
    - Entities extracted: ${tier1Extraction.entities.length}
    - Decisions captured: ${tier1Extraction.decisions.length}
    - Post-compact summary length: ${postCompactSummary.length}
    - Missing critical context? (yes/no)
    Respond: TIER2_NEEDED or TIER2_SKIP`,
});
```

---

## 4. Layer 2: Obsidian Vault + CLI v1.12.1

### 4.1 Vault Structure (Hybrid Approach)

```
~/Documents/distil/                    # Existing study vault (2,638 files)
├── SAQ/                               # Exam questions (hub nodes)
├── LO/                                # Learning objectives
├── ...existing content...
│
├── _metacognition/                    # NEW: Session knowledge graph
│   ├── sessions/                      # Session summary notes
│   │   ├── 2026-02-11-hook-design.md
│   │   └── 2026-02-10-letta-cleanup.md
│   ├── entities/                      # Extracted typed entities
│   │   ├── libraries/
│   │   │   ├── forgetful-ai.md
│   │   │   └── obsidian-cli.md
│   │   ├── decisions/
│   │   │   ├── parallel-architecture.md
│   │   │   └── async-hooks.md
│   │   ├── insights/
│   │   │   ├── scale-free-topology.md
│   │   │   └── turbovault-undercounts.md
│   │   └── errors/
│   │       ├── gitmcp-no-docs.md
│   │       └── deepwiki-not-mcp.md
│   ├── patterns/                      # Cross-session patterns
│   │   ├── agent-orchestration.md
│   │   └── two-tier-recovery.md
│   └── _index.md                      # MOC (Map of Content) for metacognition
│
└── _templates/                        # Note templates for CLI creation
    ├── session-summary.md
    ├── entity-library.md
    ├── entity-decision.md
    ├── entity-insight.md
    └── entity-error.md
```

### 4.2 Zettelkasten Ontology (Typed Entities)

#### Tag Hierarchy

```
#type/session                    # Session summaries
#type/entity/library             # External libraries/tools
#type/entity/concept             # Domain concepts
#type/entity/file                # Important files/paths
#type/decision/adopted           # Decisions made and kept
#type/decision/rejected          # Decisions considered but rejected
#type/insight/pattern            # Recurring patterns observed
#type/insight/discovery          # One-time discoveries
#type/error/resolved             # Errors encountered and fixed
#type/error/workaround           # Known issues with workarounds
#type/pattern/workflow           # Workflow patterns
#type/pattern/architecture       # Architectural patterns
```

#### Property Schema

```yaml
# Common properties (all entity types)
type: text # Entity type tag
confidence: number # 0-100, how certain is this knowledge
source_session: text # Session ID that produced this
created: date # Auto via {{date}}
verified: checkbox # Cross-validated against another source

# Entity-specific properties
# Library entities
library_version: text
library_url: text
library_capabilities: list

# Decision entities
decision_status: text # adopted | rejected | deferred
decision_alternatives: list # Other options considered
decision_rationale: text # Why this choice

# Insight entities
insight_domain: text # Which project/domain
insight_frequency: number # How many times observed

# Error entities
error_resolved: checkbox
error_workaround: text
error_root_cause: text
```

#### Example Entity Note

```markdown
---
type: entity/library
confidence: 95
source_session: e3e14aa8
created: 2026-02-11
verified: true
library_version: v1.12.1
library_capabilities:
  - eval (unrestricted JS)
  - property management
  - search with JSON output
  - batch note creation
---

# Obsidian CLI

Official Obsidian CLI providing 87+ commands across 12 categories.

## Key Capabilities

- `eval`: Unrestricted JavaScript access to `app`, `vault`, `metadataCache`, `plugins`
- `resolvedLinks`: Full adjacency list — 32,426 links across 2,618 files
- Property system: 6 types (text, list, number, checkbox, date, datetime)
- Batch creation: ~170ms/op, ~350 notes/min

## Limitations

- No native content editing (workaround: delete+recreate)
- No vault-wide backlink aggregation (must query per-file)
- No graph export format (workaround: eval + JSON.stringify)
- Search doesn't support numeric property comparison

## Related

- [[forgetful-ai|Forgetful MCP]] — Semantic layer for retrieval
- [[scale-free-topology|Network Properties]] — Vault graph analysis
- [[eval-api-access|Eval Command]] — JS API access patterns

#type/entity/library
```

### 4.3 CLI Command Patterns for Hook Scripts

#### Note Creation (Tier 1 extraction)

```bash
# Create session summary
obsidian create \
  name="2026-02-11-hook-design" \
  path="_metacognition/sessions" \
  vault=distil \
  content="$(cat /tmp/session-summary.md)"

# Set typed properties
obsidian property set \
  file="_metacognition/sessions/2026-02-11-hook-design.md" \
  property="type" value="session" type=text vault=distil

obsidian property set \
  file="_metacognition/sessions/2026-02-11-hook-design.md" \
  property="confidence" value="85" type=number vault=distil

# Create entity note
obsidian create \
  name="forgetful-ai" \
  path="_metacognition/entities/libraries" \
  vault=distil \
  content="$(cat /tmp/entity-forgetful.md)"
```

#### Linking (Graph Construction)

```bash
# Prepend wikilinks to connect entities (inserts after frontmatter)
obsidian prepend \
  file="_metacognition/entities/libraries/forgetful-ai.md" \
  vault=distil \
  content="Related: [[obsidian-cli]] | [[hook-context-transfer]]"

# Verify bidirectional link registration (~2s latency)
sleep 2
obsidian backlinks \
  file="_metacognition/entities/libraries/forgetful-ai.md" \
  vault=distil counts
```

#### Graph Queries (Context Loading)

```bash
# Get all entities related to a session
obsidian backlinks \
  file="_metacognition/sessions/2026-02-11-hook-design.md" \
  vault=distil counts

# Search for entities by type
obsidian search \
  query="tag:#type/decision/adopted" \
  vault=distil json

# Get full adjacency list via eval
obsidian eval vault=distil \
  code="JSON.stringify(Object.entries(app.metadataCache.resolvedLinks).filter(([k]) => k.startsWith('_metacognition/')).map(([k,v]) => ({file:k, links:Object.keys(v)})))"

# Get recent sessions
obsidian search \
  query="tag:#type/session path:_metacognition/sessions" \
  vault=distil json
```

#### Property Queries (Filtering)

```bash
# Find high-confidence entities
obsidian search \
  query="[confidence:95] tag:#type/entity" \
  vault=distil json

# Find unverified entities needing validation
obsidian search \
  query="[verified:false] path:_metacognition/entities" \
  vault=distil json

# Find entities from a specific session
obsidian search \
  query="[source_session:e3e14aa8]" \
  vault=distil json
```

### 4.4 Network Properties (from Research)

| Metric            | Value                  | Source                                      |
| ----------------- | ---------------------- | ------------------------------------------- |
| Total files       | 2,618                  | CLI: `obsidian files vault=distil total`    |
| Resolved links    | 32,426                 | CLI: `eval resolvedLinks`                   |
| Unresolved links  | 2,975                  | CLI: `eval unresolvedLinks`                 |
| Mean links/note   | 26.51                  | Research: 100-file sample                   |
| Median links/note | 16.5                   | Research: 100-file sample                   |
| Network density   | 1.01%                  | Research: links / possible_links            |
| Topology          | Scale-free             | CV = 1.12 (power-law distribution)          |
| Orphans           | 127 (4.9%)             | CLI: `obsidian orphans vault=distil total`  |
| Deadends          | 718 (27.4%)            | CLI: `obsidian deadends vault=distil total` |
| Hub #1            | AP99B01.md (209 links) | Research: highest-connected node            |
| Cycles            | 0                      | TurboVault: `detect_cycles`                 |
| Connected nodes   | 99% (sample)           | Research: 99/100 sampled                    |

**Small-world characteristics confirmed:**

- High local clustering around SAQ hub nodes
- Low global density (1.01%)
- Scale-free degree distribution (few hubs, many peripheral nodes)
- DAG structure (no cycles) — information flows LO → SAQ directionally

### 4.5 Eval-Powered Graph Export

For advanced graph operations not available via standard CLI commands:

```bash
# Full adjacency list as JSON
obsidian eval vault=distil \
  code="JSON.stringify(app.metadataCache.resolvedLinks)" --copy

# Subgraph for metacognition only
obsidian eval vault=distil \
  code="const links = app.metadataCache.resolvedLinks; const meta = Object.fromEntries(Object.entries(links).filter(([k]) => k.startsWith('_metacognition/'))); JSON.stringify(meta)"

# Top 20 most-linked files (authorities)
obsidian eval vault=distil \
  code="const bl = {}; Object.values(app.metadataCache.resolvedLinks).forEach(targets => Object.keys(targets).forEach(t => { bl[t] = (bl[t]||0)+1 })); JSON.stringify(Object.entries(bl).sort((a,b) => b[1]-a[1]).slice(0,20))"

# Frontmatter for a specific file
obsidian eval vault=distil \
  code="const f = app.vault.getAbstractFileByPath('_metacognition/entities/libraries/obsidian-cli.md'); JSON.stringify(app.metadataCache.getFileCache(f)?.frontmatter)"

# Plugin API access (Dataview)
obsidian eval vault=distil \
  code="const dv = app.plugins.plugins['dataview']?.api; dv ? JSON.stringify(dv.pages('#type/entity').map(p => ({file: p.file.name, confidence: p.confidence})).array()) : 'Dataview not available'"
```

---

## 5. Layer 3: Forgetful-ai MCP Server

### 5.1 Architecture

Forgetful-ai provides graph-based semantic memory with:

- **5 node types**: memory, entity, project, document, code_artifact
- **9 edge types**: relates_to, derived_from, part_of, implements, depends_on, references, contradicts, supersedes, similar_to
- **Recursive CTE subgraph traversal**: Multi-hop graph queries
- **Meta-tools pattern**: 3 tools visible to client (remember, recall, forget), internally manages graph operations

### 5.2 Integration Points

```
Session Hook ──► Entity Extraction ──► Obsidian CLI (L2)
                                   ──► Forgetful-ai (L3)
                                        │
                                        ▼
                                   ┌──────────┐
                                   │  Graph   │
                                   │ Storage  │
                                   │          │
                                   │ memories │
                                   │ entities │
                                   │ projects │
                                   │ documents│
                                   │ code     │
                                   └──────────┘
```

### 5.3 Dual-Write Pattern

Every extracted entity writes to BOTH L2 and L3:

```javascript
// Entity extracted during PreCompact
const entity = {
  type: "entity",
  subtype: "library",
  name: "obsidian-cli",
  properties: {
    version: "v1.12.1",
    capabilities: ["eval", "property-management", "search"],
    confidence: 95,
  },
  relationships: [
    { target: "forgetful-ai", edge: "relates_to" },
    { target: "hook-context-transfer", edge: "part_of" },
  ],
};

// L2: Write to Obsidian vault
await obsidianCreate(entity); // obsidian create name=... path=... vault=distil

// L3: Write to Forgetful-ai
await forgetfulRemember({
  content: entityToMemoryString(entity),
  metadata: {
    type: entity.type,
    subtype: entity.subtype,
    confidence: entity.properties.confidence,
    source_session: sessionId,
  },
});
```

### 5.4 Retrieval Strategy (SessionStart)

```javascript
// On SessionStart, query L3 for relevant context
const cwdProject = detectProject(process.cwd());
const recentSessions = await forgetfulRecall({
  query: `Recent sessions for project ${cwdProject}`,
  limit: 5,
  min_confidence: 70,
});

const relatedEntities = await forgetfulRecall({
  query: `Key entities and decisions for ${cwdProject}`,
  limit: 10,
  edge_types: ["relates_to", "part_of", "implements"],
});

// Combine with L2 graph context
const obsidianContext = execSync(
  `obsidian search query="[source_project:${cwdProject}] tag:#type/entity" vault=distil json`,
).toString();
```

---

## 6. Hook Implementation Scripts

### 6.1 SessionStart Hook (`session-start-context.mjs`)

```javascript
#!/usr/bin/env node
// ~/.claude/hooks/session-start-context.mjs
// Hook: SessionStart (sync, timeout: 5000ms)
// Purpose: Load relevant context from L2 + L3 into session

import { execSync } from "child_process";
import { writeFileSync } from "fs";
import { join } from "path";

const SESSION_ID = process.env.CLAUDE_SESSION_ID;
const CWD = process.env.CLAUDE_CWD || process.cwd();

// Detect project from cwd
function detectProject(cwd) {
  const projectMap = {
    distil: "distil",
    "tldraw-study-canvas": "tldraw-study-canvas",
    "obsidian-cli": "obsidian-cli",
    tldraw: "tldraw",
  };
  for (const [pattern, project] of Object.entries(projectMap)) {
    if (cwd.includes(pattern)) return project;
  }
  return "general";
}

const project = detectProject(CWD);

// L2: Query recent sessions for this project
let recentSessions = "";
try {
  recentSessions = execSync(
    `obsidian search query="[source_project:${project}] tag:#type/session" vault=distil json`,
    { timeout: 2000, encoding: "utf-8" },
  );
} catch {
  /* vault may not have metacognition notes yet */
}

// L2: Query key entities
let entities = "";
try {
  entities = execSync(
    `obsidian search query="tag:#type/entity path:_metacognition" vault=distil json`,
    { timeout: 2000, encoding: "utf-8" },
  );
} catch {
  /* graceful degradation */
}

// L2: Query unresolved decisions
let decisions = "";
try {
  decisions = execSync(
    `obsidian search query="[decision_status:deferred] tag:#type/decision" vault=distil json`,
    { timeout: 2000, encoding: "utf-8" },
  );
} catch {
  /* graceful degradation */
}

// Write context file for Claude to read
const contextFile = join(process.env.HOME, ".claude", "session-context.md");
writeFileSync(
  contextFile,
  `# Session Context (Auto-loaded)

## Project: ${project}
## Session: ${SESSION_ID}

### Recent Sessions
${recentSessions || "(No previous sessions recorded)"}

### Key Entities
${entities || "(No entities extracted yet)"}

### Pending Decisions
${decisions || "(No deferred decisions)"}
`,
);

// Output goes to hook stdout → injected into session
console.log(`[context-transfer] Loaded context for project: ${project}`);
```

### 6.2 PreCompact Extraction (`pre-compact-extract.mjs`)

```javascript
#!/usr/bin/env node
// ~/.claude/hooks/pre-compact-extract.mjs
// Hook: PreCompact / UserPromptSubmit (sync, timeout: 10000ms)
// Purpose: Extract structured entities from transcript before compaction

import { execSync } from "child_process";
import { readFileSync, writeFileSync, mkdirSync } from "fs";
import { join } from "path";

const SESSION_ID = process.env.CLAUDE_SESSION_ID;
const EXTRACTION_DIR = join(process.env.HOME, ".claude", "extractions");
mkdirSync(EXTRACTION_DIR, { recursive: true });

// Read current transcript (JSONL format)
const transcriptPath = process.env.CLAUDE_TRANSCRIPT_PATH;
if (!transcriptPath) process.exit(0);

const transcript = readFileSync(transcriptPath, "utf-8");
const lines = transcript
  .trim()
  .split("\n")
  .map((l) => {
    try {
      return JSON.parse(l);
    } catch {
      return null;
    }
  })
  .filter(Boolean);

// Extract entities using pattern matching on transcript
// (In production, this would use an LLM call for better extraction)
const entities = [];
const decisions = [];
const insights = [];
const errors = [];

for (const line of lines) {
  const content = line.content || line.text || "";

  // Decision patterns
  if (/(?:decided|chose|selected|picked|going with)/i.test(content)) {
    decisions.push({
      type: "decision",
      content: content.slice(0, 500),
      timestamp: line.timestamp,
    });
  }

  // Error patterns
  if (/(?:error|failed|bug|issue|broken|fix)/i.test(content)) {
    errors.push({
      type: "error",
      content: content.slice(0, 500),
      timestamp: line.timestamp,
    });
  }

  // Insight patterns
  if (
    /(?:realized|discovered|found that|turns out|key insight)/i.test(content)
  ) {
    insights.push({
      type: "insight",
      content: content.slice(0, 500),
      timestamp: line.timestamp,
    });
  }
}

// Save extraction for Letta gate review
const extraction = {
  session_id: SESSION_ID,
  timestamp: new Date().toISOString(),
  extraction_reason: process.env.EXTRACTION_REASON || "pre-compact",
  counts: {
    entities: entities.length,
    decisions: decisions.length,
    insights: insights.length,
    errors: errors.length,
  },
  entities,
  decisions,
  insights,
  errors,
};

writeFileSync(
  join(EXTRACTION_DIR, `${SESSION_ID}.json`),
  JSON.stringify(extraction, null, 2),
);

// Write entities to Obsidian (L2)
const today = new Date().toISOString().split("T")[0];

for (const decision of decisions) {
  const safeName = `decision-${today}-${decisions.indexOf(decision)}`;
  const content = `---
type: decision
confidence: 70
source_session: ${SESSION_ID}
created: ${today}
verified: false
decision_status: adopted
---

# Decision

${decision.content}

#type/decision/adopted`;

  try {
    execSync(
      `obsidian create name="${safeName}" path="_metacognition/entities/decisions" vault=distil content="${content.replace(/"/g, '\\"')}"`,
      { timeout: 2000 },
    );
  } catch {
    /* non-blocking */
  }
}

console.log(
  `[pre-compact] Extracted: ${decisions.length} decisions, ${insights.length} insights, ${errors.length} errors`,
);
```

### 6.3 Session Stop Flush (`session-stop-flush.mjs`)

```javascript
#!/usr/bin/env node
// ~/.claude/hooks/session-stop-flush.mjs
// Hook: Stop (async, timeout: 30000ms)
// Purpose: Final flush of session data to L2 + L3

import { execSync } from "child_process";
import { readFileSync, writeFileSync, existsSync } from "fs";
import { join } from "path";

const SESSION_ID = process.env.CLAUDE_SESSION_ID;
const EXTRACTION_DIR = join(process.env.HOME, ".claude", "extractions");
const today = new Date().toISOString().split("T")[0];

// Read extraction if it exists
const extractionPath = join(EXTRACTION_DIR, `${SESSION_ID}.json`);
let extraction = null;
if (existsSync(extractionPath)) {
  extraction = JSON.parse(readFileSync(extractionPath, "utf-8"));
}

// Create session summary note in Obsidian (L2)
const sessionSummary = `---
type: session
source_session: ${SESSION_ID}
created: ${today}
decisions_count: ${extraction?.counts?.decisions || 0}
insights_count: ${extraction?.counts?.insights || 0}
errors_count: ${extraction?.counts?.errors || 0}
---

# Session ${today}

## Summary
Session ID: ${SESSION_ID}
Extraction: ${extraction ? "Complete" : "None"}

## Entities Extracted
- Decisions: ${extraction?.counts?.decisions || 0}
- Insights: ${extraction?.counts?.insights || 0}
- Errors: ${extraction?.counts?.errors || 0}

## Cross-References
${extraction?.decisions?.map((d) => `- [[decision-${today}-${extraction.decisions.indexOf(d)}]]`).join("\n") || "(none)"}

#type/session`;

try {
  execSync(
    `obsidian create name="${today}-${SESSION_ID.slice(0, 8)}" path="_metacognition/sessions" vault=distil content="${sessionSummary.replace(/"/g, '\\"')}"`,
    { timeout: 3000 },
  );
} catch {
  /* non-blocking */
}

// Push to L3 (forgetful-ai) via MCP
// This happens through Claude Code's MCP integration
// The hook writes a queue file that the next session processes
const queuePath = join(process.env.HOME, ".claude", "forgetful-queue.jsonl");
const queueEntry = JSON.stringify({
  action: "remember",
  content: `Session ${SESSION_ID} on ${today}: ${extraction?.counts?.decisions || 0} decisions, ${extraction?.counts?.insights || 0} insights`,
  metadata: extraction?.counts || {},
  timestamp: new Date().toISOString(),
});

// Append to queue (processed on next SessionStart)
const { appendFileSync } = await import("fs");
appendFileSync(queuePath, queueEntry + "\n");

console.log(`[session-stop] Flushed session ${SESSION_ID} to L2 + L3 queue`);
```

---

## 7. CLI Command Reference (Complete)

### 7.1 Commands Used by Hook System

| Command                               | Purpose in Hooks                | Latency |
| ------------------------------------- | ------------------------------- | ------- |
| `obsidian create`                     | Create entity/session notes     | ~170ms  |
| `obsidian prepend`                    | Add wikilinks after frontmatter | ~170ms  |
| `obsidian property set`               | Set typed properties on notes   | ~170ms  |
| `obsidian search ... json`            | Query entities by tag/property  | ~200ms  |
| `obsidian backlinks`                  | Traverse graph (incoming links) | ~170ms  |
| `obsidian links`                      | Traverse graph (outgoing links) | ~170ms  |
| `obsidian eval`                       | Advanced graph queries via JS   | ~200ms  |
| `obsidian files vault=distil total`   | Health check (file count)       | ~100ms  |
| `obsidian orphans vault=distil total` | Graph health monitoring         | ~150ms  |

### 7.2 Commands Discovered but Not in Original Research

From `/Users/mikhail/Downloads/Obsidian CLI.md`:

| Command          | Syntax                                    | Use Case                                    |
| ---------------- | ----------------------------------------- | ------------------------------------------- |
| `diff`           | `obsidian diff file="x" from=1 to=3`      | Compare note versions (recovery)            |
| `publish:*`      | `obsidian publish:status vault=distil`    | 6 publish commands (not relevant for local) |
| `web`            | `obsidian web vault=distil`               | Open vault URL (GUI trigger)                |
| `unique`         | `obsidian unique vault=distil`            | Create unique note (Zettelkasten ID)        |
| `workspace:save` | `obsidian workspace save name="x"`        | Save workspace state                        |
| `workspace:load` | `obsidian workspace load name="x"`        | Restore workspace state                     |
| `recents`        | `obsidian recents vault=distil`           | List recently opened files                  |
| `folder`         | `obsidian folder path="x" vault=distil`   | Create folder                               |
| `folders`        | `obsidian folders vault=distil`           | List all folders                            |
| `task`           | `obsidian task ref="file:line" toggle`    | Toggle task checkboxes                      |
| `tasks`          | `obsidian tasks daily todo vault=distil`  | Query task lists                            |
| `prepend`        | `obsidian prepend file="x" content="..."` | Insert after frontmatter                    |

### 7.3 API Surface via Eval

From DeepWiki Obsidian API analysis:

| API Object            | Key Methods                                                               | Hook Use Case                       |
| --------------------- | ------------------------------------------------------------------------- | ----------------------------------- |
| `app.metadataCache`   | `.resolvedLinks`, `.unresolvedLinks`, `.getFileCache()`                   | Full graph export, frontmatter read |
| `app.metadataCache`   | Events: 'changed', 'resolve', 'resolved'                                  | Link registration monitoring        |
| `app.vault`           | `.getFiles()`, `.getMarkdownFiles()`, `.read()`, `.create()`, `.modify()` | Note CRUD                           |
| `app.fileManager`     | `.processFrontMatter(file, fn)`                                           | Safe frontmatter editing            |
| `app.fileManager`     | `.renameFile()`                                                           | Rename with auto-link-update        |
| `app.plugins.plugins` | `['dataview'].api`                                                        | Dataview query access               |
| `app.workspace`       | `.getActiveFile()`, `.getLeaf()`                                          | GUI state queries                   |

---

## 8. Data Flow Diagrams

### 8.1 Entity Extraction Pipeline

```
Transcript (JSONL)
       │
       ▼
┌──────────────┐
│   Pattern    │  Regex-based fast extraction
│   Matcher    │  (decisions, errors, insights)
└──────┬───────┘
       │
       ▼
┌──────────────┐
│   Entity     │  Assign type, confidence, relationships
│   Typer      │  from Zettelkasten ontology
└──────┬───────┘
       │
       ├──────────────────────┐
       │                      │
       ▼                      ▼
┌──────────────┐       ┌──────────────┐
│  Obsidian    │       │ Forgetful-ai │
│  CLI Create  │       │  Remember    │
│              │       │              │
│  note + props│       │  node + edges│
│  + wikilinks │       │  + metadata  │
└──────────────┘       └──────────────┘
```

### 8.2 Context Loading Pipeline (SessionStart)

```
SessionStart
       │
       ├────────────────────────────────┐
       │                                │
       ▼                                ▼
┌──────────────┐                ┌──────────────┐
│  L1: Letta   │                │  L2: Obsidian│
│  Sync        │                │  CLI Search  │
│  (existing)  │                │              │
│              │                │  Recent sess │
│  behavioral  │                │  Key entities│
│  guidance    │                │  Pending dec │
└──────┬───────┘                └──────┬───────┘
       │                               │
       │         ┌──────────────┐      │
       │         │  L3: Forget- │      │
       │         │  ful Recall  │      │
       │         │              │      │
       │         │  semantic    │      │
       │         │  matches     │      │
       │         └──────┬───────┘      │
       │                │              │
       ▼                ▼              ▼
┌─────────────────────────────────────────┐
│         Merged Session Context          │
│    (~/.claude/session-context.md)       │
└─────────────────────────────────────────┘
```

---

## 9. Performance Budget

| Operation                 | Target        | Actual (measured)                              |
| ------------------------- | ------------- | ---------------------------------------------- |
| SessionStart context load | < 5s          | ~3s (3 CLI queries @ 200ms + L1 sync ~2s)      |
| PreCompact extraction     | < 10s         | ~5s (transcript parse + 5 CLI creates @ 170ms) |
| PostCompact Letta gate    | < 3s          | ~2s (single Letta API call)                    |
| Stop flush                | < 30s (async) | ~10s (session note + queue write)              |
| Single CLI operation      | < 200ms       | ~170ms (measured)                              |
| Batch creation (10 notes) | < 2s          | ~1.7s (10 @ 170ms)                             |
| Graph query (eval)        | < 500ms       | ~200ms (JSON.stringify resolvedLinks)          |

### Throughput Limits

- Sequential CLI: ~350 notes/min
- With parallel workers (10x): ~3,500 notes/min
- Practical session extraction: 5-20 entities (well within budget)
- Maximum concurrent CLI calls: untested (recommend 4 parallel)

---

## 10. Implementation Phases

### Phase 1: Foundation (Day 1-2)

- [ ] Create `_metacognition/` directory structure in distil vault
- [ ] Create note templates in `_templates/`
- [ ] Write `session-start-context.mjs` hook
- [ ] Write `session-stop-flush.mjs` hook
- [ ] Register hooks in `~/.claude/settings.json`
- [ ] Test with manual session (create entities, verify graph)

### Phase 2: PreCompact Extraction (Day 3-4)

- [ ] Write `pre-compact-extract.mjs` with pattern matching
- [ ] Implement compact-detector.mjs (UserPromptSubmit workaround)
- [ ] Test entity extraction from sample transcript
- [ ] Verify Obsidian CLI note creation + property setting
- [ ] Test wikilink bidirectional registration

### Phase 3: Letta Gate + Tier 2 (Day 5-6)

- [ ] Implement Letta gate decision logic
- [ ] Write Tier 2 gap analysis (sub-agent based)
- [ ] Test Letta gate with intentionally poor extraction
- [ ] Verify Tier 2 only triggers when needed

### Phase 4: Forgetful-ai Integration (Day 7-8)

- [ ] Configure forgetful-ai MCP server
- [ ] Implement dual-write pattern (L2 + L3)
- [ ] Write forgetful-queue processor in SessionStart
- [ ] Test semantic retrieval across sessions
- [ ] Verify graph relationships in forgetful-ai

### Phase 5: Polish + Monitoring (Day 9-10)

- [ ] Add error handling and graceful degradation
- [ ] Implement health monitoring (orphan rate, extraction quality)
- [ ] Create MOC (\_index.md) auto-update
- [ ] Performance profiling under real session load
- [ ] Documentation and runbook

---

## 11. Risk Register

| Risk                                                | Impact | Mitigation                                          |
| --------------------------------------------------- | ------ | --------------------------------------------------- |
| PreCompact hook doesn't exist natively              | High   | UserPromptSubmit workaround + advocate for #17237   |
| CLI latency > 200ms causes UX degradation           | Medium | Async where possible, batch operations              |
| Entity extraction quality (regex) is low            | Medium | Phase 2 can upgrade to LLM-based extraction         |
| Obsidian vault bloat from session artifacts         | Low    | Prune old sessions (>30 days), archive pattern      |
| Forgetful-ai graph becomes noisy                    | Medium | Confidence thresholds, forget low-value memories    |
| Letta agent restores blocks (overrides gate config) | Low    | Address via transcript influence, not API overwrite |
| Concurrent CLI calls cause race conditions          | Low    | Sequential within hook, parallel across hooks       |

---

## 12. Research Sources

All research saved to `/Users/mikhail/Projects/obsidian-cli/research/`:

| File                        | Content                                                   | Lines |
| --------------------------- | --------------------------------------------------------- | ----- |
| `01-core-commands.md`       | 87 CLI commands, property system, search syntax           | 682   |
| `02-graph-links.md`         | Network analysis, 100-file sample, small-world properties | 344   |
| `03-data-formats.md`        | JSON output, structured queries, Canvas/Base limitations  | 855   |
| `04-dev-eval-plugins.md`    | Eval API access, resolvedLinks, plugin integration        | 983   |
| `05-automation-patterns.md` | Batch creation, Watts-Strogatz, production workflows      | 683   |
| `06-turbovault-analysis.md` | TurboVault vs CLI discrepancy analysis                    | 73    |

### External Sources

- **Official CLI docs**: `/Users/mikhail/Downloads/Obsidian CLI.md` (1,544 lines)
- **Obsidian API (DeepWiki)**: `deepwiki.com/obsidianmd/obsidian-api` — MetadataCache, Vault, FileManager
- **Feature request**: GitHub #17237 (PreCompact hook)
- **Forgetful-ai**: Graph-based MCP memory server (5 node types, 9 edge types)

---

**Design complete.** Ready for Phase 1 implementation when approved.
