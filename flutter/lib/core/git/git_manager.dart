import '../shell/shell_executor.dart';

/// State of one file in `git status --porcelain`.
enum GitFileState {
  unmodified,
  added,
  modified,
  deleted,
  renamed,
  copied,
  untracked,
  conflicted,
}

/// One entry of a porcelain status report.
class GitStatusEntry {
  const GitStatusEntry({
    required this.path,
    required this.indexState,
    required this.worktreeState,
  });

  final String path;
  final GitFileState indexState;
  final GitFileState worktreeState;

  bool get isDirty =>
      indexState != GitFileState.unmodified ||
      worktreeState != GitFileState.unmodified;
}

/// Result of `git status --porcelain -b`.
class GitStatus {
  const GitStatus({required this.branch, required this.entries});

  final String branch;
  final List<GitStatusEntry> entries;

  bool get isClean => entries.every((entry) => !entry.isDirty);

  List<String> get changedPaths => [
        for (final entry in entries)
          if (entry.isDirty) entry.path,
      ];
}

/// Typed wrapper around the git CLI through a [ProcessRunner]. Works
/// wherever a git binary exists (Windows dev, CI); on Android the sandbox
/// rollback path (see GitSandbox) covers the same safety need without one.
class GitManager {
  GitManager({required this.runner, this.timeout = const Duration(seconds: 60)});

  final ProcessRunner runner;
  final Duration timeout;

  static const _notARepoMarker = 'not a git repository';

  Future<bool> isRepo() async {
    final result = await _run('rev-parse --is-inside-work-tree');
    return result.succeeded && result.stdout.trim() == 'true';
  }

  Future<String?> currentBranch() async {
    final result = await _run('rev-parse --abbrev-ref HEAD');
    return result.succeeded ? result.stdout.trim() : null;
  }

  Future<GitStatus> status() async {
    final result = await _run('status --porcelain=v1 -b');
    if (!result.succeeded) {
      if (result.stderr.contains(_notARepoMarker)) {
        return const GitStatus(branch: '', entries: []);
      }
      throw Exception('git status failed: ${result.stderr.trim()}');
    }
    return _parseStatus(result.stdout);
  }

  Future<String> diff({bool staged = false}) async {
    final result = await _run(staged ? 'diff --cached' : 'diff');
    if (!result.succeeded) {
      throw Exception('git diff failed: ${result.stderr.trim()}');
    }
    return result.stdout;
  }

  Future<List<String>> branches() async {
    final result = await _run('branch --list');
    if (!result.succeeded) {
      throw Exception('git branch failed: ${result.stderr.trim()}');
    }
    return [
      for (final line in result.stdout.split('\n'))
        if (line.trim().isNotEmpty)
          line.trim().replaceFirst(RegExp(r'^\*\s*'), ''),
    ];
  }

  Future<void> commit(String message) async {
    final add = await _run('add -A');
    if (!add.succeeded) {
      throw Exception('git add failed: ${add.stderr.trim()}');
    }
    final commitResult = await _run('commit -m ${_quote(message)}');
    if (!commitResult.succeeded) {
      throw Exception('git commit failed: ${commitResult.stderr.trim()}');
    }
  }

  Future<void> stash([String? message]) async {
    final arguments = message == null
        ? 'stash push'
        : 'stash push -m ${_quote(message)}';
    final result = await _run(arguments);
    if (!result.succeeded) {
      throw Exception('git stash failed: ${result.stderr.trim()}');
    }
  }

  Future<void> checkout(String ref) async {
    final result = await _run('checkout ${_quote(ref)}');
    if (!result.succeeded) {
      throw Exception('git checkout failed: ${result.stderr.trim()}');
    }
  }

  /// Destructive: discards all uncommitted changes. Callers gate this
  /// behind user approval upstream.
  Future<void> resetHard([String? ref]) async {
    final result = await _run(
        ref == null ? 'reset --hard' : 'reset --hard ${_quote(ref)}');
    if (!result.succeeded) {
      throw Exception('git reset failed: ${result.stderr.trim()}');
    }
  }

  Future<ShellResult> _run(String arguments) async {
    final command = arguments.trim().isEmpty
        ? 'git'
        : 'git $arguments';
    return runner.run(ShellRequest(command: command, timeout: timeout));
  }

  GitStatus _parseStatus(String output) {
    var branch = '';
    final entries = <GitStatusEntry>[];
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trimRight();
      if (line.startsWith('## ')) {
        branch = line.substring(3).split(RegExp(r'\.\.\.|\s\[')).first.trim();
        continue;
      }
      if (line.length < 4) continue;
      final indexChar = line[0];
      final worktreeChar = line[1];
      final path = line.substring(3).trim();
      entries.add(GitStatusEntry(
        path: path,
        indexState: _stateFor(indexChar, untrackedMeans: GitFileState.added),
        worktreeState:
            _stateFor(worktreeChar, untrackedMeans: GitFileState.untracked),
      ));
    }
    return GitStatus(branch: branch, entries: entries);
  }

  GitFileState _stateFor(String char,
      {required GitFileState untrackedMeans}) {
    switch (char) {
      case '?':
        return untrackedMeans;
      case 'A':
        return GitFileState.added;
      case 'D':
        return GitFileState.deleted;
      case 'R':
        return GitFileState.renamed;
      case 'C':
        return GitFileState.copied;
      case 'U':
        return GitFileState.conflicted;
      case 'M':
        return GitFileState.modified;
      default:
        return GitFileState.unmodified;
    }
  }

  String _quote(String value) {
    final escaped = value.replaceAll("'", r"'\''");
    return "'$escaped'";
  }
}
