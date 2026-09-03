/// Per-hunk UI review model (ported from Kotlin `DiffApproval.kt`): the
/// approval screen tracks one decision per hunk and renders the approved
/// subset as a unified diff.
class DiffHunk {
  const DiffHunk({
    required this.id,
    required this.filePath,
    required this.header,
    required this.lines,
  });

  final String id;
  final String filePath;
  final String header;
  final List<String> lines;

  /// Renders the hunk as a unified-diff style block for display.
  String render() {
    final buffer = StringBuffer()
      ..write('--- ')
      ..write(filePath)
      ..write('\n+++ ')
      ..write(filePath)
      ..write('\n')
      ..write(header)
      ..write('\n');
    for (final line in lines) {
      buffer
        ..write(line)
        ..write('\n');
    }
    return buffer.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is DiffHunk &&
      other.id == id &&
      other.filePath == filePath &&
      other.header == header &&
      _listEquals(other.lines, lines);

  @override
  int get hashCode => Object.hash(id, filePath, header, Object.hashAll(lines));
}

enum HunkDecision { pending, approved, rejected }

class DiffApprovalState {
  const DiffApprovalState({this.decisions = const {}});

  final Map<String, HunkDecision> decisions;

  DiffApprovalState decide(String hunkId, HunkDecision decision) {
    return DiffApprovalState(decisions: {...decisions, hunkId: decision});
  }

  HunkDecision decisionFor(DiffHunk hunk) => decisions[hunk.id] ?? HunkDecision.pending;

  List<DiffHunk> approved(List<DiffHunk> hunks) =>
      hunks.where((h) => decisionFor(h) == HunkDecision.approved).toList();

  /// True when every hunk has a non-pending decision.
  bool isComplete(List<DiffHunk> hunks) =>
      hunks.isNotEmpty && hunks.every((h) => decisionFor(h) != HunkDecision.pending);

  /// Renders the full diff keeping only lines from approved hunks.
  String renderApproved(List<DiffHunk> hunks) =>
      approved(hunks).map((h) => h.render()).join('\n');

  @override
  bool operator ==(Object other) =>
      other is DiffApprovalState &&
      other.decisions.length == decisions.length &&
      other.decisions.entries.every((e) => decisions[e.key] == e.value);

  @override
  int get hashCode => Object.hashAll(
      decisions.entries.map((e) => Object.hash(e.key, e.value)));
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
