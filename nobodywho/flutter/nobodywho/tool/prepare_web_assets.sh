#!/usr/bin/env bash
# Stitch together the FRB-compatible web assets for flutter_rust_bridge's
# loader, which expects wasm-pack's `--target no-modules` layout under
# `web/pkg/`:
#
#   web/pkg/nobodywho_flutter.js      ← shim + Emscripten glue (generated)
#   web/pkg/nobodywho_flutter_bg.wasm ← renamed copy of the Rust-built .wasm
#
# Source-controlled inputs:
#   web/pkg/nobodywho_flutter.shim.js ← adapter wrapping createNobodyWhoModule
#
# The shim file in-tree is the stable source-of-truth; this script
# concatenates it with the freshly-built Emscripten loader (after the
# shim's `/* === EMSCRIPTEN GLUE === */` marker line) into the generated
# `nobodywho_flutter.js`. Run after any Rust-for-web rebuild.
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
EXAMPLE_PKG_DIR="${PLUGIN_DIR}/example/web/pkg"
SHIM_JS="${PKG_DIR}/nobodywho_flutter.shim.js"
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

if [[ ! -f "${SHIM_JS}" ]]; then
  echo "error: shim source not found at ${SHIM_JS}." >&2
  echo "       this file is source-controlled — make sure you're on a" >&2
  echo "       checkout of the nobodywho wasm branch with the FRB shim" >&2
  echo "       committed alongside the example app." >&2
  exit 1
fi

# Concatenate the source-controlled shim and the freshly-built Emscripten
# loader into the generated `.js` Flutter serves. Write to a temp file and
# swap so the target stays atomically valid even if the script is killed
# mid-run. The generated file is `.gitignore`d (see `web/pkg/.gitignore`).
TMP_JS="$(mktemp "${OUT_JS}.XXXXXX")"
trap 'rm -f "${TMP_JS}"' EXIT

cat "${SHIM_JS}" > "${TMP_JS}"
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
# Emscripten's generated glue has the wasm filename baked in as
# `nobodywho_flutter_web.wasm` (from the Cargo `[[bin]] name`) and eagerly
# fetches it at script-load time — before the factory is invoked, so before
# our `locateFile` override has a chance to rewrite the URL. Staging a copy
# under that exact name in the same directory satisfies that early fetch;
# FRB's later `wasm_bindgen({module_or_path: 'pkg/<stem>_bg.wasm'})` call
# still goes through `locateFile` and uses the canonical `_bg.wasm` copy.
cp "${SRC_WASM}" "${PKG_DIR}/nobodywho_flutter_web.wasm"

echo "prepare-web-assets: wrote ${OUT_JS} ($(wc -c < "${OUT_JS}" | tr -d ' ') bytes)"
echo "prepare-web-assets: wrote ${OUT_WASM} ($(wc -c < "${OUT_WASM}" | tr -d ' ') bytes)"
echo "prepare-web-assets: wrote ${PKG_DIR}/nobodywho_flutter_web.wasm (alias for emcc early fetch)"

# Flutter doesn't copy a plugin's own `web/` directory into the final build
# output of a consuming app — it only merges the app's own `web/`. So also
# stage the same pair under the example app's `web/pkg/` (if present) so
# `flutter run -d chrome` / `flutter build web` from the example picks them
# up automatically.
if [[ -d "${PLUGIN_DIR}/example/web" ]]; then
  mkdir -p "${EXAMPLE_PKG_DIR}"
  cp "${OUT_JS}" "${EXAMPLE_PKG_DIR}/nobodywho_flutter.js"
  cp "${OUT_WASM}" "${EXAMPLE_PKG_DIR}/nobodywho_flutter_bg.wasm"
  cp "${OUT_WASM}" "${EXAMPLE_PKG_DIR}/nobodywho_flutter_web.wasm"
  echo "prepare-web-assets: also staged under ${EXAMPLE_PKG_DIR}/"
fi
