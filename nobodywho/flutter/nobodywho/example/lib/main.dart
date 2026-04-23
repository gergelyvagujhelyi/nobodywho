// Flutter web chat demo for the nobodywho plugin — the Flutter analogue of
// the standalone HTML demo on the `feat/wasm-backend-trait` branch.
//
// What's covered:
//   - `NobodyWho.init()` on startup (wasm load + FRB dispatcher setup).
//   - A model URL input + "Load model" button that fetches GGUF bytes and
//     hands them to `Model.fromBytes`, with a byte-accurate progress bar.
//   - Editable system prompt + context size.
//   - Running chat with message bubbles, user text input, send on Enter.
//   - An on-page debug log mirrored from `print` / `debugPrint`, so users
//     can copy-paste what happened without opening DevTools.
//   - A status banner that tracks the phase of the app.
//
// What's intentionally *not* here (compared to the wllama demo):
//   - IndexedDB model caching — the wllama demo re-uses the browser's
//     cache API; Flutter web's `http` package doesn't, so every reload
//     re-downloads. Reasonable for a single-shot proof-of-concept, not
//     production. A follow-up could plug in `package:idb_shim`.
//   - Engine selection (mock vs real) — there's only one engine here
//     (the plugin itself).
//   - Per-token streaming in the UI. Our single-threaded wasm runs the
//     worker inline, so every token is emitted before `ask(...)` returns;
//     the UI sees the answer as one block. See
//     `core/src/chat.rs::ChatHandleAsync::new` for the wasm32 branch.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:nobodywho/nobodywho.dart' as nobodywho;

void main() {
  runApp(const NobodyWhoDemoApp());
}

enum _Phase { loading, ready, loadingModel, chatting, generating, error }

class _ChatMessage {
  _ChatMessage(this.role, this.text);
  final String role; // 'user' or 'assistant'
  String text;
}

class NobodyWhoDemoApp extends StatelessWidget {
  const NobodyWhoDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NobodyWho — Flutter web demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        useMaterial3: true,
      ),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  // Defaults the local prepare-web-assets pipeline stages under
  // `example/web/models/model.gguf`. For a remote model, paste a
  // HuggingFace `resolve/main/...gguf` URL.
  final _modelUrlCtrl = TextEditingController(text: 'models/model.gguf');
  // 512 fits comfortably under the 4 GB wasm memory cap alongside a
  // ~500 MB Q4 GGUF + MEMFS double-buffering + llama.cpp scratch. 2048
  // is the typical chat default on native but blows the ceiling on web
  // for models in this size class.
  final _contextSizeCtrl = TextEditingController(text: '512');
  final _systemPromptCtrl =
      TextEditingController(text: 'You are a helpful assistant.');
  final _userInputCtrl = TextEditingController();
  final _chatScrollCtrl = ScrollController();

  _Phase _phase = _Phase.loading;
  String _status = 'Initialising NobodyWho…';
  String? _error;

  double? _downloadProgress; // 0..1 when a fetch is in-flight
  int? _downloadedBytes;
  int? _totalBytes;

  nobodywho.Model? _model;
  nobodywho.Chat? _chat;
  final List<_ChatMessage> _history = [];

  final List<_LogEntry> _log = [];

  @override
  void initState() {
    super.initState();
    _mirrorPrintIntoLog();
    _runInit();
  }

  @override
  void dispose() {
    _modelUrlCtrl.dispose();
    _contextSizeCtrl.dispose();
    _systemPromptCtrl.dispose();
    _userInputCtrl.dispose();
    _chatScrollCtrl.dispose();
    super.dispose();
  }

  void _mirrorPrintIntoLog() {
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message == null) return;
      final ts = DateTime.now().toIso8601String().substring(11, 19);
      _log.add(_LogEntry(ts, message, _LogLevel.info));
      // Trim to keep the page responsive if the log runs long.
      if (_log.length > 500) _log.removeRange(0, _log.length - 500);
      if (mounted) setState(() {});
      // Forward to the real console so DevTools still sees it.
      // ignore: avoid_print
      print(message);
    };
  }

  void _logError(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 19);
    _log.add(_LogEntry(ts, message, _LogLevel.error));
    if (mounted) setState(() {});
  }

  Future<void> _runInit() async {
    try {
      await nobodywho.NobodyWho.init();
      setState(() {
        _phase = _Phase.ready;
        _status = 'Ready. Paste a model URL (or keep the default) and click '
            '"Load model".';
      });
    } catch (err, stack) {
      _logError('NobodyWho.init() failed: $err\n$stack');
      setState(() {
        _phase = _Phase.error;
        _error = '$err';
        _status = 'NobodyWho.init() failed.';
      });
    }
  }

  Future<void> _loadModel() async {
    final url = _modelUrlCtrl.text.trim();
    if (url.isEmpty) return;
    final nCtx = int.tryParse(_contextSizeCtrl.text.trim()) ?? 2048;

    setState(() {
      _phase = _Phase.loadingModel;
      _status = 'Fetching $url …';
      _error = null;
      _downloadProgress = null;
      _downloadedBytes = 0;
      _totalBytes = null;
    });

    try {
      // Streamed fetch so the progress bar advances byte by byte rather
      // than sitting at 0 then jumping to 100.
      //
      // Accumulate into a `BytesBuilder`, not a `List<int>`. On Flutter
      // web a plain `List<int>` is backed by a JS Array of 64-bit doubles
      // (one per element), so a 272 MB GGUF balloons to ~2.2 GB of JS
      // heap _before_ the bytes even reach Rust — Chrome kills the tab
      // for OOM long before `Model.fromBytes` sees anything.
      // `BytesBuilder` is byte-packed (Uint8List-backed) and turns the
      // accumulation into a single O(n) copy at the end.
      final request = http.Request('GET', Uri.parse(url));
      final response = await http.Client().send(request);
      if (response.statusCode != 200) {
        throw StateError('model fetch returned HTTP ${response.statusCode}');
      }
      final total = response.contentLength;
      setState(() => _totalBytes = total);

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        builder.add(chunk);
        _downloadedBytes = builder.length;
        if (total != null && total > 0) {
          _downloadProgress = builder.length / total;
        }
        if (mounted) setState(() {});
      }
      final bytes = builder.toBytes();
      setState(() {
        _status =
            'Fetched ${_fmtBytes(bytes.lengthInBytes)}. Calling Model.fromBytes …';
        _downloadProgress = null;
      });

      final model = await nobodywho.Model.fromBytes(data: bytes);
      setState(() => _status = 'Model loaded. Building Chat …');

      final chat = nobodywho.Chat(
        model: model,
        contextSize: nCtx,
        systemPrompt: _systemPromptCtrl.text,
      );

      setState(() {
        _model = model;
        _chat = chat;
        _phase = _Phase.chatting;
        _status = 'Chat ready. Type a message and hit Send.';
        _history.clear();
      });
    } catch (err, stack) {
      _logError('Model load failed: $err\n$stack');
      setState(() {
        _phase = _Phase.error;
        _error = '$err';
        _status = 'Model load failed.';
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _userInputCtrl.text.trim();
    if (text.isEmpty) return;
    final chat = _chat;
    if (chat == null) return;

    setState(() {
      _history.add(_ChatMessage('user', text));
      _history.add(_ChatMessage('assistant', ''));
      _userInputCtrl.clear();
      _phase = _Phase.generating;
      _status = 'Generating… (UI will freeze while the single-threaded wasm '
          'worker runs inference — see ChatHandleAsync wasm32 branch)';
    });
    _scrollChatToBottom();

    // Give Flutter at least one frame to paint the "Generating…" state
    // before `ask(…)` kicks off the synchronous wasm inference, which
    // blocks the main task until completion. Two frames are belt-and-
    // suspenders in case the layout needed another pass (AppBar /
    // SafeArea insets etc.). Without this the banner and spinner don't
    // render until the whole answer is already in, which looks like a
    // full app freeze to the user.
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(Duration.zero);

    try {
      final stream = chat.ask(text);
      await for (final token in stream) {
        _history.last.text += token;
        if (mounted) setState(() {});
        _scrollChatToBottom();
      }
      setState(() {
        _phase = _Phase.chatting;
        _status = 'Chat ready.';
      });
    } catch (err, stack) {
      _logError('ask() failed: $err\n$stack');
      setState(() {
        _history.last.text += '\n[error: $err]';
        _phase = _Phase.chatting;
        _status = 'Error — see log.';
      });
    }
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollCtrl.hasClients) return;
      _chatScrollCtrl.animateTo(
        _chatScrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  static String _fmtBytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
    if (n < 1024 * 1024 * 1024) {
      return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(n / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NobodyWho — Flutter web demo'),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 820),
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildStatusBanner(),
              const SizedBox(height: 12),
              _buildModelSection(),
              const SizedBox(height: 12),
              _buildSystemPromptSection(),
              const SizedBox(height: 12),
              _buildChatSection(),
              const SizedBox(height: 12),
              _buildLogSection(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBanner() {
    final scheme = Theme.of(context).colorScheme;
    Color bg;
    Color fg;
    switch (_phase) {
      case _Phase.loading:
      case _Phase.loadingModel:
      case _Phase.generating:
        bg = scheme.secondaryContainer;
        fg = scheme.onSecondaryContainer;
        break;
      case _Phase.ready:
      case _Phase.chatting:
        bg = scheme.primaryContainer;
        fg = scheme.onPrimaryContainer;
        break;
      case _Phase.error:
        bg = scheme.errorContainer;
        fg = scheme.onErrorContainer;
        break;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(_status, style: TextStyle(color: fg)),
          if (_error != null) ...[
            const SizedBox(height: 6),
            SelectableText(_error!, style: TextStyle(color: fg, fontSize: 12)),
          ],
        ],
      ),
    );
  }

  Widget _buildModelSection() {
    final busy = _phase == _Phase.loadingModel;
    return _card(
      title: 'Model',
      children: [
        TextField(
          controller: _modelUrlCtrl,
          decoration: const InputDecoration(
            labelText: 'Model URL (GGUF)',
            hintText: 'e.g. https://…/qwen-0.6b-q4_k_m.gguf',
            border: OutlineInputBorder(),
          ),
          enabled: !busy,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            SizedBox(
              width: 160,
              child: TextField(
                controller: _contextSizeCtrl,
                decoration: const InputDecoration(
                  labelText: 'Context size',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                keyboardType: TextInputType.number,
                enabled: !busy,
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed:
                  _phase == _Phase.ready || _phase == _Phase.chatting || _phase == _Phase.error
                      ? _loadModel
                      : null,
              child: Text(busy ? 'Loading…' : 'Load model'),
            ),
          ],
        ),
        if (_downloadedBytes != null) ...[
          const SizedBox(height: 12),
          LinearProgressIndicator(value: _downloadProgress),
          const SizedBox(height: 4),
          Text(
            _totalBytes != null
                ? '${_fmtBytes(_downloadedBytes!)} / ${_fmtBytes(_totalBytes!)}'
                : '${_fmtBytes(_downloadedBytes!)} downloaded',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildSystemPromptSection() {
    return _card(
      title: 'System prompt',
      children: [
        TextField(
          controller: _systemPromptCtrl,
          minLines: 2,
          maxLines: 4,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          enabled: _phase != _Phase.loadingModel && _phase != _Phase.generating,
        ),
        const SizedBox(height: 4),
        const Text(
          'Applied when the next "Load model" click rebuilds the chat.',
          style: TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildChatSection() {
    final canChat = _phase == _Phase.chatting;
    return _card(
      title: 'Chat',
      children: [
        Container(
          height: 320,
          decoration: BoxDecoration(
            color: Colors.grey.shade50,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.all(8),
          child: _history.isEmpty
              ? Center(
                  child: Text(
                    canChat
                        ? 'Send a message to start.'
                        : 'Load a model to begin.',
                    style: const TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  controller: _chatScrollCtrl,
                  itemCount: _history.length,
                  itemBuilder: (ctx, i) => _buildMessageBubble(_history[i]),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            // Wrap the TextField in a Focus+KeyboardListener so Enter
            // submits even on Flutter web (where `onSubmitted` is sometimes
            // not triggered depending on IME / focus state). Shift+Enter
            // still inserts a newline for the multiline case.
            Expanded(
              child: Focus(
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter &&
                      !HardwareKeyboard.instance.isShiftPressed &&
                      canChat) {
                    _sendMessage();
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: _userInputCtrl,
                  decoration: const InputDecoration(
                    hintText: 'Type a message…',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  enabled: canChat,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: canChat ? _sendMessage : null,
              child: Text(_phase == _Phase.generating ? 'Running…' : 'Send'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMessageBubble(_ChatMessage m) {
    final isUser = m.role == 'user';
    // If this is the *last* bubble and it's empty while we're generating,
    // fill it with a spinner + status text instead of a literal '…'. That
    // way the user has something to look at during the inline wasm
    // worker's blocking run, even if setState updates after this frame
    // won't land until the worker returns.
    final isActiveAssistant = !isUser &&
        m.text.isEmpty &&
        _phase == _Phase.generating &&
        identical(m, _history.isNotEmpty ? _history.last : null);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          top: 4,
          bottom: 4,
          left: isUser ? 40 : 0,
          right: isUser ? 0 : 40,
        ),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isUser ? Colors.blue.shade50 : Colors.white,
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment:
              isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              m.role.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 2),
            if (isActiveAssistant)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: const [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('thinking…'),
                ],
              )
            else
              SelectableText(m.text.isEmpty ? '…' : m.text),
          ],
        ),
      ),
    );
  }

  Widget _buildLogSection() {
    return _card(
      title: 'Debug log',
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(4),
          ),
          padding: const EdgeInsets.all(8),
          height: 200,
          child: ListView.builder(
            reverse: false,
            itemCount: _log.length,
            itemBuilder: (ctx, i) {
              final e = _log[i];
              return Text(
                '${e.timestamp}  ${e.message}',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: e.level == _LogLevel.error
                      ? Colors.red.shade200
                      : Colors.grey.shade200,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _card({required String title, required List<Widget> children}) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade300),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const Divider(height: 16),
            ...children,
          ],
        ),
      ),
    );
  }
}

enum _LogLevel { info, error }

class _LogEntry {
  _LogEntry(this.timestamp, this.message, this.level);
  final String timestamp;
  final String message;
  final _LogLevel level;
}
