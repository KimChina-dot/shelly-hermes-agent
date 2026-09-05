import 'package:flutter_tts/flutter_tts.dart';

/// Text-to-speech boundary the chat page talks to. The platform plugin is
/// only touched behind this interface so tests and callers can inject
/// fakes — real synthesis needs the platform TTS channel.
///
/// The service is settings-agnostic: whether reading replies aloud is
/// wanted at all is decided by the caller (the TTS toggle in the settings
/// store), never read here.
abstract interface class TtsService {
  /// Speaks [text] aloud. The returned future completes when the
  /// utterance finishes (or is stopped); an empty/blank text is a no-op.
  Future<void> speak(String text);

  /// Stops any ongoing utterance. Safe to call when nothing is speaking.
  Future<void> stop();
}

/// [TtsService] backed by the `flutter_tts` plugin. Configured once for
/// Chinese (zh-CN) with an English (en-US) fallback for devices that lack
/// a Chinese voice; speech completion is awaited so the UI can flip the
/// speaker icon back when the readout ends.
class FlutterTtsService implements TtsService {
  FlutterTtsService({FlutterTts? engine}) : _engine = engine ?? FlutterTts();

  final FlutterTts _engine;
  bool _configured = false;

  Future<void> _configure() async {
    if (_configured) return;
    await _engine.awaitSpeakCompletion(true);
    final chinese = await _engine.setLanguage('zh-CN');
    if (chinese != 1) {
      // No zh-CN voice on this device — fall back to English.
      await _engine.setLanguage('en-US');
    }
    _configured = true;
  }

  @override
  Future<void> speak(String text) async {
    if (text.trim().isEmpty) return;
    await _configure();
    await _engine.speak(text);
  }

  @override
  Future<void> stop() => _engine.stop();
}

/// Turns an assistant reply into what the voice should actually read:
/// markdown-ish decorations (headings, emphasis, links, list bullets,
/// fenced code blocks) are stripped lightly and runs of whitespace are
/// collapsed into single spaces.
String ttsPlainText(String markdown) {
  var text = markdown;
  // Fenced code blocks are dropped entirely — reading source aloud is noise.
  text = text.replaceAll(RegExp('```[\\s\\S]*?```'), ' ');
  text = text.replaceAll(RegExp(r'~~~[\s\S]*?~~~'), ' ');
  // Images vanish; links keep their label text.
  text = text.replaceAll(RegExp(r'!\[([^\]]*)\]\([^)]*\)'), ' ');
  text = text.replaceAllMapped(
    RegExp(r'\[([^\]]*)\]\([^)]*\)'),
    (match) => match.group(1) ?? '',
  );
  // Heading hashes, blockquote markers and horizontal rules.
  text = text.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s+', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
  text = text.replaceAll(
    RegExp(r'^\s{0,3}([-*_])[ \t]*\1[ \t]*\1[ \t]*$', multiLine: true),
    ' ',
  );
  // List bullets and ordered markers keep their content, lose the marker.
  text = text.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '');
  text = text.replaceAll(RegExp(r'^\s{0,3}\d+[.)]\s+', multiLine: true), '');
  // Inline code backticks and emphasis markers.
  text = text.replaceAll('`', '');
  text = text.replaceAll('**', '');
  text = text.replaceAll('__', '');
  text = text.replaceAll('*', '');
  // Whitespace runs (including the newlines the block rules left behind)
  // collapse into single spaces so the engine reads one flowing sentence.
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text;
}
