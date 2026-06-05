"""Render `Documentation/index.md` — the consumer documentation router.

The file reads evidently as an index: it opens by describing its sections, every
section has a grep-able `## SECTION:` heading, the capability overview is a flat
list (each entry with `#### What it does` / `#### Where it's documented` linking
to guides only), and the API reference is a single link — symbols are not
enumerated here.
"""

from __future__ import annotations

import json


def load_content(path):
    with open(path) as f:
        return json.load(f)


def build(content):
    guides = content["guides"]
    out = ["# CameraKit Documentation", ""]
    out += [
        "This file is the index into the CameraKit consumer documentation. It",
        "routes you to the guides and the API reference; it contains no API",
        "descriptions itself. Each section below has a grep-able heading of the",
        "form `## SECTION: <name>`.",
        "",
    ]

    out += ["## SECTION: HOW TO USE THIS INDEX", ""]
    out += [
        "- **START HERE** — the required reading order for a first integration.",
        "- **GUIDES** — task-oriented guides, in reading order.",
        "- **CAPABILITIES** — what CameraKit can do, each linked to its guide.",
        "- **API REFERENCE** — per-symbol signatures, parameters, and errors.",
        "- **CONVENTIONS** — cross-cutting rules that apply throughout.",
        "",
    ]

    out += ["## SECTION: START HERE", ""]
    out += [
        f"Read [{guides[0]['title']}](guides/{guides[0]['file']}) then "
        f"[{guides[1]['title']}](guides/{guides[1]['file']}). The order of "
        "operations (construct → open → preview → capture → close) lives in the "
        "getting-started guide, not here.",
        "",
    ]

    out += ["## SECTION: GUIDES", ""]
    for g in guides:
        out.append(f"- [{g['title']}](guides/{g['file']}) — {g['summary']}")
    out.append("")

    out += ["## SECTION: CAPABILITIES", ""]
    for cap in content["capabilities"]:
        links = ", ".join(
            f"[{_guide_title(guides, f)}](guides/{f})" for f in cap["guides"]
        )
        out += [
            f"### CAPABILITY: {cap['name']}",
            "",
            "#### What it does",
            "",
            cap["what"],
            "",
            "#### Where it's documented",
            "",
            links,
            "",
        ]

    out += ["## SECTION: API REFERENCE", ""]
    out += [
        "Per-symbol signatures, parameters, returns, and errors are in the API",
        "reference. Start at [reference/api-index.md](reference/api-index.md).",
        "",
    ]

    out += ["## SECTION: CONVENTIONS", ""]
    for c in content["conventions"]:
        out.append(f"- {c}")
    out.append("")

    return "\n".join(out).rstrip() + "\n"


def _guide_title(guides, file):
    for g in guides:
        if g["file"] == file:
            return g["title"]
    return file


if __name__ == "__main__":
    import sys

    content = load_content(sys.argv[1])
    with open(sys.argv[2], "w") as f:
        f.write(build(content))
    print(f"wrote {sys.argv[2]}")
