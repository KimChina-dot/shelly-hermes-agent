import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/app.dart';
import 'package:shelly_hermes/platform/platform_workspace.dart';
import 'package:shelly_hermes/state/chat_session.dart';

/// Platform double: records which surface received operations and can be
/// toggled between "no grant" and "granted" states.
class _FakePlatform extends PlatformWorkspace {
  _FakePlatform() : super(const MethodChannel('test.workspace'));

  bool granted = false;
  bool broken = false;
  final List<String> ops = [];

  @override
  Future<bool> hasDirectory() async => granted;

  @override
  Future<String?> pickDirectory() async {
    granted = true;
    return 'content://tree/demo';
  }

  @override
  Future<String?> readFile(String path) async {
    ops.add('platform:read:$path');
    if (broken) {
      throw PlatformException(code: 'workspace', message: 'no workspace directory picked');
    }
    return 'platform-content';
  }

  @override
  Future<void> writeFile(String path, String content) async {
    ops.add('platform:write:$path');
    if (broken) {
      throw PlatformException(code: 'workspace', message: 'no workspace directory picked');
    }
  }

  @override
  Future<List<String>> listFiles([String prefix = '']) async {
    ops.add('platform:list');
    if (broken) {
      throw PlatformException(code: 'workspace', message: 'no workspace directory picked');
    }
    return const ['platform-file'];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ResilientWorkspace', () {
    test('routes operations to the sandbox while no directory is picked',
        () async {
      final platform = _FakePlatform();
      final ws = ResilientWorkspace(platform: platform);

      await ws.refreshAuthorization();
      expect(ws.authorized.value, isFalse);

      await ws.writeFile('demo/notes.md', '第一行');
      expect(await ws.readFile('demo/notes.md'), '第一行');
      expect(platform.ops, isEmpty);
    });

    test('routes operations to SAF once a directory is granted', () async {
      final platform = _FakePlatform()..granted = true;
      final ws = ResilientWorkspace(platform: platform);

      await ws.refreshAuthorization();
      expect(ws.authorized.value, isTrue);

      await ws.writeFile('demo/notes.md', '第一行');
      expect(platform.ops, contains('platform:write:demo/notes.md'));
    });

    test('pickDirectory flips authorization and subsequent routing',
        () async {
      final platform = _FakePlatform();
      final ws = ResilientWorkspace(platform: platform);

      expect(await ws.pickDirectory(), 'content://tree/demo');
      expect(ws.authorized.value, isTrue);

      await ws.writeFile('x.txt', 'v');
      expect(platform.ops, contains('platform:write:x.txt'));
    });

    test('falls back to the sandbox when the platform bridge throws',
        () async {
      final platform = _FakePlatform()
        ..granted = true
        ..broken = true;
      final ws = ResilientWorkspace(platform: platform);
      await ws.refreshAuthorization();

      await ws.writeFile('demo/notes.md', 'sandbox copy');
      expect(await ws.readFile('demo/notes.md'), 'sandbox copy');
      expect(await ws.listFiles(), contains('demo/notes.md'));
      expect(platform.ops, isNotEmpty, reason: 'platform was tried first');
    });
  });

  testWidgets('chat tab shows the sandbox banner while workspace is unauthorized',
      (tester) async {
    final container = ProviderContainer(overrides: [
      workspaceProvider.overrideWithValue(
          ResilientWorkspace(platform: _FakePlatform())),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('演示沙箱:文件改动不会落盘,选择目录后即可真实读写'), findsOneWidget);
    expect(find.text('选择目录'), findsOneWidget);
  });

  testWidgets('chat tab hides the sandbox banner once the directory is granted',
      (tester) async {
    final container = ProviderContainer(overrides: [
      workspaceProvider
          .overrideWithValue(ResilientWorkspace(platform: _FakePlatform()..granted = true)),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const ShellyApp()),
    );
    await tester.pumpAndSettle();

    expect(find.text('演示沙箱:文件改动不会落盘,选择目录后即可真实读写'), findsNothing);
  });
}
