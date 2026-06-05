"""Flatten DocC article Markdown into plain Markdown for the agent-facing copy.

DocC articles authored under `CameraKit.docc/guides/` may use DocC directives
(`@Metadata { ... }`) and symbol/article links (`<doc:...>`). The DocC site
renders these; the flat copy under `Documentation/guides/` degrades them to
plain Markdown so a coding agent reads prose, code, and relative links directly.
"""

from __future__ import annotations

import os
import re


def _strip_directive_blocks(text):
    """Remove DocC `@Directive { ... }` blocks (brace-balanced) and bare `@Directive` lines."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        m = re.match(r"[ \t]*@[A-Za-z]+", text[i:])
        if m and (i == 0 or text[i - 1] == "\n"):
            j = i + m.end()
            # Skip whitespace to see if a brace block follows.
            k = j
            while k < n and text[k] in " \t":
                k += 1
            if k < n and text[k] == "{":
                depth = 0
                while k < n:
                    if text[k] == "{":
                        depth += 1
                    elif text[k] == "}":
                        depth -= 1
                        if depth == 0:
                            k += 1
                            break
                    k += 1
                while k < n and text[k] in " \t":
                    k += 1
                if k < n and text[k] == "\n":
                    k += 1
                i = k
                continue
            else:
                # Bare directive line — drop to end of line.
                while k < n and text[k] != "\n":
                    k += 1
                if k < n:
                    k += 1
                i = k
                continue
        nl = text.find("\n", i)
        if nl == -1:
            out.append(text[i:])
            break
        out.append(text[i : nl + 1])
        i = nl + 1
    return "".join(out)


def _rewrite_doc_links(text):
    """`<doc:Slug>` → relative `.md` link; `<doc:Type/member>` → code span."""

    def repl(m):
        target = m.group(1)
        if "/" in target:
            return f"`{target.replace('/', '.')}`"
        return f"[{target}]({target}.md)"

    return re.sub(r"<doc:([^>]+)>", repl, text)


def _collapse_blank_lines(text):
    return re.sub(r"\n{3,}", "\n\n", text).strip("\n") + "\n"


def flatten(text):
    text = _strip_directive_blocks(text)
    text = _rewrite_doc_links(text)
    return _collapse_blank_lines(text)


def flatten_dir(src_dir, dst_dir):
    """Flatten every `.md` under src_dir into dst_dir. Returns written filenames."""
    os.makedirs(dst_dir, exist_ok=True)
    written = []
    if not os.path.isdir(src_dir):
        return written
    for name in sorted(os.listdir(src_dir)):
        if not name.endswith(".md"):
            continue
        with open(os.path.join(src_dir, name)) as f:
            flat = flatten(f.read())
        with open(os.path.join(dst_dir, name), "w") as f:
            f.write(flat)
        written.append(name)
    return written


if __name__ == "__main__":
    import sys

    files = flatten_dir(sys.argv[1], sys.argv[2])
    print(f"flattened {len(files)} guides into {sys.argv[2]}")
