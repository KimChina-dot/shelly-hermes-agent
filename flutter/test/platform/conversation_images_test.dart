import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/gateway/openai_messages.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/platform/conversation_images.dart';

const _pngDataUrl =
    'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('shelly-img-test');
    addTearDown(() => tempDir.delete(recursive: true));
  });

  test('save writes the bytes and returns a resolvable file path', () async {
    final store = ConversationImageStore(tempDir);

    final path = await store.save(_pngDataUrl);

    final file = File(path);
    expect(file.existsSync(), isTrue);
    final decoded = base64Decode(_pngDataUrl.split(',').last);
    expect(file.lengthSync(), decoded.length);
    // The stored reference is a short path, not the inline payload.
    expect(path.length, lessThan(120));
    expect(path.startsWith(tempDir.path), isTrue);
  });

  test('imageWireUrl passes data URLs through and expands file paths', () async {
    final store = ConversationImageStore(tempDir);
    final path = await store.save(_pngDataUrl);

    expect(imageWireUrl(_pngDataUrl), _pngDataUrl);
    expect(imageWireUrl(path), _pngDataUrl);
  });

  test('imageWireUrl returns null for unreadable files', () {
    expect(
      imageWireUrl(
          '${tempDir.path}${Platform.pathSeparator}missing.png'),
      isNull,
    );
  });

  test('encodeMessages expands file-path images and drops unreadable ones',
      () async {
    final store = ConversationImageStore(tempDir);
    final livePath = await store.save(_pngDataUrl);
    final deadPath =
        '${tempDir.path}${Platform.pathSeparator}deleted.jpg';

    final encoded = encodeMessages([
      AgentMessage(
        role: MessageRole.user,
        content: '两张图,一张已失效',
        images: [livePath, deadPath],
      ),
    ]);

    final content = encoded[0]['content'] as List<dynamic>;
    expect(content, hasLength(2)); // text + only the live image
    expect(
      (content[1]['image_url'] as Map)['url'],
      _pngDataUrl,
    );
  });
}
