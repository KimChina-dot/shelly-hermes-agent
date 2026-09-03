// Private fields take named public constructor params, so initializing
// formals do not apply here.
// ignore_for_file: prefer_initializing_formals
import '../agent_core.dart';
import '../models.dart';

/// Audit sink: one JSONL line per tool execution attempt. The Android host
/// writes to a workspace-side log file; tests capture lines in memory.
abstract interface class AuditSink {
  void write(String line);
}

class InMemoryAuditSink implements AuditSink {
  final List<String> lines = [];

  @override
  void write(String line) => lines.add(line);
}

/// JSONL audit trail over tool activity, ported from the Kotlin host's
/// audit semantics: every call is recorded before and after execution with
/// outcome and duration, and audit failures never break the agent loop.
class JsonlAuditLog implements AgentObserver {
  JsonlAuditLog({required AuditSink sink, DateTime Function()? clock})
      : _sink = sink,
        _clock = clock ?? DateTime.now;

  final AuditSink _sink;
  final DateTime Function() _clock;

  @override
  void onEvent(AgentEvent event) {
    try {
      if (event is ToolStarted) {
        _emit({
          'event': 'tool_started',
          'tool': event.toolName,
          'callId': event.toolCallId,
          'arguments': event.argumentsJson,
        });
      } else if (event is ToolFinished) {
        _emit({
          'event': 'tool_finished',
          'tool': event.toolName,
          'callId': event.toolCallId,
          'succeeded': event.succeeded,
          'durationMillis': event.durationMillis,
          if (event.result != null) 'result': event.result,
        });
      } else if (event is ApprovalWaiting) {
        _emit({
          'event': 'approval_waiting',
          'tool': event.call.name,
          'callId': event.call.id,
        });
      } else if (event is ApprovalFinished) {
        _emit({
          'event': 'approval_finished',
          'tool': event.call.name,
          'callId': event.call.id,
          if (event.decision != null) 'decision': event.decision!.name,
        });
      }
    } catch (_) {
      // Auditing must never break the agent loop.
    }
  }

  void _emit(Map<String, dynamic> fields) {
    final record = {'ts': _clock().toIso8601String(), ...fields};
    _sink.write(_jsonl(record));
  }
}

/// Minimal JSONL encoder: quotes strings with the standard escapes and
/// passes numbers/booleans/null through. Field order follows insertion.
String _jsonl(Map<String, dynamic> record) {
  final parts = <String>[];
  record.forEach((key, value) {
    final encoded = switch (value) {
      null => 'null',
      bool b => b.toString(),
      num n => n.toString(),
      _ => '"${_escape(value.toString())}"',
    };
    parts.add('"${_escape(key)}":$encoded');
  });
  return '{${parts.join(',')}}';
}

String _escape(String raw) => raw
    .replaceAll('\\', '\\\\')
    .replaceAll('"', '\\"')
    .replaceAll('\n', '\\n')
    .replaceAll('\r', '\\r')
    .replaceAll('\t', '\\t');
