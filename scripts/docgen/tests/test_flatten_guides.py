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

Use ``CameraEngine/open(configuration:)`` to get ``SessionCapabilities``.

```swift
@Environment(\\.scenePhase) private var scenePhase
switch scenePhase {
case .active: await engine.setLifecyclePhase(.active)
@unknown default: break
}
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

    def test_symbol_links_degrade_to_code_spans(self):
        self.assertIn("`CameraEngine.open(configuration:)`", self.out)
        self.assertIn("`SessionCapabilities`", self.out)
        # No inline double-backtick symbol links remain outside code fences.
        prose = "\n".join(l for l in self.out.split("\n") if not l.lstrip().startswith("```"))
        self.assertNotIn("``", prose)

    def test_prose_and_code_preserved(self):
        self.assertIn("Forward every phase.", self.out)
        self.assertIn("await engine.setLifecyclePhase(.active)", self.out)
        self.assertIn("```swift", self.out)

    def test_swift_attributes_inside_fences_survive(self):
        # @-attributes inside a code fence must NOT be stripped as directives.
        self.assertIn("@Environment(\\.scenePhase) private var scenePhase", self.out)
        self.assertIn("@unknown default: break", self.out)


if __name__ == "__main__":
    unittest.main()
