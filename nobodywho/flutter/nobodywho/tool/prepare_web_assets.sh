#!/usr/bin/env bash
# Stitch together the FRB-compatible web assets for flutter_rust_bridge's
# loader, which expects wasm-pack's `--target no-modules` layout under
# `web/pkg/`:
#
#   web/pkg/nobodywho_flutter.js      ← shim (in this repo) + Emscripten glue
#   web/pkg/nobodywho_flutter_bg.wasm ← renamed copy of the Rust-built .wasm
#
# The shim file in-tree only contains the adapter; this script appends the
# generated Emscripten loader after the `/* === EMSCRIPTEN GLUE === */` marker
# and copies the wasm to its FRB-expected name. Run it any time the Rust crate
# is rebuilt for web (typically as part of `flutter build web` wiring, or
# manually during development).
#
# Usage:
#   tool/prepare_web_assets.sh [debug|release]
#
# Default profile is `release` since the debug wasm is ~12× larger.
set -euo pipefail

PROFILE="${1:-release}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PLUGIN_DIR}/../../.." && pwd)"

WASM_TARGET_DIR="${REPO_ROOT}/nobodywho/target/wasm32-unknown-emscripten/${PROFILE}"
SRC_JS="${WASM_TARGET_DIR}/nobodywho_flutter_web.js"
SRC_WASM="${WASM_TARGET_DIR}/nobodywho_flutter_web.wasm"

PKG_DIR="${PLUGIN_DIR}/web/pkg"
OUT_JS="${PKG_DIR}/nobodywho_flutter.js"
OUT_WASM="${PKG_DIR}/nobodywho_flutter_bg.wasm"

if [[ ! -f "${SRC_JS}" || ! -f "${SRC_WASM}" ]]; then
  echo "error: Rust-built web artifacts not found under ${WASM_TARGET_DIR}." >&2
  echo "       build them first with:" >&2
  echo "         cd nobodywho && cargo build --${PROFILE} \\" >&2
  echo "           -p nobodywho-flutter --bin nobodywho_flutter_web \\" >&2
  echo "           --target wasm32-unknown-emscripten" >&2
  exit 1
fi

mkdir -p "${PKG_DIR}"

# Drop the Emscripten glue after the shim's marker line. The shim file is
# source-controlled; this script regenerates only the portion below the
# marker. We write to a temp file and swap so the target stays atomically
# valid even if the script is killed mid-run.
TMP_JS="$(mktemp "${OUT_JS}.XXXXXX")"
trap 'rm -f "${TMP_JS}"' EXIT

awk 'BEGIN { keep=1 }
     /^\/\* === EMSCRIPTEN GLUE ===/ { print; keep=0; next }
     keep { print }' "${OUT_JS}" > "${TMP_JS}"

{
  echo ""
  echo "/* --- begin generated Emscripten loader (${PROFILE}) --- */"
  cat "${SRC_JS}"
  echo ""
  echo "/* --- end generated Emscripten loader --- */"
} >> "${TMP_JS}"

mv "${TMP_JS}" "${OUT_JS}"
trap - EXIT

cp "${SRC_WASM}" "${OUT_WASM}"

echo "prepare-web-assets: wrote ${OUT_JS} ($(wc -c < "${OUT_JS}" | tr -d ' ') bytes)"
echo "prepare-web-assets: wrote ${OUT_WASM} ($(wc -c < "${OUT_WASM}" | tr -d ' ') bytes)"
