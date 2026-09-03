import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';
import 'package:shelly_hermes/core/workspace/project.dart';
import 'package:shelly_hermes/core/workspace/workspace_manager.dart';

void main() {
  const detector = ProjectDetector();

  group('ProjectDetector', () {
    test('flutter wins over git, name parsed from pubspec', () async {
      final ws = MemoryWorkspace({
        'pubspec.yaml': 'name: my_app\ndependencies:\n  http: ^1.0.0\n',
        'lib/main.dart': 'void main() {}',
        '.gitignore': 'build/',
      });
      final info = await detector.detect(ws);
      expect(info.kind, ProjectKind.flutter);
      expect(info.name, 'my_app');
      expect(info.isGitRepo, isTrue);
      expect(info.markers, contains('.gitignore'));
    });

    test('android detected when no pubspec, name from applicationId',
        () async {
      final ws = MemoryWorkspace({
        'app/build.gradle.kts': 'android {\n'
            '  namespace "dev.shelly.demo"\n'
            '  defaultConfig { applicationId "dev.shelly.demo.app" }\n'
            '}\n',
      });
      final info = await detector.detect(ws);
      expect(info.kind, ProjectKind.android);
      expect(info.name, 'dev.shelly.demo.app');
      expect(info.isGitRepo, isFalse);
    });

    test('git-only workspace without dotdir access falls back to .gitignore',
        () async {
      final ws = MemoryWorkspace({'.gitignore': 'node_modules/'});
      final info = await detector.detect(ws);
      expect(info.kind, ProjectKind.git);
      expect(info.isGitRepo, isTrue);
    });

    test('plain workspace', () async {
      final info = await detector.detect(MemoryWorkspace({'notes.txt': 'x'}));
      expect(info.kind, ProjectKind.plain);
      expect(info.isGitRepo, isFalse);
    });

    test('pubspec without name falls back to generic name', () async {
      final ws = MemoryWorkspace({'pubspec.yaml': 'dependencies:\n'});
      final info = await detector.detect(ws);
      expect(info.kind, ProjectKind.flutter);
      expect(info.name, 'project');
    });

    test('json round-trip', () async {
      final info = await detector.detect(MemoryWorkspace({
        'pubspec.yaml': 'name: roundtrip\n',
        '.git/HEAD': 'ref: refs/heads/main\n',
      }));
      final restored = ProjectInfo.fromJson(info.toJson());
      expect(restored.kind, info.kind);
      expect(restored.name, info.name);
      expect(restored.isGitRepo, info.isGitRepo);
      expect(restored.markers, info.markers);
    });
  });

  group('WorkspaceManager', () {
    test('detectProject caches until invalidated', () async {
      final ws = MemoryWorkspace({'pubspec.yaml': 'name: cached\n'});
      final manager = WorkspaceManager(workspace: ws);
      expect((await manager.detectProject()).name, 'cached');
      await ws.writeFile('pubspec.yaml', 'name: renamed\n');
      expect((await manager.detectProject()).name, 'cached');
      expect((await manager.detectProject(force: true)).name, 'renamed');
      manager.invalidateProject();
      await ws.writeFile('pubspec.yaml', 'name: again\n');
      expect((await manager.detectProject()).name, 'again');
    });

    test('bindRoot/restoreRoot through the state store port', () async {
      final manager = WorkspaceManager(
        workspace: MemoryWorkspace(),
        stateStore: MemoryStateStore(),
      );
      expect(await manager.restoreRoot(), isNull);
      await manager.bindRoot('content://tree/root');
      expect(await manager.restoreRoot(), 'content://tree/root');
    });

    test('snapshot diffs added/removed/modified', () async {
      final ws = MemoryWorkspace({
        'keep.txt': 'same',
        'change.txt': 'old',
        'gone.txt': 'bye',
      });
      final manager = WorkspaceManager(workspace: ws);
      final before = await manager.snapshot();

      await ws.writeFile('change.txt', 'new');
      await ws.writeFile('added.txt', 'hi');
      ws.files.remove('gone.txt');
      final after = await manager.snapshot();

      final diff = before.diffTo(after);
      expect(diff.added, ['added.txt']);
      expect(diff.removed, ['gone.txt']);
      expect(diff.modified, ['change.txt']);
      expect(diff.isEmpty, isFalse);
      expect(diff.changeCount, 3);
      expect(before.diffTo(before).isEmpty, isTrue);
    });

    test('snapshot hash is stable across runs and whitespace-sensitive',
        () async {
      final ws1 = MemoryWorkspace({'a.txt': 'hello'});
      final ws2 = MemoryWorkspace({'a.txt': 'hello'});
      final ws3 = MemoryWorkspace({'a.txt': 'hello '});
      final s1 = await WorkspaceManager(workspace: ws1).snapshot();
      final s2 = await WorkspaceManager(workspace: ws2).snapshot();
      final s3 = await WorkspaceManager(workspace: ws3).snapshot();
      expect(s1.hashes['a.txt'], s2.hashes['a.txt']);
      expect(s1.hashes['a.txt'], isNot(s3.hashes['a.txt']));
    });
  });
}
