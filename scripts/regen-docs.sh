#!/usr/bin/env bash
# regen-docs.sh — regenerate the consumer documentation set in Documentation/.
#
# Pipeline: emit symbol graph → drift guard → render reference + api-index →
# render index → ensure guide stubs → flatten guides to Documentation/guides/.
#
# Regeneration is on-demand (run it after API or guide changes). The reference
# layer is fully generated; only the guides (DocC articles) are hand-authored.
#
# Usage: scripts/regen-docs.sh [--skip-emit]
#   --skip-emit  reuse the existing Documentation/reference/symbol-graph.json
#                (skips the slow device build; for fast guide/format iteration).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

DOCGEN="scripts/docgen"
CONFIG="$DOCGEN/cluster_map.json"
CONTENT="$DOCGEN/index_content.json"
DOCC_GUIDES="CameraKit/Sources/CameraKit/CameraKit.docc/guides"
OUT="Documentation"
REF="$OUT/reference"
SYMGRAPH="$REF/symbol-graph.json"

mkdir -p "$REF" "$OUT/guides"

# 1. Symbol graph (slow device build) unless reusing an existing one.
if [[ "${1:-}" == "--skip-emit" ]]; then
  [[ -f "$SYMGRAPH" ]] || { echo "no $SYMGRAPH to reuse; run without --skip-emit"; exit 1; }
  echo "regen-docs: reusing existing $SYMGRAPH"
else
  scripts/emit-symbol-graph.sh "$REF"
fi

# 2. Drift guard — every public top-level type must be classified.
python3 - "$SYMGRAPH" "$CONFIG" <<'PY'
import sys
sys.path.insert(0, "scripts/docgen")
import symbolgraph
graph = symbolgraph.load_graph(sys.argv[1])
config = symbolgraph.load_config(sys.argv[2])
_, _, unclassified = symbolgraph.classify(graph, config)
if unclassified:
    print("DRIFT: unclassified public types (add to cluster_map.json):")
    for t in unclassified:
        print(f"  - {t}")
    sys.exit(1)
print("drift guard: all public types classified")
PY

# 3. Reference clusters + api-index.
python3 "$DOCGEN/render_reference.py" "$SYMGRAPH" "$CONFIG" "$REF"
python3 "$DOCGEN/render_api_index.py" "$SYMGRAPH" "$CONFIG" "$REF/api-index.md"

# 4. Router index.
python3 "$DOCGEN/render_index.py" "$CONTENT" "$OUT/index.md"

# 5. Ensure guide stubs exist, then flatten DocC articles to the agent copy.
python3 "$DOCGEN/make_guide_stubs.py" "$CONTENT" "$DOCC_GUIDES"
python3 "$DOCGEN/flatten_guides.py" "$DOCC_GUIDES" "$OUT/guides"

echo "regen-docs: Documentation/ regenerated."
