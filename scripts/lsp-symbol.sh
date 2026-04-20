#!/usr/bin/env bash
# lsp-symbol.sh — thin sourcekit-lsp wrapper for one-shot queries.
#
# Usage:
#   scripts/lsp-symbol.sh outline FILE           — documentSymbol (file outline)
#   scripts/lsp-symbol.sh hover FILE LINE COL    — hover at position (1-based)
#   scripts/lsp-symbol.sh workspace QUERY        — workspace symbol search
#
# Positions are 1-based as shown in editors; converted to 0-based for LSP.
#
# A short sleep runs between the query and the shutdown notification to let
# sourcekit-lsp finish processing before the stream closes.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  cat <<EOF >&2
usage:
  $0 outline FILE
  $0 hover FILE LINE COL
  $0 workspace QUERY
EOF
  exit 2
fi

SK=$(xcrun --find sourcekit-lsp)
OP="$1"; shift
ROOT_URI="file://$(pwd)"
DELAY="${LSP_DELAY:-5}"  # seconds to wait between query and shutdown

pack() {
  # Emit an LSP message: Content-Length header + JSON body.
  local body="$1"
  printf 'Content-Length: %d\r\n\r\n%s' "${#body}" "$body"
}

run_session() {
  # Stdin of this function feeds sourcekit-lsp; stdout is the server's responses.
  "$SK" 2>/dev/null
}

extract_result() {
  # Split response stream by Content-Length headers; keep the one with id == $1.
  local want_id="$1"
  awk 'BEGIN{RS="Content-Length: "} NR>1{sub(/^[0-9]+\r\n\r\n/,""); print}' \
    | jq -r --argjson id "$want_id" 'select(.id==$id) | .result' 2>/dev/null
}

case "$OP" in
  outline)
    FILE="$1"
    if [[ ! -f "$FILE" ]]; then echo "not a file: $FILE" >&2; exit 2; fi
    URI="file://$(realpath "$FILE")"
    TEXT=$(jq -Rs . < "$FILE")
    (
      pack "$(jq -nc --arg r "$ROOT_URI" '{jsonrpc:"2.0",id:1,method:"initialize",params:{processId:null,rootUri:$r,capabilities:{}}}')"
      pack '{"jsonrpc":"2.0","method":"initialized","params":{}}'
      pack "$(jq -nc --arg u "$URI" --argjson t "$TEXT" '{jsonrpc:"2.0",method:"textDocument/didOpen",params:{textDocument:{uri:$u,languageId:"swift",version:1,text:$t}}}')"
      pack "$(jq -nc --arg u "$URI" '{jsonrpc:"2.0",id:2,method:"textDocument/documentSymbol",params:{textDocument:{uri:$u}}}')"
      sleep "$DELAY"
      pack '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
      pack '{"jsonrpc":"2.0","method":"exit","params":null}'
    ) | run_session | extract_result 2
    ;;
  hover)
    FILE="$1"; LINE="$2"; COL="$3"
    if [[ ! -f "$FILE" ]]; then echo "not a file: $FILE" >&2; exit 2; fi
    URI="file://$(realpath "$FILE")"
    TEXT=$(jq -Rs . < "$FILE")
    L=$((LINE - 1)); C=$((COL - 1))
    (
      pack "$(jq -nc --arg r "$ROOT_URI" '{jsonrpc:"2.0",id:1,method:"initialize",params:{processId:null,rootUri:$r,capabilities:{}}}')"
      pack '{"jsonrpc":"2.0","method":"initialized","params":{}}'
      pack "$(jq -nc --arg u "$URI" --argjson t "$TEXT" '{jsonrpc:"2.0",method:"textDocument/didOpen",params:{textDocument:{uri:$u,languageId:"swift",version:1,text:$t}}}')"
      pack "$(jq -nc --arg u "$URI" --argjson l "$L" --argjson c "$C" '{jsonrpc:"2.0",id:2,method:"textDocument/hover",params:{textDocument:{uri:$u},position:{line:$l,character:$c}}}')"
      sleep "$DELAY"
      pack '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
      pack '{"jsonrpc":"2.0","method":"exit","params":null}'
    ) | run_session | extract_result 2
    ;;
  workspace)
    QUERY="$1"
    (
      pack "$(jq -nc --arg r "$ROOT_URI" '{jsonrpc:"2.0",id:1,method:"initialize",params:{processId:null,rootUri:$r,capabilities:{}}}')"
      pack '{"jsonrpc":"2.0","method":"initialized","params":{}}'
      pack "$(jq -nc --arg q "$QUERY" '{jsonrpc:"2.0",id:2,method:"workspace/symbol",params:{query:$q}}')"
      sleep "$DELAY"
      pack '{"jsonrpc":"2.0","id":3,"method":"shutdown","params":null}'
      pack '{"jsonrpc":"2.0","method":"exit","params":null}'
    ) | run_session | extract_result 2
    ;;
  *)
    echo "unknown operation: $OP" >&2
    exit 2
    ;;
esac
