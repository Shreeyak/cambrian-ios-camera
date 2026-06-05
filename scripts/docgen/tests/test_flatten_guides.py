import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import flatten_guides  # noqa: E402

ARTICLE = """# Lifecycle

@Metadata {
    @PageKind(article)
}

Forward every phase. See <doc:02-getting-started> first.

Call <doc:CameraEngine/setCropRegion(_:)> to crop.

```swift
await engine.setLifecyclePhase(.active)
```
"""


class FlattenTests(unittest.TestCase):
    def setUp(self):
        self.out = flatten_guides.flatten(ARTICLE)

    def test_directive_block_stripped(self):
        self.assertNotIn("@Metadata", self.out)
        self.assertNotIn("@PageKind", self.out)

    def test_article_doc_link_becomes_relative_md(self):
        self.assertIn("[02-getting-started](02-getting-started.md)", self.out)

    def test_symbol_doc_link_becomes_code_span(self):
        self.assertIn("`CameraEngine.setCropRegion(_:)`", self.out)

    def test_prose_and_code_preserved(self):
        self.assertIn("Forward every phase.", self.out)
        self.assertIn("await engine.setLifecyclePhase(.active)", self.out)
        self.assertIn("```swift", self.out)


if __name__ == "__main__":
    unittest.main()
