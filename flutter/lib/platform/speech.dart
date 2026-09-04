import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Speech-to-text boundary the composer talks to. The platform plugin is
/// only touched behind this interface so widget tests can inject fakes —
/// real recognition needs the speech channel and microphone permission.
abstract interface class SpeechTranscriber {
  /// Resolves whether recognition is usable on this device (plugin ready
  /// and permission granted).
  Future<bool> initialize();

  /// Starts streaming recognition; [onResult] receives running text, with
  /// [isFinal] true once the utterance settles.
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  });

  /// Ends the current utterance.
  Future<void> stop();
}

class PlatformSpeechTranscriber implements SpeechTranscriber {
  final stt.SpeechToText _speech = stt.SpeechToText();

  @override
  Future<bool> initialize() => _speech.initialize();

  @override
  Future<void> listen({
    required String localeId,
    required void Function(String text, bool isFinal) onResult,
  }) {
    return _speech.listen(
      onResult: (result) =>
          onResult(result.recognizedWords, result.finalResult),
      listenOptions: stt.SpeechListenOptions(
        localeId: localeId,
        listenFor: const Duration(seconds: 30),
        pauseFor: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();
}
