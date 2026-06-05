"""Flatten DocC article Markdown into plain Markdown for the agent-facing copy.

DocC articles authored under `CameraKit.docc/guides/` may use DocC directives
(`@Metadata { ... }`) and symbol/article links (`<doc:...>`). The DocC site
renders these; the flat copy under `Documentation/guides/` degrades them to
plain Markdown so a coding agent reads prose, code, and relative links directly.
"""

from __future__ import annotations

import os
import re


_DIRECTIVE = re.compile(r"^\s*@[A-Za-z]\w*")


def _strip_directive_blocks(text):
    """Remove DocC `@Directive { ... }` blocks and bare `@Directive` lines.

    Operates line-by-line and never touches content inside fenced code blocks,
    so Swift attributes (`@Environment`, `@unknown`, `@MainActor`, …) inside
    ```swift fences are preserved.
    """
    lines = text.split("\n")
    out = []
    i = 0
    in_fence = False
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(line)
            i += 1
            continue
        if not in_fence and _DIRECTIVE.match(line):
            # Find where the directive's brace block opens, if any (this line or
            # the next non-empty line). If it opens, consume until balanced.
            j = i
            while j < len(lines) and "{" not in lines[j] and lines[j].strip() != "":
                # A bare directive header with no following brace block.
                if j == i:
                    break
                j += 1
            if i < len(lines) and "{" in lines[i]:
                start = i
            elif j < len(lines) and "{" in lines[j] and lines[j].strip().startswith("{"):
                start = i
            else:
                i += 1  # bare `@Directive` line — drop it
                continue
            depth = 0
            k = start
            while k < len(lines):
                depth += lines[k].count("{") - lines[k].count("}")
                k += 1
                if depth <= 0:
                    break
            i = k
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def _rewrite_doc_links(text):
    """`<doc:Slug>` → relative `.md` link; `<doc:Type/member>` → code span."""

    def repl(m):
        target = m.group(1)
        if "/" in target:
            return f"`{target.replace('/', '.')}`"
        return f"[{target}]({target}.md)"

    return re.sub(r"<doc:([^>]+)>", repl, text)


def _rewrite_symbol_links(text):
    """Degrade DocC double-backtick symbol links to plain code spans.

    ``Type/member(_:)`` → `Type.member(_:)`; ``Type`` → `Type`. Lines inside
    fenced code blocks are left untouched.
    """
    out, in_fence = [], False
    for line in text.split("\n"):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            out.append(line)
            continue
        if in_fence:
            out.append(line)
            continue
        out.append(re.sub(r"``([^`]+)``", lambda m: f"`{m.group(1).replace('/', '.')}`", line))
    return "\n".join(out)


def _collapse_blank_lines(text):
    return re.sub(r"\n{3,}", "\n\n", text).strip("\n") + "\n"


def flatten(text):
    text = _strip_directive_blocks(text)
    text = _rewrite_doc_links(text)
    text = _rewrite_symbol_links(text)
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
