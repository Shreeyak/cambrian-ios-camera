"""Render the consumer API reference: symbol graph -> grouped Markdown clusters.

One Markdown file per non-empty cluster (see `cluster_map.json`). Each file lists
its types in cluster order; each type renders its signature, cleaned doc summary,
and members (initializers, cases, properties, methods). Doc text is stripped of
development-internal anchors (spec §9 hygiene) so the output is self-contained.
"""

from __future__ import annotations

import os
import re

import symbolgraph

# Development-internal references a consumer cannot resolve. Prose sentences
# containing any of these are dropped; inline occurrences are stripped.
INTERNAL_PATTERNS = [
    r"\bstate\.md\b",
    r"\bDECISIONS\.md\b",
    r"\bCONTRACTS\.md\b",
    r"\bStage[\s-]?\d+\b",
    r"\bPhase[\s-]?\d+[A-Za-z]?\b",
    r"\bADR-\d+\b",
    r"\b[DG]-\d+\b",
    r"\bdomain-revised/[\w./§-]+",
    r"\bConstants\.\w+",
    r"§[\w.]+",
]
_INTERNAL_RE = re.compile("|".join(INTERNAL_PATTERNS))

# Cluster slug -> display title (overrides simple title-casing).
CLUSTER_TITLES = {
    "camera-engine": "Camera Engine",
    "api-index": "API Reference Index",
}

# Any Markdown list item (parameter/return/throw docs and inline sub-bullets).
_DOC_BULLET = re.compile(r"^\s*-\s+")


def _strip_internal_parens(text):
    """Remove only the parentheticals that contain an internal token."""
    return re.sub(
        r"\s*\(([^()]*?)\)", lambda m: "" if _INTERNAL_RE.search(m.group(1)) else m.group(0), text
    )


def _tidy(text):
    text = re.sub(r"\s+;", ";", text)
    text = re.sub(r"\s+([.,])", r"\1", text)
    text = re.sub(r"\s{2,}", " ", text)
    return text.strip(" ;,")


def _strip_inline_internal(text):
    """Strip internal parentheticals and any bare internal tokens, then tidy."""
    text = _strip_internal_parens(text)
    text = _INTERNAL_RE.sub("", text)
    return _tidy(text)


def _clean_doc(lines):
    """Clean a docComment into Markdown, dropping internal-anchor sentences.

    Prose paragraphs come first; doc-markup bullets (`- Throws:` etc.) are kept
    as a parameters/returns/errors list with internal tokens stripped.
    """
    prose, bullets, cur = [], [], []
    in_bullets = False
    for raw in lines:
        line = raw.rstrip()
        if _DOC_BULLET.match(line):
            in_bullets = True
            if cur:
                bullets.append(" ".join(cur))
                cur = []
            cur = [line.strip()]
        elif in_bullets and line.strip() and (raw.startswith("  ") or raw.startswith("\t")):
            cur.append(line.strip())  # continuation of the current bullet
        elif in_bullets and not line.strip():
            if cur:
                bullets.append(" ".join(cur))
                cur = []
        else:
            prose.append(line)
    if cur:
        bullets.append(" ".join(cur))

    # Prose: split into sentences, drop those referencing internal anchors.
    prose_text = " ".join(p.strip() for p in prose).strip()
    kept = []
    for sent in re.split(r"(?<=[.!?])\s+", prose_text):
        if not sent.strip():
            continue
        # Strip incidental internal citations; drop the sentence only if an
        # internal reference SURVIVES (a genuine cross-reference like "see X").
        stripped = _strip_internal_parens(sent)
        if _INTERNAL_RE.search(stripped):
            continue
        cleaned = _tidy(stripped)
        if cleaned:
            kept.append(cleaned)
    out = []
    if kept:
        out.append(" ".join(s for s in kept if s).strip())
    cleaned_bullets = []
    for b in bullets:
        cb = _strip_inline_internal(b)
        if cb and cb != "-":
            cleaned_bullets.append(f"- {cb.lstrip('- ').strip()}" if not cb.startswith("-") else cb)
    if cleaned_bullets:
        out.append("\n".join(cleaned_bullets))
    return "\n\n".join(o for o in out if o).strip()


def _signature(symbol):
    return "".join(f["spelling"] for f in symbol.get("declarationFragments", []))


def _kind_label(symbol):
    spelled = _signature(symbol).split()
    for kw in ("actor", "class", "struct", "enum", "protocol", "typealias"):
        if kw in spelled:
            return kw.capitalize()
    return symbol["kind"]["identifier"].replace("swift.", "").capitalize()


_MEMBER_ORDER = {
    "swift.init": 0,
    "swift.enum.case": 1,
    "swift.type.property": 2,
    "swift.property": 3,
    "swift.type.method": 4,
    "swift.method": 5,
}


def _doc_lines(symbol):
    return [l["text"] for l in symbol.get("docComment", {}).get("lines", [])]


def _render_member(symbol):
    out = [f"### {symbol['names']['title']}", "", "```swift", _signature(symbol), "```"]
    doc = _clean_doc(_doc_lines(symbol))
    if doc:
        out += ["", doc]
    return "\n".join(out)


def _render_type(type_symbol, members):
    title = type_symbol["names"]["title"]
    out = [f"## {title}", "", f"*{_kind_label(type_symbol)}*", "", "```swift", _signature(type_symbol), "```"]
    doc = _clean_doc(_doc_lines(type_symbol))
    if doc:
        out += ["", doc]
    members = sorted(members, key=lambda s: (_MEMBER_ORDER.get(s["kind"]["identifier"], 9), s["names"]["title"]))
    for m in members:
        out += ["", _render_member(m)]
    return "\n".join(out)


def _cluster_title(slug):
    return CLUSTER_TITLES.get(slug, slug.replace("-", " ").title())


def _own_module_symbols(graph):
    """Drop symbols synthesized from non-module protocol conformances.

    Compiler-synthesized members of stdlib protocols (e.g. `Actor`'s
    `withSerialExecutor`, `assumeIsolated`) are emitted under this module's
    graph but carry a foreign USR prefix (`s:ScA…`) and no source `location`.
    Members the module actually declares carry the module USR prefix
    (`s:9CameraKit…`). Keep only the latter (plus all top-level types).
    """
    name = graph["module"]["name"]
    prefix = f"s:{len(name)}{name}"
    out, seen = [], set()
    for s in graph["symbols"]:
        usr = s.get("identifier", {}).get("precise", "")
        is_top = len(s["pathComponents"]) == 1
        if not is_top and not usr.startswith(prefix):
            continue
        if usr in seen:
            continue
        seen.add(usr)
        out.append(s)
    return out


def build(graph, config, out_dir):
    """Write one Markdown file per non-empty cluster. Returns written filenames."""
    os.makedirs(out_dir, exist_ok=True)
    by_type = {}
    for s in _own_module_symbols(graph):
        by_type.setdefault(symbolgraph.owning_type(s), []).append(s)

    written = []
    for slug, type_names in config["clusters"].items():
        present = [t for t in type_names if t in by_type]
        if not present:
            continue
        body = [f"# {_cluster_title(slug)}", ""]
        for tname in present:
            syms = by_type[tname]
            type_symbol = next((s for s in syms if len(s["pathComponents"]) == 1), None)
            members = [s for s in syms if len(s["pathComponents"]) > 1]
            if type_symbol is None:
                continue
            body.append(_render_type(type_symbol, members))
            body.append("")
        path = os.path.join(out_dir, f"{slug}.md")
        with open(path, "w") as f:
            f.write("\n".join(body).rstrip() + "\n")
        written.append(f"{slug}.md")
    return written


if __name__ == "__main__":
    import sys

    graph = symbolgraph.load_graph(sys.argv[1])
    config = symbolgraph.load_config(sys.argv[2])
    files = build(graph, config, sys.argv[3])
    print(f"wrote {len(files)} cluster files to {sys.argv[3]}")
