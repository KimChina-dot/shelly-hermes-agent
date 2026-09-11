/// Facade over the legacy `core/` and `state/` layers for the features layer.
///
/// PHASE 16 (V3 migration plan P10) — features consumption-surface
/// convergence. Every file under `lib/features/` now reaches core/state
/// symbols through this single facade instead of importing
/// `../../core/...` / `../../state/...` paths directly (risk R7 in
/// docs/audit/MIGRATION_RISK.md).
///
/// Per the controller decision, v3.0 does NOT move directories: `core/` and
/// `state/` stay physically in place, and this file is the sole anchor the
/// 3.1 physical relocation will rewrite — when a module moves, only its
/// `export` line below changes, not the features import graph.
///
/// The export set below is exactly the union of core/state libraries that
/// features consume today (R7 table + grep verification, 2026-09-10).
/// Exception: `features/approval/approval_sheet.dart` already consumes the
/// approval vocabulary through the `capability/approval` port (PHASE 12)
/// and is intentionally left on that path.
///
/// This file must stay logic-free: re-exports only.
///
/// PHASE 19 (V3 migration plan P14) — facade FROZEN. Every export line below
/// carries a keep/wrap/move disposition in docs/audit/MODULE_MAP.md (§1-§8);
/// the six `move` entries are executed in v3.1 strictly per
/// docs/audit/V31_MIGRATION_CHECKLIST.md (M1-M6, one mechanical step + full
/// test gate each). Until then this export set does not change: additions or
/// removals beyond the checklist are rejected by the controller decision.
library;

// ---------------------------------------------------------------------------
// state/ — session, settings, providers (R7: the 33 direct-import surface)
// ---------------------------------------------------------------------------

export 'state/chat_session.dart';
export 'state/conversation_export.dart';
export 'state/conversation_search.dart';
export 'state/dsh_provider.dart';
export 'state/hermes_provider.dart';
export 'state/lan_companion.dart';
export 'state/memory_maintenance.dart';
export 'state/plugin_repo.dart';
export 'state/scheduled_tasks.dart';
export 'state/settings_store.dart';
export 'state/update_check.dart';
export 'state/usage_stats.dart';

// ---------------------------------------------------------------------------
// core/ — agent model, events, gateway, tools, memory (R7 §3 coupling table)
// ---------------------------------------------------------------------------

export 'core/agent_profile.dart';
export 'core/approval_broker.dart';
export 'core/crash/crash_log_store.dart';
export 'core/diagnostics/environment_checker.dart';
export 'core/dsh/installer.dart';
export 'core/dsh/plugin.dart';
export 'core/dsh/tool_registry.dart';
export 'core/error_messages.dart';
export 'core/events/agent_events.dart';
export 'core/events/event_bus.dart';
export 'core/gateway/model_discovery.dart';
export 'core/gateway/providers.dart';
export 'core/hermes/forgetting.dart';
export 'core/hermes/knowledge.dart';
export 'core/hermes/memory_settings.dart';
export 'core/memory/memory_store.dart';
export 'core/mcp/mcp_client.dart';
export 'core/mcp/mcp_guard.dart';
export 'core/models.dart';
export 'core/platform/background_tasks.dart';
export 'core/platform/home_widget_bridge.dart';
export 'core/task_queue.dart';
export 'core/task_recovery.dart';
export 'core/tools/registry.dart';
export 'core/tts/tts_service.dart';
