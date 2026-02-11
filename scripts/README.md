# Obsidian CLI Knowledge Graph Scripts

Modular scripts for automated knowledge graph generation, analysis, and maintenance using the [Obsidian CLI](https://github.com/Zpankz/obsidian-cli) (v1.12.0+).

## Architecture

```
scripts/
├── lib/
│   └── obsidian_cli.sh              # Shared library (CLI wrapper, logging, helpers)
├── 01-discovery/                     # Phase 1: Vault scanning & inventory
│   ├── vault-inventory.sh           #   File listing, sizes, types, folder tree
│   ├── property-census.sh           #   Property names, types, distributions
│   └── tag-taxonomy.sh              #   Tag hierarchy, co-occurrence matrix
├── 02-extraction/                    # Phase 2: Entity extraction
│   ├── frontmatter-export.sh        #   All frontmatter as structured JSON
│   ├── outline-extractor.sh         #   Heading structures per file
│   └── metadata-cache-dump.sh       #   Full metadata cache export
├── 03-relationship-mapping/          # Phase 3: Link graph export
│   ├── adjacency-export.sh          #   Resolved/unresolved link adjacency lists
│   ├── backlink-census.sh           #   Per-file backlink counts & ranking
│   └── link-type-classifier.sh      #   Wikilinks, embeds, frontmatter links, tags
├── 04-graph-construction/            # Phase 4: Building the graph
│   ├── batch-note-creator.sh        #   Create notes from JSON/CSV input
│   ├── link-injector.sh             #   Add wikilinks to existing notes
│   └── property-tagger.sh           #   Batch set properties on files
├── 05-analysis/                      # Phase 5: Graph analytics
│   ├── network-metrics.sh           #   Degree distribution, density, clustering
│   ├── hub-authority-report.sh      #   Hub/authority/bridge node ranking
│   ├── graph-health-report.sh       #   Orphans, deadends, health score
│   ├── centrality-analysis.sh       #   PageRank, betweenness, closeness centrality
│   └── community-detection.sh       #   Label propagation community detection
├── 06-maintenance/                   # Phase 6: Graph repair
│   ├── orphan-linker.sh             #   Suggest links for orphan files
│   ├── broken-link-fixer.sh         #   Detect broken links with fix suggestions
│   ├── deadend-enricher.sh          #   Add outgoing links to dead-end files
│   └── missing-link-predictor.sh    #   Predict missing links via common neighbors
├── 07-evolution/                     # Phase 7: Graph optimization
│   ├── note-decomposer.sh           #   Split large notes into atomic notes
│   ├── small-world-optimizer.sh     #   Watts-Strogatz small-world rewiring
│   ├── cluster-bridge-builder.sh    #   Create MOC bridge notes across clusters
│   └── semantic-linker.sh           #   Content-based similarity linking
├── 08-reporting/                     # Phase 8: Report generation
│   └── vault-report-generator.sh    #   Aggregate analysis into a vault note
├── orchestrator.sh                   # Master runner for pipeline execution
└── README.md                         # This file
```

## Quick Start

```bash
# Run the full read-only pipeline (phases 1, 2, 3, 5, 6)
./scripts/orchestrator.sh --vault my-vault

# Run specific phases
./scripts/orchestrator.sh --vault my-vault --phases 1,5

# Run a single script
./scripts/05-analysis/graph-health-report.sh --vault my-vault

# Dry run (no CLI calls)
./scripts/orchestrator.sh --vault my-vault --dry-run
```

## Prerequisites

- **Obsidian** desktop app running (the CLI communicates via IPC socket)
- **Obsidian CLI** available in PATH (embedded in Obsidian v1.12.0+)
- **Python 3.6+** (for data processing steps)
- **bash 4+**

## Configuration

All scripts accept these common options:

| Option | Env Var | Default | Description |
|--------|---------|---------|-------------|
| `--vault <name>` | `VAULT` | *(required)* | Obsidian vault name |
| `--output <dir>` | `OUTPUT_DIR` | `./output` | Output directory for results |
| `--dry-run` | `DRY_RUN=true` | `false` | Print commands without executing |
| `--debug` | `LOG_LEVEL=debug` | `info` | Enable debug logging |
| `--quiet` | `LOG_LEVEL=error` | `info` | Suppress non-error output |
| `--workers <n>` | `PARALLEL_WORKERS` | `4` | Parallel workers for batch ops |

## Phase Details

### Phase 1: Discovery & Inventory

Scans the vault to build a complete inventory. **Read-only, safe to run anytime.**

```bash
# Full vault inventory (files, sizes, types)
./scripts/01-discovery/vault-inventory.sh --vault distil

# Property catalog with distributions
./scripts/01-discovery/property-census.sh --vault distil

# Tag hierarchy and co-occurrence
./scripts/01-discovery/tag-taxonomy.sh --vault distil
```

**Outputs:** `vault-inventory.json`, `file-type-stats.json`, `property-census.json`, `tag-taxonomy.json`, `tag-cooccurrence.json`

### Phase 2: Entity Extraction

Extracts structured data from every file. **Read-only.**

```bash
# Export all frontmatter (optionally filtered by path)
./scripts/02-extraction/frontmatter-export.sh --vault distil --path SAQ

# Extract heading structures
./scripts/02-extraction/outline-extractor.sh --vault distil --limit 500

# Full metadata cache dump (slim mode excludes positions)
./scripts/02-extraction/metadata-cache-dump.sh --vault distil --slim
```

**Outputs:** `frontmatter-all.json`, `frontmatter-entities.json`, `outlines.json`, `metadata-cache.json`

### Phase 3: Relationship Mapping

Exports the complete link graph. **Read-only.**

```bash
# Full adjacency list (resolved + unresolved)
./scripts/03-relationship-mapping/adjacency-export.sh --vault distil

# Backlink counts and ranking
./scripts/03-relationship-mapping/backlink-census.sh --vault distil --top 100

# Classify all links by type
./scripts/03-relationship-mapping/link-type-classifier.sh --vault distil
```

**Outputs:** `resolved-links.json`, `edge-list.csv`, `backlink-census.json`, `link-types.json`

### Phase 4: Graph Construction

Creates notes and adds links. **Write operations - use with care.**

```bash
# Create notes from JSON input
./scripts/04-graph-construction/batch-note-creator.sh \
  --vault distil --input notes.json --path _generated

# Inject wikilinks into existing notes
./scripts/04-graph-construction/link-injector.sh \
  --vault distil --input link-map.json --strategy append

# Batch set properties
./scripts/04-graph-construction/property-tagger.sh \
  --vault distil --name status --value reviewed --type text \
  --query "tag:#type/entity"
```

**Input formats:**

```json
// batch-note-creator input (JSON)
[
  {
    "name": "my-note",
    "content": "# Title\n\nBody with [[wikilinks]]",
    "properties": { "type": "concept", "tags": ["tag1"] }
  }
]

// link-injector input (JSON)
{
  "source-file.md": ["target1", "target2"],
  "other-file.md": ["target3"]
}
```

### Phase 5: Graph Analysis

Computes network metrics. **Read-only.**

```bash
# Network metrics (density, clustering, degree distribution)
./scripts/05-analysis/network-metrics.sh --vault distil

# Hub and authority ranking
./scripts/05-analysis/hub-authority-report.sh --vault distil --top 50

# Comprehensive health score (0-100)
./scripts/05-analysis/graph-health-report.sh --vault distil

# Full centrality analysis (PageRank, betweenness, closeness)
./scripts/05-analysis/centrality-analysis.sh --vault distil --top 30

# Community detection (label propagation + modularity)
./scripts/05-analysis/community-detection.sh --vault distil --min-community 3
```

**Outputs:** `network-metrics.json`, `hub-authority-report.json`, `graph-health.json`, `centrality-analysis.json`, `centrality-report.txt`, `communities.json`, `community-report.txt`

### Phase 6: Maintenance

Identifies and suggests fixes for graph issues. **Read-only by default**, with optional `--auto-link`.

```bash
# Find orphans and suggest connections
./scripts/06-maintenance/orphan-linker.sh --vault distil

# Detect broken links with fuzzy-match fix suggestions
./scripts/06-maintenance/broken-link-fixer.sh --vault distil --threshold 70

# Suggest outgoing links for dead-end notes
./scripts/06-maintenance/deadend-enricher.sh --vault distil
```

```bash
# Predict missing links from graph structure (common neighbors, Adamic-Adar)
./scripts/06-maintenance/missing-link-predictor.sh --vault distil --threshold 3
```

**Outputs:** `orphan-suggestions.json`, `broken-links.json`, `deadend-suggestions.json`, `predicted-links.json`, `predicted-link-map.json` + corresponding link maps ready for `link-injector.sh`

### Phase 7: Graph Evolution

Structural optimization. **Write operations for `--auto-link` / `--auto-create`.**

```bash
# Decompose a large note into atomic notes
./scripts/07-evolution/note-decomposer.sh \
  --vault distil --file "SAQ/ANZCA/ANZCA.md" --min-level 2

# Watts-Strogatz small-world optimization
./scripts/07-evolution/small-world-optimizer.sh \
  --vault distil --beta 0.1 --max-shortcuts 50

# Create bridge notes between clusters
./scripts/07-evolution/cluster-bridge-builder.sh \
  --vault distil --min-cluster-size 10

# Content-based similarity linking (Jaccard on tags, headings, links)
./scripts/07-evolution/semantic-linker.sh \
  --vault distil --threshold 0.15 --max-links 5
```

### Phase 8: Reporting

Aggregates analysis outputs into a comprehensive vault note. **Creates one note.**

```bash
# Generate report from all analysis outputs and create as vault note
./scripts/08-reporting/vault-report-generator.sh --vault distil

# Custom report location
./scripts/08-reporting/vault-report-generator.sh --vault distil \
  --note-path _reports --note-name "Monthly Graph Review"
```

**Outputs:** `vault-report.md` (local copy + vault note with wikilinks to top nodes)

## Pipeline Outputs

All outputs go to `./output/<phase>/` by default. Key files:

| File | Phase | Description |
|------|-------|-------------|
| `vault-inventory.json` | 1 | Complete file listing with metadata |
| `property-census.json` | 1 | All properties with types and distributions |
| `tag-taxonomy.json` | 1 | Tag hierarchy with counts |
| `frontmatter-all.json` | 2 | All frontmatter keyed by file path |
| `metadata-cache.json` | 2 | Complete metadata cache |
| `resolved-links.json` | 3 | Full adjacency list (source → targets) |
| `edge-list.csv` | 3 | Edge list for NetworkX/Gephi import |
| `backlink-census.json` | 3 | In-degree ranking for all files |
| `network-metrics.json` | 5 | Density, clustering, degree stats, topology |
| `graph-health.json` | 5 | Health score (0-100) with recommendations |
| `orphan-suggestions.json` | 6 | Link suggestions for orphan files |
| `broken-links.json` | 6 | Broken links with fuzzy-match fixes |
| `small-world-analysis.json` | 7 | Small-world coefficient (σ), clustering |
| `centrality-analysis.json` | 5 | PageRank, betweenness, closeness scores |
| `communities.json` | 5 | Community assignments with modularity |
| `predicted-links.json` | 6 | Missing link predictions (Adamic-Adar) |
| `semantic-similarities.json` | 7 | Content-based similarity pairs |
| `vault-report.md` | 8 | Aggregated analysis report (also a vault note) |

## CLI Commands Used

The scripts use these Obsidian CLI commands:

| Command | Purpose | Approx Latency |
|---------|---------|----------------|
| `obsidian eval code="..."` | JavaScript API access (metadataCache, vault, plugins) | ~200ms |
| `obsidian files` | File listing with metadata | ~100ms |
| `obsidian folders` | Folder structure | ~100ms |
| `obsidian properties` | Property enumeration | ~150ms |
| `obsidian tags` | Tag listing with counts | ~150ms |
| `obsidian orphans` | Files with no incoming links | ~150ms |
| `obsidian deadends` | Files with no outgoing links | ~150ms |
| `obsidian unresolved` | Broken wikilinks | ~150ms |
| `obsidian search` | Full-text and property search | ~200ms |
| `obsidian create` | Note creation | ~170ms |
| `obsidian append` | Append content to note | ~170ms |
| `obsidian prepend` | Prepend content after frontmatter | ~170ms |
| `obsidian property:set` | Set frontmatter property | ~170ms |
| `obsidian read` | Read note content | ~170ms |
| `obsidian outline` | Extract heading structure | ~170ms |

## Performance

- **Sequential**: ~170ms per operation, ~350 notes/minute
- **Parallel (4 workers)**: ~1,400 notes/minute
- **Full pipeline (2,600-file vault)**: ~2-5 minutes for read-only phases
- **Eval-based batch operations**: Single call for entire vault (fastest approach)

## Safety

- **Phases 1-3, 5**: Completely read-only. Safe to run anytime.
- **Phase 4**: Creates notes and modifies files. Use `--dry-run` first.
- **Phase 6**: Read-only by default. `--auto-link` writes to vault.
- **Phase 7**: Read-only by default. `--auto-link`/`--auto-create` write to vault.
- **Phase 8**: Creates one report note in the vault.
- **Eval commands**: All eval calls are read-only (`app.vault.getFiles()`, `app.metadataCache.*`). No write operations are performed via eval.

## Extending

### Adding a New Script

1. Create a new `.sh` file in the appropriate phase directory
2. Source the shared library: `source "$SCRIPT_DIR/../lib/obsidian_cli.sh"`
3. Use `parse_common_args "$@"` for standard option parsing
4. Use `obs_cli` and `obs_eval` wrappers for CLI calls
5. Use `ensure_output_dir` for output management

### Chaining Scripts

Scripts are designed to be chainable. Maintenance scripts produce link maps that feed directly into construction scripts:

```bash
# Generate suggestions → inject links
./scripts/06-maintenance/orphan-linker.sh --vault distil
./scripts/04-graph-construction/link-injector.sh \
  --vault distil --input output/06-maintenance/orphan-link-map.json

# Analyze → optimize → re-analyze
./scripts/05-analysis/network-metrics.sh --vault distil
./scripts/07-evolution/small-world-optimizer.sh --vault distil --auto-link
./scripts/05-analysis/network-metrics.sh --vault distil  # compare metrics

# Predict missing links → inject them
./scripts/06-maintenance/missing-link-predictor.sh --vault distil
./scripts/04-graph-construction/link-injector.sh \
  --vault distil --input output/06-maintenance/predicted-link-map.json

# Semantic similarity → inject links
./scripts/07-evolution/semantic-linker.sh --vault distil
./scripts/04-graph-construction/link-injector.sh \
  --vault distil --input output/07-evolution/semantic-link-map.json

# Full analysis → vault report
./scripts/orchestrator.sh --vault distil --phases 5
./scripts/08-reporting/vault-report-generator.sh --vault distil
```
