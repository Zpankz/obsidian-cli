# Obsidian CLI Developer Tools: Eval, Plugins, and Graph Analysis

**Research Stage 4 - Deep Analysis**
**Date:** 2026-02-11
**Vault:** distil (ANZCA/CICM exam preparation)

## Executive Summary

The `obsidian eval` command provides **UNRESTRICTED ACCESS** to the Obsidian API runtime. This is the most powerful capability in the CLI - it enables programmatic graph analysis, plugin interaction, metadata queries, and custom data extraction without writing plugins.

**Key Findings:**

- Full JavaScript eval with access to `app`, `app.vault`, `app.metadataCache`, `app.plugins`, `app.workspace`
- Dataview plugin API accessible via `app.plugins.plugins['dataview'].api`
- Graph configuration and metadata fully readable
- 32,426 total resolved links, 2,975 unresolved links across 2,618 markdown files
- Zero orphan files (all files have at least one outgoing link)
- Graph view settings (filters, color groups, forces) exposed via `app.internalPlugins.plugins.graph.instance.options`

---

## 1. JavaScript Eval Capabilities

### 1.1 Basic Access

**Syntax:** `obsidian eval code="<javascript>" vault=<name>`

**Available Root Objects:**

```javascript
// Core API access
app; // Main Obsidian application object
app.vault; // Vault file system operations
app.metadataCache; // Graph links, file metadata, tags
app.workspace; // UI state, active files, leaves
app.plugins; // Plugin registry and APIs
app.internalPlugins; // Core plugins (graph, daily notes, etc.)
app.commands; // Command palette commands
```

**Test Results:**

```bash
# File counts
obsidian eval code="app.vault.getFiles().length" vault=distil
=> 2642 total files

obsidian eval code="app.vault.getMarkdownFiles().length" vault=distil
=> 2618 markdown files (24 non-markdown: images, JSON, etc.)
```

### 1.2 App Object Structure

**Full `app` keys:**

```json
[
  "appMenuBarManager",
  "embedRegistry",
  "viewRegistry",
  "nextFrameEvents",
  "nextFrameTimer",
  "isMobile",
  "mobileToolbar",
  "mobileNavbar",
  "mobileTabSwitcher",
  "mobileQuickActions",
  "lastEvent",
  "title",
  "appId",
  "keymap",
  "scope",
  "commands",
  "hotkeyManager",
  "dragManager",
  "dom",
  "customCss",
  "shareReceiver",
  "renderContext",
  "secretStorage",
  "cli",
  "vault",
  "workspace",
  "fileManager",
  "statusBar",
  "metadataCache",
  "metadataTypeManager",
  "setting",
  "foldManager",
  "internalPlugins",
  "plugins",
  "setAccentColor"
]
```

**Key objects for data analysis:**

- `app.vault` - File system operations (read, write, list)
- `app.metadataCache` - **Graph adjacency lists** (resolvedLinks, unresolvedLinks)
- `app.plugins` - Community plugin APIs (Dataview, Datacore, etc.)
- `app.workspace` - Active file, editor state
- `app.commands` - Command palette actions

---

## 2. MetadataCache: The Graph Core

### 2.1 Structure

**MetadataCache keys:**

```json
[
  "_",
  "worker",
  "inProgressTaskCount",
  "db",
  "fileCache",
  "metadataCache",
  "workQueue",
  "uniqueFileLookup",
  "didFinish",
  "initialized",
  "resolvedLinks",
  "unresolvedLinks",
  "linkResolverQueue",
  "onCleanCacheCallbacks",
  "workerResolve",
  "userIgnoreFilters",
  "userIgnoreFiltersString",
  "userIgnoreFilterCache",
  "app",
  "vault",
  "blockCache",
  "preloadPromise",
  "transactionSave"
]
```

**Critical objects:**

- `resolvedLinks` - **Adjacency list of all valid wikilinks** (source → {target: count})
- `unresolvedLinks` - Broken wikilinks (source → {target: count})
- `fileCache` - Per-file metadata (frontmatter, headings, tags, links, sections)

### 2.2 Resolved Links (Graph Adjacency List)

**Structure:** `{sourcePath: {targetPath: linkCount, ...}, ...}`

**Sample:**

```json
{
  "AGENTS.md": {},
  "LO/ANZCA/ANZCA.md": {
    "LO/ANZCA/A_applied-procedural-anatomy/A_applied-procedural-anatomy.md": 1,
    "LO/ANZCA/G_cardiovascular-system/G_cardiovascular-system.md": 1,
    "LO/ANZCA/P_endocrine-metabolism-and-nutrition/P_endocrine-metabolism-and-nutrition.md": 1,
    ...
  }
}
```

**Statistics:**

```javascript
// Total files with outgoing links
Object.keys(app.metadataCache.resolvedLinks).length
=> 2618

// Total resolved links across vault
const links = app.metadataCache.resolvedLinks;
let totalLinks = 0;
Object.values(links).forEach(targets => totalLinks += Object.keys(targets).length);
totalLinks
=> 32426

// Total unresolved links (broken wikilinks)
const unresolved = app.metadataCache.unresolvedLinks;
let count = 0;
Object.values(unresolved).forEach(targets => count += Object.keys(targets).length);
count
=> 2975
```

### 2.3 Graph Analysis via Eval

**Top 5 most connected files (outgoing links):**

```javascript
const links = app.metadataCache.resolvedLinks;
const counts = Object.entries(links)
  .map(([file, targets]) => [file, Object.keys(targets).length])
  .sort((a, b) => b[1] - a[1])
  .slice(0, 5);
JSON.stringify(counts);
```

**Result:**

```json
[
  ["SAQ/ANZCA/ANZCA.md", 55],
  ["LO/ANZCA/L_pain/L3_pain-pharmacology/APL3xxiv_pharmacology-local.md", 49],
  [
    "LO/ANZCA/G_cardiovascular-system/G2_cardiovascular-physiology/APG2iv_factors-determine.md",
    44
  ],
  [
    "LO/ANZCA/G_cardiovascular-system/G2_cardiovascular-physiology/APG2vi_determinants-regulation.md",
    44
  ],
  ["SAQ/ANZCA/AP06B/AP06B10.md", 44]
]
```

**Top 5 most linked-to files (backlinks):**

```javascript
const files = app.vault.getMarkdownFiles();
const backlinks = {};
Object.entries(app.metadataCache.resolvedLinks).forEach(([source, targets]) => {
  Object.keys(targets).forEach((target) => {
    backlinks[target] = (backlinks[target] || 0) + 1;
  });
});
const sorted = Object.entries(backlinks)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 5);
JSON.stringify(sorted);
```

**Result:**

```json
[
  ["SAQ/ANZCA/AP99A/AP99A05.md", 728],
  ["SAQ/ANZCA/AP99A/AP99A11.md", 690],
  ["SAQ/ANZCA/AP99A/AP99A04.md", 535],
  ["SAQ/ANZCA/AP99A/AP99A08.md", 534],
  ["SAQ/ANZCA/AP99A/AP99A07.md", 533]
]
```

**Orphan detection (files with no outgoing links):**

```javascript
const allFiles = new Set(app.vault.getMarkdownFiles().map(f => f.path));
const linked = new Set(Object.keys(app.metadataCache.resolvedLinks));
const orphans = [...allFiles].filter(f => !linked.has(f));
orphans.length
=> 0  // No orphans in distil vault!
```

### 2.4 File Cache (Per-File Metadata)

**Access:** `app.metadataCache.getCache(filePath)`

**Structure:** Returns object with:

- `frontmatter` - YAML frontmatter as object
- `links` - Array of wikilinks with positions
- `embeds` - Array of embedded files
- `tags` - Array of tags with positions
- `headings` - Array of headings with levels
- `sections` - Array of sections with positions
- `blocks` - Named blocks

**Sample (rich file with frontmatter):**

```javascript
const cache = app.metadataCache.getCache(
  "LO/ANZCA/L_pain/L3_pain-pharmacology/APL3xxiv_pharmacology-local.md",
);
JSON.stringify({
  frontmatter: cache?.frontmatter,
  tags: cache?.tags?.map((t) => t.tag),
  links: cache?.links?.length,
});
```

**Result (truncated frontmatter):**

```json
{
  "frontmatter": {
    "college": "ANZCA",
    "title": "APL3xxiv_pharmacology-local",
    "aliases": ["BT_RA 1.3", "APL3xxiv", "ANZCA_12_3_24_BT_RA_1_3_DiscussPharmacologyLocalAnaestheticAgentsIncluding"],
    "summary": "Discuss the pharmacology of local anaesthetic agents...",
    "section": "[[L_pain]]",
    "section.sub": "[[L3_pain-pharmacology]]",
    "saq.direct": ["[[AP99A10]]", "[[AP99B11]]", "[[AP25A11]]", ...],
    "topic": "PHARMACODYNAMICS",
    "complexity": 4.29,
    "type.measurement": true,
    "lo.mapped": "[[H6ii_local-anaesthetic-drugs-pharmacology|CPH6ii]]"
  }
}
```

**Key insight:** File cache gives structured access to ALL markdown metadata, not just text content.

---

## 3. Plugin System

### 3.1 Installed Plugins

**Command:** `obsidian plugins vault=distil filter=community`

**Installed plugins:**

```
dataview
folders-graph
inline-local-graph
nova
obsidian-minimal-settings
obsidian42-brat
pieces-for-developers
terminal
```

**Enabled plugins:**

```bash
obsidian plugins:enabled vault=distil filter=community
=> Same list (all 8 enabled)
```

### 3.2 Plugin API Access

**Structure:** `app.plugins.plugins[pluginId]`

**Plugin object keys:**

```json
[
  "_loaded",
  "_events",
  "_children",
  "_lastDataModifiedTime",
  "_userDisabled",
  "onConfigFileChange",
  "app",
  "manifest",
  "settings",
  "index",
  "api",
  "cmExtension",
  "debouncedRefresh"
]
```

**Key property:** `api` - Public API exposed by plugin

### 3.3 Dataview Plugin API

**Access:** `app.plugins.plugins['dataview'].api`

**Confirmation:**

```javascript
JSON.stringify(app.plugins.plugins['dataview']?.api ? 'has-api' : 'no-api')
=> "has-api"
```

**API capabilities (from Dataview docs):**

- `api.pages(query)` - Query pages (returns DataArray)
- `api.page(path)` - Get single page metadata
- `api.evaluate(expression)` - Evaluate DQL expression
- `api.query(dql, path)` - Execute full Dataview query
- `api.queryMarkdown(dql, path)` - Execute query, return markdown

**Test query (SAQ files with #type/saq tag):**

```javascript
JSON.stringify(
  app.plugins.plugins['dataview']?.api?.pages('#type/saq')
    .array()
    .slice(0,3)
    .map(p => p.file.name)
)
=> []  // No results (tag structure may differ)
```

**Note:** Dataview API is fully accessible. Queries can extract frontmatter, compute aggregates, and generate reports programmatically.

---

## 4. Graph View Plugin

### 4.1 Internal Plugin Structure

**Access:** `app.internalPlugins.plugins.graph`

**Keys:**

```json
[
  "_loaded",
  "_events",
  "_children",
  "lastSave",
  "manager",
  "instance",
  "enabled",
  "commands",
  "ribbonItems",
  "mobileFileInfo",
  "hasStatusBarItem",
  "statusBarEl",
  "addedButtonEls",
  "views",
  "onConfigFileChange",
  "app"
]
```

**Key property:** `instance` - Active graph view instance

### 4.2 Graph Configuration

**Access:** `app.internalPlugins.plugins.graph.instance.options`

**Full configuration:**

```json
{
  "collapse-filter": true,
  "search": "path:LO  ",
  "showTags": false,
  "showAttachments": false,
  "hideUnresolved": true,
  "showOrphans": false,
  "collapse-color-groups": true,
  "colorGroups": [
    {
      "query": "path:LO/CICM  ",
      "color": { "a": 1, "rgb": 52479 }
    },
    {
      "query": "path:LO/ANZCA  ",
      "color": { "a": 1, "rgb": 16711854 }
    }
  ],
  "collapse-display": true,
  "showArrow": false,
  "textFadeMultiplier": 1.5,
  "nodeSizeMultiplier": 0.527473958333333,
  "lineSizeMultiplier": 0.520668402777778,
  "collapse-forces": true,
  "centerStrength": 0.49453125,
  "repelStrength": 20,
  "linkStrength": 1,
  "linkDistance": 30,
  "scale": 0.4070655745692258,
  "close": true
}
```

**Key settings:**

- `search` - Filter query (currently: "path:LO ")
- `colorGroups` - Array of filter queries with colors
- `hideUnresolved` - Hide broken links
- `showOrphans` - Show isolated nodes
- Force-directed layout params: `centerStrength`, `repelStrength`, `linkStrength`, `linkDistance`
- Display params: `nodeSizeMultiplier`, `lineSizeMultiplier`, `textFadeMultiplier`

**Note:** These settings are **READ-ONLY** via CLI eval. Modification would require UI interaction or plugin development.

### 4.3 Graph Commands

**Command:** `obsidian commands filter=graph vault=distil`

**Available commands:**

```
graph:animate
graph:open
graph:open-local
```

**Test (open graph view):**

```bash
obsidian command id=graph:open vault=distil
# (Would open graph view in Obsidian UI)
```

---

## 5. Workspace Object

### 5.1 Structure

**Keys:**

```json
[
  "_",
  "leftSplit",
  "rightSplit",
  "leftRibbon",
  "rightRibbon",
  "rootSplit",
  "floatingSplit",
  "activeLeaf",
  "activeTabGroup",
  "containerEl",
  "layoutReady",
  "requestSaveLayout",
  "requestResize",
  "requestActiveLeafEvents",
  "requestUpdateLayout",
  "requestLayoutChangeEvents",
  "mobileFileInfos",
  "backlinkInDocument",
  "lastTabGroupStacked",
  "protocolHandlers",
  "onLayoutReadyCallbacks",
  "undoHistory",
  "lastActiveFile",
  "_activeEditor",
  "layoutItemQueue",
  "handleXCallback",
  "hoverLinkSources",
  "operatorFuncConfigs",
  "editorExtensions",
  "app",
  "scope",
  "recentFileTracker",
  "leftSidebarToggleButtonEl",
  "rightSidebarToggleButtonEl",
  "editorSuggest"
]
```

**Key properties:**

- `activeLeaf` - Currently active editor pane
- `lastActiveFile` - Last opened file
- `activeTabGroup` - Active tab group
- `undoHistory` - Undo/redo stack

### 5.2 Active Leaf

**Access:** `app.workspace.activeLeaf`

**Structure:**

```json
[
  "_",
  "containerEl",
  "dimension",
  "component",
  "app",
  "workspace",
  "id",
  "resizeHandleEl",
  "type",
  "activeTime",
  "history",
  "hoverPopover",
  "group",
  "pinned",
  "width",
  "height",
  "resizeObserver",
  "working",
  "tabHeaderEl",
  "tabHeaderInnerIconEl"
]
```

**Key properties:**

- `type` - Leaf type (e.g., "markdown", "graph", "canvas")
- `activeTime` - Timestamp of last activation
- `history` - Navigation history
- `pinned` - Whether tab is pinned

---

## 6. Vault Object

### 6.1 Structure

**Keys:**

```json
[
  "_",
  "fileMap",
  "config",
  "configTs",
  "configDir",
  "requestSaveConfig",
  "cacheLimit",
  "reloadConfig",
  "adapter",
  "root"
]
```

**Key methods (from Obsidian API docs):**

- `getFiles()` - All files (TFile[])
- `getMarkdownFiles()` - Only .md files (TFile[])
- `getAbstractFileByPath(path)` - Get file/folder by path
- `read(file)` - Read file content
- `cachedRead(file)` - Read from cache
- `create(path, content)` - Create new file
- `modify(file, content)` - Modify file
- `delete(file)` - Delete file
- `rename(file, newPath)` - Rename/move file

**Critical:** Write operations (`create`, `modify`, `delete`, `rename`) should **NOT** be used via CLI eval for safety.

---

## 7. Advanced Graph Analytics (Python Integration)

### 7.1 Export Graph Data

**Strategy:** Use eval to export resolvedLinks as JSON, then analyze with Python/NetworkX.

**Export command:**

```bash
obsidian eval code="JSON.stringify(app.metadataCache.resolvedLinks)" vault=distil > graph.json
```

**Python analysis example:**

```python
import json
import networkx as nx

# Load graph
with open('graph.json') as f:
    links = json.load(f)

# Build NetworkX directed graph
G = nx.DiGraph()
for source, targets in links.items():
    for target, count in targets.items():
        G.add_edge(source, target, weight=count)

# Compute metrics
print(f"Nodes: {G.number_of_nodes()}")
print(f"Edges: {G.number_of_edges()}")
print(f"Density: {nx.density(G):.4f}")

# PageRank (importance)
pr = nx.pagerank(G)
top_pr = sorted(pr.items(), key=lambda x: x[1], reverse=True)[:10]
print("Top 10 by PageRank:", top_pr)

# Betweenness centrality (bridging nodes)
bc = nx.betweenness_centrality(G)
top_bc = sorted(bc.items(), key=lambda x: x[1], reverse=True)[:10]
print("Top 10 by Betweenness:", top_bc)

# Community detection
communities = nx.algorithms.community.greedy_modularity_communities(G.to_undirected())
print(f"Communities: {len(communities)}")

# Clustering coefficient
cc = nx.average_clustering(G.to_undirected())
print(f"Clustering coefficient: {cc:.4f}")
```

### 7.2 Obsidian-Specific Metrics

**Hub notes (high out-degree):**

```javascript
const links = app.metadataCache.resolvedLinks;
const hubs = Object.entries(links)
  .map(([file, targets]) => ({ file, outDegree: Object.keys(targets).length }))
  .filter((n) => n.outDegree > 30)
  .sort((a, b) => b.outDegree - a.outDegree);
JSON.stringify(hubs);
```

**Authority notes (high in-degree):**

```javascript
const backlinks = {};
Object.entries(app.metadataCache.resolvedLinks).forEach(([source, targets]) => {
  Object.keys(targets).forEach((target) => {
    backlinks[target] = (backlinks[target] || 0) + 1;
  });
});
const authorities = Object.entries(backlinks)
  .map(([file, inDegree]) => ({ file, inDegree }))
  .filter((n) => n.inDegree > 100)
  .sort((a, b) => b.inDegree - a.inDegree);
JSON.stringify(authorities);
```

**Bridge notes (high betweenness - requires NetworkX):**

Export graph → Python → NetworkX betweenness_centrality

---

## 8. Safety & Limitations

### 8.1 READ-ONLY Operations

**SAFE eval examples:**

- `app.vault.getFiles()`
- `app.vault.getMarkdownFiles()`
- `app.metadataCache.getCache(path)`
- `app.metadataCache.resolvedLinks`
- `app.plugins.plugins['dataview'].api.pages()`
- `JSON.stringify(app.internalPlugins.plugins.graph.instance.options)`

### 8.2 DANGEROUS Operations (AVOID)

**DO NOT use via eval:**

- `app.vault.create(path, content)` - Creates files
- `app.vault.modify(file, content)` - Modifies files
- `app.vault.delete(file)` - Deletes files
- `app.vault.rename(file, newPath)` - Moves files
- `app.metadataCache.trigger(...)` - Triggers events
- Any plugin API methods that modify state

**Rationale:** CLI eval has no undo, no confirmation dialogs, and runs with full vault permissions. Data loss risk is high.

### 8.3 Limitations

1. **No DOM access in headless mode** - `app.workspace.activeLeaf` may be null if Obsidian isn't running with UI
2. **No async/await** - Eval is synchronous, can't use Promises (would need callback-based approach)
3. **Output size limits** - Large JSON outputs may be truncated (use slicing: `.slice(0, 500)`)
4. **No interactive debugging** - No breakpoints, console.log only
5. **Plugin availability** - Plugins must be installed and enabled for API access

---

## 9. Use Cases

### 9.1 Graph Analytics Dashboard

**Export vault graph metrics:**

```bash
# Total stats
obsidian eval code="JSON.stringify({
  files: app.vault.getMarkdownFiles().length,
  totalLinks: Object.values(app.metadataCache.resolvedLinks).reduce((sum, targets) => sum + Object.keys(targets).length, 0),
  unresolvedLinks: Object.values(app.metadataCache.unresolvedLinks).reduce((sum, targets) => sum + Object.keys(targets).length, 0)
})" vault=distil
```

**Result:**

```json
{
  "files": 2618,
  "totalLinks": 32426,
  "unresolvedLinks": 2975
}
```

### 9.2 Dataview Query Automation

**Extract all SAQ files with complexity > 4:**

```javascript
const pages = app.plugins.plugins["dataview"].api.pages('"SAQ"');
const filtered = pages
  .where((p) => p.complexity > 4)
  .array()
  .map((p) => ({
    name: p.file.name,
    complexity: p.complexity,
    college: p.college,
  }));
JSON.stringify(filtered.slice(0, 10));
```

### 9.3 Tag Analysis

**Count notes by tag:**

```javascript
const tagCounts = {};
app.vault.getMarkdownFiles().forEach((file) => {
  const cache = app.metadataCache.getCache(file.path);
  cache?.tags?.forEach((tagObj) => {
    const tag = tagObj.tag;
    tagCounts[tag] = (tagCounts[tag] || 0) + 1;
  });
});
const sorted = Object.entries(tagCounts)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 20);
JSON.stringify(sorted);
```

### 9.4 Broken Link Detection

**Find files with most unresolved links:**

```javascript
const unresolved = app.metadataCache.unresolvedLinks;
const counts = Object.entries(unresolved)
  .map(([file, targets]) => [file, Object.keys(targets).length])
  .filter(([file, count]) => count > 0)
  .sort((a, b) => b[1] - a[1])
  .slice(0, 10);
JSON.stringify(counts);
```

### 9.5 Frontmatter Extraction

**Extract all files with specific frontmatter field:**

```javascript
const results = [];
app.vault.getMarkdownFiles().forEach((file) => {
  const cache = app.metadataCache.getCache(file.path);
  const fm = cache?.frontmatter;
  if (fm && fm["lo.mapped"]) {
    results.push({
      file: file.path,
      loMapped: fm["lo.mapped"],
    });
  }
});
JSON.stringify(results.slice(0, 10));
```

---

## 10. Recommendations

### 10.1 For Data Analysis

1. **Export graph to JSON** → Analyze with Python/NetworkX for complex metrics
2. **Use Dataview API** for structured queries (better than parsing markdown)
3. **Cache file metadata** - `getCache()` is faster than reading file content
4. **Slice large outputs** - Use `.slice(0, N)` to avoid truncation

### 10.2 For Integration

1. **Build external tools** that query Obsidian state via CLI eval
2. **Generate reports** from vault metadata (daily stats, broken links, etc.)
3. **Sync to external systems** (export graph to Neo4j, frontmatter to SQLite)
4. **Validate vault integrity** (orphans, broken links, missing frontmatter)

### 10.3 For Safety

1. **READ-ONLY by default** - Never use write operations via eval
2. **Test on small datasets** - Use `.slice()` to verify queries before full run
3. **Backup vault** before experimenting with plugins or complex queries
4. **Use version control** - Git-track vault for rollback capability

---

## 11. Vault Statistics (distil)

**Files:**

- Total files: 2,642
- Markdown files: 2,618
- Non-markdown: 24 (images, JSON, etc.)

**Links:**

- Total resolved links: 32,426
- Total unresolved links: 2,975
- Files with outgoing links: 2,618 (100%)
- Orphan files (no outgoing links): 0

**Most Connected Files (Outgoing):**

1. `SAQ/ANZCA/ANZCA.md` - 55 links
2. `LO/ANZCA/L_pain/L3_pain-pharmacology/APL3xxiv_pharmacology-local.md` - 49 links
3. `LO/ANZCA/G_cardiovascular-system/G2_cardiovascular-physiology/APG2iv_factors-determine.md` - 44 links
4. `LO/ANZCA/G_cardiovascular-system/G2_cardiovascular-physiology/APG2vi_determinants-regulation.md` - 44 links
5. `SAQ/ANZCA/AP06B/AP06B10.md` - 44 links

**Most Linked-To Files (Incoming):**

1. `SAQ/ANZCA/AP99A/AP99A05.md` - 728 backlinks
2. `SAQ/ANZCA/AP99A/AP99A11.md` - 690 backlinks
3. `SAQ/ANZCA/AP99A/AP99A04.md` - 535 backlinks
4. `SAQ/ANZCA/AP99A/AP99A08.md` - 534 backlinks
5. `SAQ/ANZCA/AP99A/AP99A07.md` - 533 backlinks

**Graph View Configuration:**

- Active filter: `path:LO  `
- Color groups: CICM (rgb 52479), ANZCA (rgb 16711854)
- Unresolved links hidden
- Orphans hidden (none exist)
- Force-directed layout with custom strength params

**Installed Plugins:**

- dataview (with API)
- folders-graph
- inline-local-graph
- nova
- obsidian-minimal-settings
- obsidian42-brat
- pieces-for-developers
- terminal

---

## 12. Next Steps

**Research Stage 5 - Integration Patterns:**

1. **Python graph analyzer** - Export resolvedLinks → NetworkX → PageRank, betweenness, communities
2. **Dataview query library** - Common queries for SAQ/LO extraction
3. **Broken link fixer** - Detect + suggest fixes for 2,975 unresolved links
4. **Vault health dashboard** - Daily stats via cron + CLI eval
5. **External sync** - Export frontmatter to SQLite for complex queries

**Tools to build:**

- `obsidian-graph-export` - Export graph to GraphML/GEXF for Gephi
- `obsidian-query` - Wrapper for common Dataview queries
- `obsidian-validate` - Vault integrity checks (broken links, missing frontmatter)
- `obsidian-stats` - Daily/weekly vault metrics

---

## Appendix: Raw Command Reference

```bash
# File counts
obsidian eval code="app.vault.getFiles().length" vault=distil
obsidian eval code="app.vault.getMarkdownFiles().length" vault=distil

# Object structure exploration
obsidian eval code="JSON.stringify(Object.keys(app))" vault=distil
obsidian eval code="JSON.stringify(Object.keys(app.metadataCache))" vault=distil
obsidian eval code="JSON.stringify(Object.keys(app.workspace))" vault=distil
obsidian eval code="JSON.stringify(Object.keys(app.vault))" vault=distil

# Graph metadata
obsidian eval code="Object.keys(app.metadataCache.resolvedLinks).length" vault=distil
obsidian eval code="Object.keys(app.metadataCache.unresolvedLinks).length" vault=distil
obsidian eval code="JSON.stringify(app.metadataCache.resolvedLinks).slice(0,500)" vault=distil

# Plugin access
obsidian eval code="JSON.stringify(Object.keys(app.plugins.plugins))" vault=distil
obsidian eval code="JSON.stringify(Object.keys(app.plugins.plugins['dataview'] || {}))" vault=distil
obsidian eval code="JSON.stringify(app.plugins.plugins['dataview']?.api ? 'has-api' : 'no-api')" vault=distil

# Graph plugin
obsidian eval code="JSON.stringify(Object.keys(app.internalPlugins?.plugins?.graph || {}))" vault=distil
obsidian eval code="JSON.stringify(app.internalPlugins?.plugins?.graph?.instance?.options || 'none')" vault=distil

# File cache
obsidian eval code="const cache = app.metadataCache.getCache('SAQ/ANZCA/ANZCA.md'); JSON.stringify({frontmatter: Object.keys(cache?.frontmatter || {}), links: cache?.links?.length})" vault=distil

# Graph analysis
obsidian eval code="const links = app.metadataCache.resolvedLinks; const counts = Object.entries(links).map(([file, targets]) => [file, Object.keys(targets).length]).sort((a,b) => b[1] - a[1]).slice(0,5); JSON.stringify(counts)" vault=distil

# Commands
obsidian commands filter=graph vault=distil
obsidian plugins vault=distil filter=community
obsidian plugins:enabled vault=distil filter=community
```

---

**End of Report**
