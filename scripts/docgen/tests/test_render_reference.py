import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import render_reference  # noqa: E402


def _doc(*lines):
    return {"lines": [{"text": t} for t in lines]}


class CleanDocTests(unittest.TestCase):
    def test_drops_internal_anchor_sentences_keeps_throws(self):
        lines = [
            "Applies a true crop.",
            "",
            "Overrides state.md #67 (which recommended dropping this API); see DECISIONS.md.",
            "",
            "- Throws: `EngineError.notOpen` if the session is not open.",
        ]
        out = render_reference._clean_doc(lines)
        self.assertIn("Applies a true crop.", out)
        self.assertIn("Throws", out)
        self.assertIn("EngineError.notOpen", out)
        for forbidden in ("state.md", "DECISIONS", "#67", "ADR-"):
            self.assertNotIn(forbidden, out)

    def test_strips_inline_adr_parenthetical(self):
        out = render_reference._clean_doc(["Runs on the session queue (ADR-07) for safety."])
        self.assertNotIn("ADR-07", out)
        self.assertIn("session queue", out)


class RenderTypeTests(unittest.TestCase):
    def test_type_and_member_render(self):
        type_symbol = {
            "kind": {"identifier": "swift.class"},
            "names": {"title": "CameraEngine"},
            "pathComponents": ["CameraEngine"],
            "declarationFragments": [{"spelling": "actor "}, {"spelling": "CameraEngine"}],
            "docComment": _doc("The camera engine."),
        }
        member = {
            "kind": {"identifier": "swift.method"},
            "names": {"title": "setCropRegion(_:)"},
            "pathComponents": ["CameraEngine", "setCropRegion(_:)"],
            "declarationFragments": [{"spelling": "func setCropRegion(_ rect: Rect) async throws"}],
            "docComment": _doc("Sets the crop."),
        }
        md = render_reference._render_type(type_symbol, [member])
        self.assertIn("## CameraEngine", md)
        self.assertIn("*Actor*", md)
        self.assertIn("### setCropRegion(_:)", md)
        self.assertIn("func setCropRegion(_ rect: Rect) async throws", md)


if __name__ == "__main__":
    unittest.main()
