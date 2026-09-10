import '../models.dart';
import '../runtime/tool_registry.dart';
import 'registry.dart';
import 'workspace.dart' show decodeArguments;

/// No-op plan/notes state (PHASE 46): `plan` replaces the whole current
/// plan, `note` appends a progress note. Both tools only mutate in-memory
/// state on this registry instance — the workspace is never touched — and
/// answer with a short ack the model can build on. Invalid arguments
/// return an error string (not an exception) so the model can correct
/// itself without failing the task, mirroring [TerminalSearchTools].
///
/// One instance lives per task run (like the other registries), so plan
/// state resets naturally between tasks. The state is surfaced to the
/// model through [recitationBlock]: the session splices that block into
/// the system prompt on every round (todo-recitation — the current plan
/// stays in the model's near attention window, Manus/TodoList style),
/// positioned after the 「工具使用守则」 rules and before the 「长期记忆」
/// memory block.
class NotesToolRegistry implements AgentToolRegistry {
  NotesToolRegistry();

  final List<String> _steps = <String>[];
  final List<String> _notes = <String>[];

  /// How many steps/notes the recitation block shows at most.
  static const maxRecitedSteps = 8;
  static const maxRecitedNotes = 8;

  static const notesSpecs = <ToolSpec>[
    ToolSpec('plan', '整体替换当前任务计划(仅记录状态,不执行)', 'low'),
    ToolSpec('note', '追加一条进展备注(仅记录状态)', 'low'),
  ];

  @override
  List<ToolSpec> get specs => notesSpecs;

  @override
  List<Map<String, dynamic>> openAiToolsJson() => [
    {
      'type': 'function',
      'function': {
        'name': 'plan',
        'description': notesSpecs[0].description,
        'parameters': {
          'type': 'object',
          'properties': {
            'steps': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': '完整的新计划步骤列表,按执行顺序;全量替换旧计划',
            },
          },
          'required': ['steps'],
        },
      },
    },
    {
      'type': 'function',
      'function': {
        'name': 'note',
        'description': notesSpecs[1].description,
        'parameters': {
          'type': 'object',
          'properties': {
            'text': {'type': 'string', 'description': '要记录的进展内容'},
          },
          'required': ['text'],
        },
      },
    },
  ];

  @override
  Future<String> execute(ToolCall call) async {
    switch (call.name) {
      case 'plan':
        return _plan(call);
      case 'note':
        return _note(call);
      default:
        throw ToolError('unknown tool: ${call.name}');
    }
  }

  /// Replaces the whole plan with the given steps (blank entries dropped;
  /// an empty list clears the plan).
  Future<String> _plan(ToolCall call) async {
    final args = decodeArguments(call.argumentsJson);
    final steps = args['steps'];
    if (steps is! List || steps.any((step) => step is! String)) {
      return 'error: plan requires "steps" to be an array of strings';
    }
    seedPlan(steps.cast<String>());
    return 'plan updated (${_steps.length} steps)';
  }

  /// Seeds the plan from outside the tool surface (PHASE 8): the Brain
  /// preflight's steps open the task as the 「当前计划」 recitation block,
  /// which the model then keeps current through the `plan` tool. Same shape
  /// rules as the tool: blanks dropped, the list replaces any old plan.
  void seedPlan(List<String> steps) {
    _steps
      ..clear()
      ..addAll([
        for (final step in steps)
          if (step.trim().isNotEmpty) step.trim(),
      ]);
  }

  /// Appends one progress note.
  Future<String> _note(ToolCall call) async {
    final args = decodeArguments(call.argumentsJson);
    final text = args['text'];
    if (text is! String || text.trim().isEmpty) {
      return 'error: note requires a non-empty "text"';
    }
    _notes.add(text.trim());
    return 'note recorded';
  }

  /// Renders the 「当前计划」 recitation paragraph: the plan as a numbered
  /// list (first [maxRecitedSteps] steps) plus the latest notes as bullets
  /// (last [maxRecitedNotes]). Null while nothing was recorded, so bare
  /// task rounds keep their prompt exactly as before.
  String? recitationBlock() {
    if (_steps.isEmpty && _notes.isEmpty) return null;
    final lines = <String>['「当前计划」'];
    final shownSteps = _steps.length > maxRecitedSteps
        ? _steps.sublist(0, maxRecitedSteps)
        : _steps;
    for (var i = 0; i < shownSteps.length; i++) {
      lines.add('${i + 1}. ${shownSteps[i]}');
    }
    if (_notes.isNotEmpty) {
      final shownNotes = _notes.length > maxRecitedNotes
          ? _notes.sublist(_notes.length - maxRecitedNotes)
          : _notes;
      lines.add('最新进展:');
      for (final note in shownNotes) {
        lines.add('- $note');
      }
    }
    return lines.join('\n');
  }
}

/// Opens the memory paragraph composed by `systemPromptWithMemory`
/// (chat_session.dart); the recitation block must sit before it.
const String memoryBlockMarker = '「长期记忆」';

/// Matches an injected 「当前计划」 paragraph: from the marker up to the
/// next paragraph opening with 「 (the memory block) or the prompt end.
/// The block itself never contains blank lines, so `\n\n「` reliably ends
/// it.
final RegExp _recitationParagraph = RegExp(r'「当前计划」[\s\S]*?(?=\n\n「|$)');

String _trimNewlines(String text) =>
    text.replaceAll(RegExp(r'\n+$'), '').replaceAll(RegExp(r'^\n+'), '');

/// Re-splices the current 「当前计划」 [block] into a composed system
/// prompt: a previously injected paragraph (stale round state) is stripped
/// first, then the fresh block lands after the 「工具使用守则」 rules and
/// before the 「长期记忆」 memory paragraph — or at the end when there is
/// no memory block. Null [block] only strips (used when the fresh run's
/// notes state is still empty, e.g. after a resume).
String spliceRecitation(String systemContent, String? block) {
  var head = systemContent.replaceAll(_recitationParagraph, '');
  String? memory;
  final markerAt = head.indexOf(memoryBlockMarker);
  if (markerAt >= 0) {
    memory = head.substring(markerAt);
    head = head.substring(0, markerAt);
  }
  head = _trimNewlines(head);
  memory = memory == null ? null : _trimNewlines(memory);
  return [
    if (head.isNotEmpty) head,
    if (block != null && block.isNotEmpty) block,
    if (memory != null && memory.isNotEmpty) memory,
  ].join('\n\n');
}
