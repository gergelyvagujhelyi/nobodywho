// Flutter web smoke-test app for the nobodywho plugin — end-to-end version.
//
// The init-only check in an earlier revision of this file proved that the
// wasm loads and FRB's dispatcher round-trips. This version goes further:
// it fetches a small GGUF that the local http server stages next to the
// built app (see `web/models/model.gguf`; gitignored), hands the bytes to
// `Model.fromBytes`, starts a `Chat`, asks one short question, and streams
// the response onto the page.
//
// Touching every layer: Rust llama.cpp → Emscripten-compiled wasm → our
// shim at pkg/nobodywho_flutter.js → FRB dispatcher → Dart wrapper → UI.
// If the status turns green with a generated answer, the plugin is
// genuinely running an LLM in the browser.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:nobodywho/nobodywho.dart' as nobodywho;

// Where `prepare_web_assets.sh` stages the model. Served by Flutter's
// build tooling under `/models/model.gguf`. Not downloaded lazily over
// the internet: a tab can't cleanly handle a 400 MB transfer AND a large
// wasm instantiation on a cold page, so the expectation is that this
// file was fetched once ahead of time to the example's web/ directory.
const _modelPath = 'models/model.gguf';

void main() {
  runApp(const NobodyWhoSmokeApp());
}

class NobodyWhoSmokeApp extends StatefulWidget {
  const NobodyWhoSmokeApp({super.key});

  @override
  State<NobodyWhoSmokeApp> createState() => _NobodyWhoSmokeAppState();
}

class _NobodyWhoSmokeAppState extends State<NobodyWhoSmokeApp> {
  String _status = 'initialising NobodyWho…';
  String _answer = '';
  bool _ok = false;
  bool _inferenceRunning = false;

  @override
  void initState() {
    super.initState();
    _runInit();
  }

  Future<void> _runInit() async {
    try {
      await nobodywho.NobodyWho.init();
      setState(() {
        _ok = true;
        _status = 'NobodyWho.init() succeeded — wasm loaded, FRB dispatcher '
            'online. Starting inference automatically…';
      });
      // Chain straight into inference so a headless smoke test doesn't need
      // to synthesize a button click to exercise the full Dart → Rust → Dart
      // round trip. Interactive users can still press the button again to
      // re-run.
      await _runInference();
    } catch (err, stack) {
      setState(() {
        _ok = false;
        _status = 'NobodyWho.init() failed: $err\n\n$stack';
      });
    }
  }

  Future<void> _runInference() async {
    if (_inferenceRunning) return;
    setState(() {
      _inferenceRunning = true;
      _answer = '';
      _status = 'fetching model bytes from $_modelPath …';
    });
    try {
      final resp = await http.get(Uri.parse(_modelPath));
      if (resp.statusCode != 200) {
        throw StateError('model fetch returned HTTP ${resp.statusCode}');
      }
      final Uint8List bytes = resp.bodyBytes;
      setState(() => _status =
          'fetched ${(bytes.lengthInBytes / (1024 * 1024)).toStringAsFixed(1)} MB — '
          'calling Model.fromBytes …');

      final model = await nobodywho.Model.fromBytes(data: bytes);
      setState(() => _status = 'model loaded — building Chat …');

      final chat = nobodywho.Chat(model: model, contextSize: 512);
      setState(() => _status = 'asking the model …');

      // `TokenStream` extends `Stream<String>`, so iterate for per-token
      // UI updates instead of awaiting the full response in one go.
      final stream = chat.ask('Is water wet? Answer in one short sentence.');
      await for (final token in stream) {
        setState(() => _answer += token);
      }

      setState(() {
        _ok = true;
        _status = 'done. End-to-end Rust inference ran in the browser.';
        _inferenceRunning = false;
      });
    } catch (err, stack) {
      setState(() {
        _ok = false;
        _status = 'inference failed: $err\n\n$stack';
        _inferenceRunning = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final statusStyle = TextStyle(
      color: _ok ? Colors.green.shade800 : Colors.red.shade800,
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    );
    return MaterialApp(
      title: 'nobodywho smoke',
      home: Scaffold(
        appBar: AppBar(title: const Text('nobodywho smoke')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(_status, style: statusStyle),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _inferenceRunning ? null : _runInference,
                child: Text(
                  _inferenceRunning ? 'running…' : 'Run inference',
                ),
              ),
              const SizedBox(height: 24),
              if (_answer.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: SelectableText(
                    _answer,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
