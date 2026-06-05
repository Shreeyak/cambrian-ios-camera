"""Create placeholder guide articles in the DocC catalog for any guide named in
the manifest that does not yet exist. Phase B replaces stubs with real content;
this keeps the index links resolvable in the meantime. Existing files are never
overwritten.
"""

from __future__ import annotations

import os
import sys

from render_index import load_content

STUB = """# {title}

@Metadata {{
    @PageKind(article)
}}

> Status: stub — to be authored in Phase B.

{summary}
"""


def make_stubs(content_path, guides_dir):
    content = load_content(content_path)
    os.makedirs(guides_dir, exist_ok=True)
    created = []
    for g in content["guides"]:
        path = os.path.join(guides_dir, g["file"])
        if os.path.exists(path):
            continue
        with open(path, "w") as f:
            f.write(STUB.format(title=g["title"], summary=g["summary"]))
        created.append(g["file"])
    return created


if __name__ == "__main__":
    created = make_stubs(sys.argv[1], sys.argv[2])
    print(f"created {len(created)} guide stub(s)")
