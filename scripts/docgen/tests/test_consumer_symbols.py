import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import symbolgraph  # noqa: E402


def _type(name, kind="swift.struct"):
    return {
        "kind": {"identifier": kind},
        "names": {"title": name},
        "pathComponents": [name],
        "accessLevel": "public",
    }


def _member(owner, label, kind="swift.method"):
    return {
        "kind": {"identifier": kind},
        "names": {"title": label},
        "pathComponents": [owner, label],
        "accessLevel": "public",
    }


def _graph(symbols):
    return {"module": {"name": "CameraKit"}, "symbols": symbols, "relationships": []}


CONFIG = {
    "clusters": {"camera-engine": ["CameraEngine"]},
    "exclude": ["Watchdog"],
}


class ClassifyTests(unittest.TestCase):
    def test_filter_keeps_included_type_and_members_drops_excluded(self):
        graph = _graph(
            [
                _type("CameraEngine", "swift.class"),
                _member("CameraEngine", "open()"),
                _type("Watchdog", "swift.class"),
            ]
        )
        kept, excluded = symbolgraph.filter_symbols(graph, CONFIG)
        kept_titles = {symbolgraph.title(s) for s in kept}
        self.assertEqual(kept_titles, {"CameraEngine", "open()"})
        self.assertEqual(excluded, ["Watchdog"])

    def test_unclassified_type_is_reported(self):
        graph = _graph([_type("CameraEngine", "swift.class"), _type("Surprise")])
        included, excluded, unclassified = symbolgraph.classify(graph, CONFIG)
        self.assertEqual(included, ["CameraEngine"])
        self.assertEqual(excluded, [])
        self.assertEqual(unclassified, ["Surprise"])


if __name__ == "__main__":
    unittest.main()
