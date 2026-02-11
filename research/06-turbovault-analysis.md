# TurboVault Graph Analysis Results

**Date:** 2026-02-11
**Vault:** distil (via TurboVault MCP, vault registered as "default")

---

## 1. Full Health Analysis

| Metric                         | Value         |
| ------------------------------ | ------------- |
| Total notes                    | 2,638         |
| Total links (TurboVault count) | 2,274         |
| Broken links                   | 0             |
| Orphaned notes                 | 1,190 (45.1%) |
| Dead-end notes                 | 1,211 (45.9%) |
| Hub notes                      | 5             |
| Health score                   | 87/100        |
| Healthy                        | Yes           |

## 2. Cycle Detection

**Cycles found: 0**

The vault link graph is a DAG (Directed Acyclic Graph). No circular reference chains detected. This makes sense for an exam-focused knowledge base where information flows from general concepts to specific exam questions (LOs → SAQs), not in cycles.

## 3. Export Report (JSON)

```json
{
  "timestamp": "2026-02-11T02:45:41.590449+00:00",
  "vault_name": "default",
  "health": {
    "health_score": 80,
    "total_notes": 2638,
    "total_links": 2274,
    "broken_links": 0,
    "orphaned_notes": 1190,
    "connectivity_rate": 0.5489,
    "link_density": 0.000327,
    "status": "Healthy"
  },
  "recommendations": [
    "Over 10% of notes are orphaned. Link them to improve connectivity.",
    "Low link density. Consider adding more cross-references between notes."
  ]
}
```

## 4. Discrepancy Analysis: TurboVault vs Obsidian CLI

| Metric       | TurboVault    | Obsidian CLI | Ratio |
| ------------ | ------------- | ------------ | ----- |
| Total links  | 2,274         | 32,426       | 14.3x |
| Orphans      | 1,190 (45.1%) | 127 (4.9%)   | 9.4x  |
| Dead-ends    | 1,211 (45.9%) | 718 (27.4%)  | 1.7x  |
| Connectivity | 54.9%         | 99% (sample) | -     |
| Link density | 0.000327      | 0.0101       | 30.9x |

**Root cause:** TurboVault parses wikilinks from raw markdown text via regex. Obsidian's `metadataCache.resolvedLinks` tracks ALL link types including:

- Wikilinks: `[[target]]`, `[[target|alias]]`
- Embeds: `![[image.png]]`, `![[note#heading]]`
- Tag references (when linking to tag notes)
- Alias resolution (multiple aliases → single target)
- Transclusion links

**Conclusion:** Obsidian CLI's view via `app.metadataCache.resolvedLinks` is **authoritative**. TurboVault's regex-based parsing underestimates true connectivity by ~14x. Use Obsidian CLI for graph metrics; use TurboVault for structural operations (note creation, search, metadata).

---

**Report generated:** 2026-02-11
**Tools used:** mcp**turbovault**full_health_analysis, mcp**turbovault**detect_cycles, mcp**turbovault**export_analysis_report
