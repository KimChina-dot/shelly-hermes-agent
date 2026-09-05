import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/tts/tts_service.dart';

/// Scriptable [TtsService] fake: records what was asked of it and models
/// the "speaking" state so callers' start/stop transitions can be asserted
/// without a platform TTS channel.
class FakeTtsService implements TtsService {
  FakeTtsService();

  final List<String> spoken = [];
  int speakCalls = 0;
  int stopCalls = 0;

  /// True between a [speak] start and the utterance completing.
  bool speaking = false;

  /// When set, the pending utterance only completes once [stop] is called
  /// (the page's early-stop path).
  Completer<void>? holdUtterance;

  Object? speakError;

  @override
  Future<void> speak(String text) async {
    speakCalls += 1;
    if (text.trim().isEmpty) return;
    if (speakError != null) throw speakError!;
    spoken.add(text);
    speaking = true;
    final gate = holdUtterance;
    if (gate != null) {
      await gate.future;
      holdUtterance = null;
      return;
    }
    speaking = false;
  }

  @override
  Future<void> stop() async {
    stopCalls += 1;
    speaking = false;
    holdUtterance?.complete();
    holdUtterance = null;
  }
}

void main() {
  group('FakeTtsService speak/stop transitions', () {
    test('speak records the text and clears the speaking state on completion',
        () async {
      final tts = FakeTtsService();
      expect(tts.speaking, isFalse);

      await tts.speak('你好,世界');
      expect(tts.speakCalls, 1);
      expect(tts.spoken, ['你好,世界']);
      // The future completed, so the readout is no longer "playing".
      expect(tts.speaking, isFalse);
    });

    test('speak marks speaking while the utterance is held open', () async {
      final tts = FakeTtsService()..holdUtterance = Completer<void>();
      final done = tts.speak('长句子还在读');
      // Give the microtask queue a tick to enter the held await.
      await Future<void>.delayed(Duration.zero);
      expect(tts.speaking, isTrue);
      expect(tts.spoken, ['长句子还在读']);

      await tts.stop();
      await done;
      expect(tts.speaking, isFalse);
      expect(tts.stopCalls, 1);
    });

    test('sequential messages speak in order', () async {
      final tts = FakeTtsService();
      await tts.speak('第一条');
      await tts.speak('第二条');
      expect(tts.spoken, ['第一条', '第二条']);
      expect(tts.speakCalls, 2);
    });

    test('speak of blank text is a no-op for the spoken log', () async {
      final tts = FakeTtsService();
      await tts.speak('   ');
      expect(tts.spoken, isEmpty);
    });

    test('stop without an ongoing utterance is safe', () async {
      final tts = FakeTtsService();
      await tts.stop();
      expect(tts.stopCalls, 1);
      expect(tts.speaking, isFalse);
    });

    test('restarting after stop speaks again', () async {
      final tts = FakeTtsService()..holdUtterance = Completer<void>();
      final first = tts.speak('第一次');
      await Future<void>.delayed(Duration.zero);
      await tts.stop();
      await first;

      tts.holdUtterance = null;
      await tts.speak('第二次');
      expect(tts.spoken, ['第一次', '第二次']);
      expect(tts.speaking, isFalse);
    });
  });

  group('ttsPlainText', () {
    test('plain text passes through untouched', () {
      expect(ttsPlainText('普通的一句话。'), '普通的一句话。');
    });

    test('headings lose their hash markers', () {
      expect(ttsPlainText('## 安装步骤\n正文'), '安装步骤 正文');
    });

    test('emphasis markers are stripped but content kept', () {
      expect(ttsPlainText('这是**重点**和*次重点*内容'), '这是重点和次重点内容');
    });

    test('inline code keeps its content, loses backticks', () {
      expect(ttsPlainText('运行 `flutter run` 即可'), '运行 flutter run 即可');
    });

    test('links keep the label, images are dropped', () {
      expect(
        ttsPlainText('见 [官方文档](https://example.com) 与 ![截图](a.png)'),
        '见 官方文档 与',
      );
    });

    test('fenced code blocks are dropped entirely', () {
      const markdown = '步骤如下:\n```dart\nvoid main() {}\n```\n完成。';
      expect(ttsPlainText(markdown), '步骤如下: 完成。');
    });

    test('list bullets and ordered markers are removed', () {
      expect(
        ttsPlainText('- 第一项\n* 第二项\n1. 第三项'),
        '第一项 第二项 第三项',
      );
    });

    test('blockquote markers and horizontal rules disappear', () {
      expect(ttsPlainText('> 引用的话\n\n---\n\n之后'), '引用的话 之后');
    });

    test('whitespace runs collapse into single spaces', () {
      expect(ttsPlainText('A\n\nB\t\tC   D'), 'A B C D');
    });

    test('blank input yields an empty string', () {
      expect(ttsPlainText(''), '');
      expect(ttsPlainText('  \n  '), '');
    });
  });
}
