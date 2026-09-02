import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/git/git_manager.dart';
import 'package:shelly_hermes/core/git/git_sandbox.dart';
import 'package:shelly_hermes/core/shell/shell_executor.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

/// Runs `git <scripted-by-command>` — commands are matched verbatim.
class _FakeGitRunner implements ProcessRunner {
  _FakeGitRunner(this.replies);

  final Map<String, ShellResult> replies;
  final List<String> commands = [];

  @override
  bool get isSupported => true;

  @override
  Future<ShellResult> run(ShellRequest request,
      {CancellationSignal? cancellation}) async {
    commands.add(request.command);
    return replies[request.command] ??
        const ShellResult(exitCode: 1, duration: Duration.zero, stderr: 'unexpected');
  }
}

void main() {
  group('GitManager', () {
    test('isRepo parses rev-parse output', () async {
      final runner = _FakeGitRunner({
        'git rev-parse --is-inside-work-tree': const ShellResult(
          exitCode: 0,
          duration: Duration.zero,
          stdout: 'true\n',
        ),
      });
      expect(await GitManager(runner: runner).isRepo(), isTrue);
      expect(runner.commands, ['git rev-parse --is-inside-work-tree']);
    });

    test('status parses porcelain v1 output', () async {
      final runner = _FakeGitRunner({
        'git status --porcelain=v1 -b': ShellResult(
          exitCode: 0,
          duration: Duration.zero,
          stdout: '## main...origin/main [ahead 1]\n'
              ' M lib/a.dart\n'
              'M  lib/b.dart\n'
              '?? notes.txt\n'
              'D  gone.txt\n',
        ),
      });
      final status = await GitManager(runner: runner).status();
      expect(status.branch, 'main');
      expect(status.entries.length, 4);
      expect(status.entries[0].worktreeState, GitFileState.modified);
      expect(status.entries[1].indexState, GitFileState.modified);
      expect(status.entries[2].worktreeState, GitFileState.untracked);
      expect(status.entries[3].indexState, GitFileState.deleted);
      expect(status.isClean, isFalse);
      expect(status.changedPaths,
          unorderedEquals(['lib/a.dart', 'lib/b.dart', 'notes.txt', 'gone.txt']));
    });

    test('status on a non-repo reports empty, not an exception', () async {
      final runner = _FakeGitRunner({
        'git status --porcelain=v1 -b': const ShellResult(
          exitCode: 128,
          duration: Duration.zero,
          stderr: 'fatal: not a git repository (or any of the parent directories)',
        ),
      });
      final status = await GitManager(runner: runner).status();
      expect(status.branch, isEmpty);
      expect(status.entries, isEmpty);
      expect(status.isClean, isTrue);
    });

    test('commit runs add -A then commit with quoted message', () async {
      final runner = _FakeGitRunner({
        'git add -A': const ShellResult(exitCode: 0, duration: Duration.zero),
        "git commit -m 'fix: login crash on resume'": const ShellResult(
          exitCode: 0,
          duration: Duration.zero,
          stdout: '[main 1a2b3c] fix: login crash on resume',
        ),
      });
      await GitManager(runner: runner).commit('fix: login crash on resume');
      expect(runner.commands,
          ['git add -A', "git commit -m 'fix: login crash on resume'"]);
    });

    test('failed commit surfaces stderr', () async {
      final runner = _FakeGitRunner({
        'git add -A': const ShellResult(exitCode: 0, duration: Duration.zero),
        "git commit -m 'x'": const ShellResult(
          exitCode: 1,
          duration: Duration.zero,
          stderr: 'nothing to commit',
        ),
      });
      await expectLater(
        GitManager(runner: runner).commit('x'),
        throwsA(isA<Exception>()),
      );
    });

    test('resetHard/checkout/stash/branches/diff passthrough', () async {
      final runner = _FakeGitRunner({
        'git reset --hard': const ShellResult(exitCode: 0, duration: Duration.zero),
        "git checkout 'feature/x'": const ShellResult(exitCode: 0, duration: Duration.zero),
        "git stash push -m 'before agent'": const ShellResult(exitCode: 0, duration: Duration.zero),
        'git branch --list': const ShellResult(
          exitCode: 0,
          duration: Duration.zero,
          stdout: '* main\n  feature/x\n',
        ),
        'git diff': const ShellResult(exitCode: 0, duration: Duration.zero, stdout: 'diff --git a'),
      });
      final git = GitManager(runner: runner);
      await git.resetHard();
      await git.checkout('feature/x');
      await git.stash('before agent');
      expect(await git.branches(), ['main', 'feature/x']);
      expect(await git.diff(), 'diff --git a');
      expect(await git.currentBranch(), isNull);
    });
  });

  group('GitSandbox', () {
    test('open captures content, restore rolls everything back', () async {
      final ws = MemoryWorkspace({
        'keep.txt': 'original',
        'edit.txt': 'before',
        'dir/deep.txt': 'deep',
      });
      final sandbox = GitSandbox(ws);
      final session = await sandbox.open();
      expect(session.fileCount, 3);
      expect(session.id, startsWith('sandbox-'));

      // Agent mutates: overwrite, add, and (via delete) remove.
      await ws.writeFile('edit.txt', 'after');
      await ws.writeFile('new.txt', 'created by agent');
      await ws.deleteFile('dir/deep.txt');

      final report = await sandbox.restore(session);
      expect(report.restored, unorderedEquals(['edit.txt', 'dir/deep.txt']));
      expect(report.removed, ['new.txt']);
      expect(report.failed, isEmpty);
      expect(ws.files['edit.txt'], 'before');
      expect(ws.files['dir/deep.txt'], 'deep');
      expect(ws.files.containsKey('new.txt'), isFalse);
      expect(ws.files['keep.txt'], 'original');
    });

    test('restore on an unchanged workspace is a no-op', () async {
      final ws = MemoryWorkspace({'a.txt': 'same'});
      final sandbox = GitSandbox(ws);
      final session = await sandbox.open();
      final report = await sandbox.restore(session);
      expect(report.isEmpty, isTrue);
      expect(ws.files['a.txt'], 'same');
    });

    test('custom id factory is honored', () async {
      final sandbox = GitSandbox(
        MemoryWorkspace(),
        idFactory: () => 'pre-agent-checkpoint',
      );
      expect((await sandbox.open()).id, 'pre-agent-checkpoint');
    });
  });
}
