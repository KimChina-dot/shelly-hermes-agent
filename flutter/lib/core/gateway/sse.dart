import 'dart:async';

/// Minimal SSE (Server-Sent Events) line parser for chat/completions
/// streams. Handles `data:` payload lines, multi-line data joins, comment
/// lines starting with `:` and the `data: [DONE]` sentinel.
class SseParser {
  final _controller = StreamController<String>();
  final _buffer = <String>[];

  /// Completed [String] data payloads, in arrival order.
  Stream<String> get data => _controller.stream;

  void addLine(String line) {
    if (line.isEmpty) {
      _flush();
      return;
    }
    if (line.startsWith(':')) return; // comment / keep-alive
    if (line.startsWith('data:')) {
      _buffer.add(line.substring(5).trimLeft());
      return;
    }
    // Other fields (event:, id:, retry:) are irrelevant for chat streams.
  }

  /// Feeds a raw chunk that may contain any number of partial lines.
  /// Returns the unconsumed trailing partial line.
  String addChunk(String chunk) {
    final pending = _partial + chunk;
    final lines = pending.split('\n');
    _partial = lines.removeLast();
    for (final line in lines) {
      addLine(line.endsWith('\r') ? line.substring(0, line.length - 1) : line);
    }
    return _partial;
  }

  String _partial = '';

  void _flush() {
    if (_buffer.isEmpty) return;
    final payload = _buffer.join('\n');
    _buffer.clear();
    _controller.add(payload);
  }

  Future<void> close() async {
    _flush();
    await _controller.close();
  }
}
