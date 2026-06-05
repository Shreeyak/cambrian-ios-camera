"""Shared helpers for reading a Swift symbol graph and the cluster config.

The symbol graph is the compiler-emitted JSON (`-emit-symbol-graph`). Every
symbol carries `pathComponents` (e.g. `["CameraEngine", "open()"]`), so a
symbol's owning top-level type is `pathComponents[0]`. All symbols in the graph
are already `public` (the compiler drops internal/private), so consumer scoping
is purely the include/exclude decision encoded in `cluster_map.json`.
"""

from __future__ import annotations

import json

TYPE_KINDS = {
    "swift.class",
    "swift.struct",
    "swift.enum",
    "swift.protocol",
    "swift.typealias",
}


def load_graph(path):
    with open(path) as f:
        return json.load(f)


def load_config(path):
    with open(path) as f:
        return json.load(f)


def owning_type(symbol):
    """The top-level type a symbol belongs to (its first path component)."""
    return symbol["pathComponents"][0]


def title(symbol):
    return symbol["names"]["title"]


def top_level_type_names(graph):
    """Names of every top-level (path length 1) type symbol in the graph."""
    return {
        s["pathComponents"][0]
        for s in graph["symbols"]
        if len(s["pathComponents"]) == 1 and s["kind"]["identifier"] in TYPE_KINDS
    }


def included_type_names(config):
    names = set()
    for members in config["clusters"].values():
        names.update(members)
    return names


def classify(graph, config):
    """Partition the graph's top-level types.

    Returns (included, excluded_present, unclassified) where each is a sorted
    list of type names. `unclassified` are top-level types named in neither the
    cluster map nor the exclude list — the drift guard treats a non-empty
    `unclassified` as a hard error so new public API cannot slip in silently.
    """
    tops = top_level_type_names(graph)
    included_cfg = included_type_names(config)
    excluded_cfg = set(config.get("exclude", []))

    included = sorted(tops & included_cfg)
    excluded_present = sorted(tops & excluded_cfg)
    unclassified = sorted(tops - included_cfg - excluded_cfg)
    return included, excluded_present, unclassified


def filter_symbols(graph, config):
    """Keep only symbols owned by an included type.

    Returns (kept_symbols, excluded_present) — `kept_symbols` includes each
    included type plus all of its members; `excluded_present` is the sorted list
    of excluded type names actually found in the graph (for the api-index
    'NOT IN THIS REFERENCE' section).
    """
    included = set(included_type_names(config))
    kept = [s for s in graph["symbols"] if owning_type(s) in included]
    _, excluded_present, _ = classify(graph, config)
    return kept, excluded_present
