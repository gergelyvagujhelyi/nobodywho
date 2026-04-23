import 'package:http/http.dart' as http;
import 'package:nobodywho/nobodywho.dart' as nobodywho;

// Small Q4 Qwen model — chosen to fit inside a browser tab's memory budget
// (a typical tab caps at ~4 GB and can OOM well before that, so we stay
// conservative). The URL resolves directly to the `.gguf` bytes on
// HuggingFace's CDN with no auth required.
const _modelUrl =
    'https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF/resolve/main/Qwen_Qwen3-0.6B-Q4_K_M.gguf';

Future<nobodywho.Model> loadTestModel() async {
  final response = await http.get(Uri.parse(_modelUrl));
  if (response.statusCode != 200) {
    throw StateError(
      'Failed to download test model from $_modelUrl '
      '(HTTP ${response.statusCode})',
    );
  }
  return nobodywho.Model.fromBytes(data: response.bodyBytes);
}

// `Encoder` and `CrossEncoder` use `llama_pooling_type` and sequence-length
// helpers from `llama-cpp-2` that are cfg-gated out on `target_arch = "wasm32"`
// (see `nobodywho/core/src/encoder.rs` and `crossencoder.rs`). Until those
// paths get a wasm-compatible backend, they remain unavailable on web —
// return `null` so shared tests can skip the relevant suites.
Future<nobodywho.Encoder?> loadTestEncoder() async => null;
Future<nobodywho.CrossEncoder?> loadTestCrossEncoder() async => null;
