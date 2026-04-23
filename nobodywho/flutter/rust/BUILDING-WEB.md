# Building `nobodywho-flutter` for the web (`wasm32-unknown-emscripten`)

This crate has a `nobodywho_flutter_web` bin target that compiles the Flutter Rust Bridge surface to WebAssembly via Emscripten + wasm-bindgen, for eventual use in Flutter web.

**Status:** proof-of-concept. The bin builds cleanly and the produced wasm loads and instantiates in Node. The Dart-side wiring (`load_model_web.dart`, `resolve_binary.dart` web path) is not yet complete.

## Prerequisites

The build depends on toolchain pieces that are not on a stock system:

- **Emscripten:** we need [walkingeyerobot's fork](https://github.com/walkingeyerobot/emscripten) of Emscripten, which adds `-sWASM_BINDGEN` support (draft upstream PR: [emscripten-core/emscripten#23493](https://github.com/emscripten-core/emscripten/pull/23493)). This is provided by the Nix flake's overlay, so you don't install it manually.
- **wasm-bindgen-cli 0.2.118:** pinned in `flake.nix`.
- **A patched `flutter_rust_bridge`:** `nobodywho/Cargo.toml` contains a `[patch.crates-io]` entry that redirects `flutter_rust_bridge` to a fork branch with the `wasm_bindgen::module()` call cfg-gated out on emscripten. Upstream PR: [fzyzcjy/flutter_rust_bridge#3062](https://github.com/fzyzcjy/flutter_rust_bridge/pull/3062). Once merged and released, drop the patch entry.

## Build

From the repository root:

```bash
nix develop
# then inside the shell:
cd nobodywho
cargo build --release -p nobodywho-flutter \
            --bin nobodywho_flutter_web \
            --target wasm32-unknown-emscripten
```

First `nix develop` is slow (pulls the emscripten fork, test models, etc.). Subsequent runs reuse the store.

Artifacts land in `nobodywho/target/wasm32-unknown-emscripten/release/`:
- `nobodywho_flutter_web.wasm` (~15 MB release / ~184 MB debug)
- `nobodywho_flutter_web.js` (emscripten loader wrapping `createNobodyWhoModule()`)

## Smoke-test in Node

```bash
node --experimental-wasm-modules -e "
  const m = require('./nobodywho/target/wasm32-unknown-emscripten/release/nobodywho_flutter_web.js');
  m({ locateFile: n => './nobodywho/target/wasm32-unknown-emscripten/release/' + n }).then(
    mod => console.log(Object.keys(mod).filter(k => k.startsWith('_frb_'))));
"
```

If you see `_frb_dart_fn_deliver_output`, `_frb_pde_ffi_dispatcher_primary`, etc., the wasm is structurally live.

## Known tech debt

All documented in-source with removal conditions:
1. `flake.nix` pins the `wasm-bindgen-cli` src + vendor hashes. Update on every version bump.
2. `nobodywho/Cargo.toml` has `[patch.crates-io]` pointing at a personal `flutter_rust_bridge` fork branch. Remove when the upstream PR ships.
3. `flutter/rust/build.rs` passes `-Wno-undefined` on emscripten to skip emcc's check that every symbol in `EXPORTED_FUNCTIONS` is defined (wasm-bindgen populates the list speculatively with externref intrinsics that aren't generated on this target). Revisit if emcc/wasm-bindgen integration gets smarter about this.

## Not yet done

- **Dart integration.** `nobodywho/flutter/nobodywho/test/load_model_web.dart` is still an `UnimplementedError` stub. A Flutter web app can't load the produced wasm until that and `resolve_binary.dart` are wired for the web platform.
- **CI.** No workflow yet targets `wasm32-unknown-emscripten`.
- **Runtime end-to-end.** Loading a GGUF model in-browser and generating a token has not been demonstrated. Browser tabs cap at ~4 GB of memory, so small / heavily quantised models only.
