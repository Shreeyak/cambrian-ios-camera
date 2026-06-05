import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import render_api_index  # noqa: E402


def _type(name):
    return {
        "kind": {"identifier": "swift.struct"},
        "names": {"title": name},
        "pathComponents": [name],
        "identifier": {"precise": f"s:9CameraKit{name}"},
    }


GRAPH = {
    "module": {"name": "CameraKit"},
    "symbols": [_type("CameraSettings"), _type("CameraMode"), _type("Watchdog")],
    "relationships": [],
}
CONFIG = {
    "clusters": {"camera-settings": ["CameraSettings", "CameraMode"]},
    "exclude": ["Watchdog"],
}


class ApiIndexTests(unittest.TestCase):
    def setUp(self):
        self.md = render_api_index.build(GRAPH, CONFIG)

    def test_has_four_sections(self):
        for section in (
            "## SECTION: HOW THE REFERENCE IS ORGANIZED",
            "## SECTION: SYMBOL → FILE",
            "## SECTION: BY CLUSTER",
            "## SECTION: NOT IN THIS REFERENCE",
        ):
            self.assertIn(section, self.md)

    def test_symbol_file_table_maps_each_type(self):
        self.assertIn("| `CameraSettings` | [camera-settings.md](camera-settings.md) |", self.md)
        self.assertIn("| `CameraMode` | [camera-settings.md](camera-settings.md) |", self.md)

    def test_excluded_type_listed_not_mapped(self):
        not_in = self.md.split("## SECTION: NOT IN THIS REFERENCE")[1]
        self.assertIn("`Watchdog`", not_in)
        # Watchdog must not appear in the SYMBOL → FILE table.
        sym_table = self.md.split("## SECTION: SYMBOL → FILE")[1].split("## SECTION: BY CLUSTER")[0]
        self.assertNotIn("Watchdog", sym_table)


if __name__ == "__main__":
    unittest.main()
