"""Render `reference/api-index.md` — the per-symbol reference index.

The load-bearing piece is the `SYMBOL -> FILE` table: an alphabetical map from
each consumer-facing type to its cluster file, so "where is X?" is one grep.
Sections use grep-able `## SECTION:` headings (matching the index convention).
"""

from __future__ import annotations

import symbolgraph
from render_reference import _cluster_title


def _present_types_by_cluster(graph, config):
    tops = symbolgraph.top_level_type_names(graph)
    result = []
    for slug, members in config["clusters"].items():
        present = [t for t in members if t in tops]
        if present:
            result.append((slug, present))
    return result


def build(graph, config):
    by_cluster = _present_types_by_cluster(graph, config)
    _, excluded_present, _ = symbolgraph.classify(graph, config)

    # symbol -> file, alphabetical.
    symbol_file = {}
    for slug, types in by_cluster:
        for t in types:
            symbol_file[t] = f"{slug}.md"

    out = ["# CameraKit API Reference — Index", ""]
    out += [
        "This indexes the per-symbol reference under `reference/`. For",
        "task-oriented learning start at `../index.md` and the guides; use this",
        "layer to look up a specific symbol's signature, parameters, returns, and",
        "errors.",
        "",
    ]

    out += ["## SECTION: HOW THE REFERENCE IS ORGANIZED", ""]
    out += [
        "Types are grouped by cohesion, one cluster per file. Grep a symbol name",
        "in the table below to find its file.",
        "",
    ]

    out += ["## SECTION: SYMBOL → FILE", ""]
    out += ["| Symbol | File |", "| --- | --- |"]
    for name in sorted(symbol_file):
        out.append(f"| `{name}` | [{symbol_file[name]}]({symbol_file[name]}) |")
    out.append("")

    out += ["## SECTION: BY CLUSTER", ""]
    for slug, types in by_cluster:
        members = ", ".join(f"`{t}`" for t in types)
        out.append(f"- [{_cluster_title(slug)}]({slug}.md): {members}")
    out.append("")

    out += ["## SECTION: NOT IN THIS REFERENCE", ""]
    out += [
        "These public types are development-internal (dependency-injection seams,",
        "test hooks, recovery/watchdog internals). Consumers never call them:",
        "",
    ]
    out.append(", ".join(f"`{t}`" for t in excluded_present) + ".")
    out.append("")

    return "\n".join(out).rstrip() + "\n"


if __name__ == "__main__":
    import sys

    graph = symbolgraph.load_graph(sys.argv[1])
    config = symbolgraph.load_config(sys.argv[2])
    with open(sys.argv[3], "w") as f:
        f.write(build(graph, config))
    print(f"wrote {sys.argv[3]}")
