// Entry point for the wasm32-unknown-emscripten bin target.
// wasm-bindgen rewrites the linked .wasm to expose all #[wasm_bindgen]
// exports from the lib crate; main() exists only to satisfy wasm-ld,
// which insists on a `main` symbol for standalone wasm.
use nobodywho_flutter as _;

fn main() {}
