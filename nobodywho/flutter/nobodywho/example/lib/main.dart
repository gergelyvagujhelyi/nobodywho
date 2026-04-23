// Minimal Flutter web smoke-test app for the nobodywho plugin.
//
// Calling `NobodyWho.init()` goes through flutter_rust_bridge's web loader
// (appends a <script src="pkg/nobodywho_flutter.js">, waits for it, calls
// `wasm_bindgen({module_or_path: 'pkg/nobodywho_flutter_bg.wasm'})`,
// cross-checks the Rust-side content hash against the one generated into
// `frb_generated.dart`). That single call exercises:
//
//   - the Rust → wasm32-unknown-emscripten build path
//   - our shim at `pkg/nobodywho_flutter.js` that adapts Emscripten's
//     `createNobodyWhoModule` factory to wasm-pack's `wasm_bindgen`
//     interface
//   - flutter_rust_bridge's Dart-side dispatcher talking to the wasm via
//     the generated bindings
//
// If init() returns cleanly we've proven end-to-end Dart → Rust in the
// browser. We surface the result on the page so `flutter run -d chrome`
// (or the equivalent `dart test -p chrome`) can visually confirm.
//
// No real model loading here: the aim of this example is to verify the
// binding plumbing works, not to do inference on a browser-bound GGUF
// (which has a 4 GB memory ceiling per tab and warrants its own test).
import 'package:flutter/material.dart';
import 'package:nobodywho/nobodywho.dart' as nobodywho;

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
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    _runSmoke();
  }

  Future<void> _runSmoke() async {
    try {
      await nobodywho.NobodyWho.init();
      setState(() {
        _ok = true;
        _status = 'NobodyWho.init() succeeded — wasm loaded, FRB dispatcher '
            'online, Rust content hash matches Dart-generated constant.';
      });
    } catch (err, stack) {
      setState(() {
        _ok = false;
        _status = 'NobodyWho.init() failed: $err\n\n$stack';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final okStyle = TextStyle(
      color: Colors.green.shade800,
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    );
    final errStyle = TextStyle(
      color: Colors.red.shade800,
      fontWeight: FontWeight.bold,
      fontFamily: 'monospace',
    );
    return MaterialApp(
      title: 'nobodywho smoke',
      home: Scaffold(
        appBar: AppBar(title: const Text('nobodywho smoke')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(_status, style: _ok ? okStyle : errStyle),
        ),
      ),
    );
  }
}
