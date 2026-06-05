import os
import re
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import render_index  # noqa: E402

CONTENT = {
    "guides": [
        {"file": "01-overview.md", "title": "Overview", "summary": "What it is."},
        {"file": "02-getting-started.md", "title": "Getting started", "summary": "First run."},
        {"file": "03-lifecycle.md", "title": "Lifecycle", "summary": "Phases."},
    ],
    "capabilities": [
        {"name": "Lifecycle", "what": "Keep the camera correct.", "guides": ["03-lifecycle.md"]}
    ],
    "conventions": ["The engine is an actor."],
}


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.md = render_index.build(CONTENT)

    def test_all_sections_are_greppable(self):
        sections = re.findall(r"^## SECTION: .+$", self.md, re.M)
        for expected in (
            "## SECTION: HOW TO USE THIS INDEX",
            "## SECTION: START HERE",
            "## SECTION: GUIDES",
            "## SECTION: CAPABILITIES",
            "## SECTION: API REFERENCE",
            "## SECTION: CONVENTIONS",
        ):
            self.assertIn(expected, sections)

    def test_capability_entry_has_two_subheadings_and_guide_link(self):
        block = self.md.split("### CAPABILITY: Lifecycle")[1]
        self.assertIn("#### What it does", block)
        self.assertIn("#### Where it's documented", block)
        self.assertIn("(guides/03-lifecycle.md)", block)

    def test_capabilities_is_flat_list_not_table(self):
        caps = self.md.split("## SECTION: CAPABILITIES")[1].split("## SECTION: API REFERENCE")[0]
        self.assertNotIn("|", caps)  # no markdown table pipes

    def test_api_reference_links_index_without_enumerating_symbols(self):
        ref = self.md.split("## SECTION: API REFERENCE")[1].split("## SECTION: CONVENTIONS")[0]
        self.assertIn("reference/api-index.md", ref)


if __name__ == "__main__":
    unittest.main()
