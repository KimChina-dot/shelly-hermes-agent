/// Key catalog for the v3.0 migration pipeline
/// (docs/audit/V3_MIGRATION_PLAN.md §1, docs/audit/MIGRATION_RISK.md R1).
///
/// R1 freezes the `shelly.*` SharedPreferences keys that must survive the
/// v2.x → v3.0 upgrade; that list doubles as the acceptance table for the
/// migration's [backup] and [validate] stages. Keys added after the R1
/// audit snapshot (`shelly.capability.trust`, `shelly.mission.missions`)
/// are included so the catalog tracks the live tree.
///
/// The catalog drives *validation* only — [MigrationManager]'s backup stage
/// snapshots every `shelly.*` key it finds (minus the migration's own
/// namespaces), so an unknown key is never silently dropped from the
/// backup; it is only reported as unvalidated.
library;

/// Value shape family the validator asserts for one key.
enum MigrationValueKind {
  /// JSON array payload (`shelly.conversations`, `shelly.memory.facts`, …).
  jsonList,

  /// JSON object payload (`shelly.model.config`, checkpoints, …).
  jsonMap,

  /// Raw non-JSON string (`shelly.agent.profile.active`, `shelly.lan.token`).
  plainString,

  /// Boolean flag persisted with setBool (`shelly.tts.enabled`, …).
  plainBool,

  /// Integer persisted with setInt (`shelly.update.lastcheck`, …).
  plainInt,

  /// String list persisted with setStringList (`shelly.plugin.installed`).
  plainStringList,
}

/// Validation spec for one `shelly.*` prefs key (one R1 table row).
class MigrationKeySpec {
  const MigrationKeySpec({
    required this.key,
    required this.kind,
    this.entryFields = const [],
    this.requiredFields = const [],
    this.note,
  });

  /// Exact prefs key, or a key prefix when [isPrefix] is true.
  final String key;

  /// Expected shape family.
  final MigrationValueKind kind;

  /// For [MigrationValueKind.jsonList]: field names every entry object must
  /// carry (presence check only — the reader stays lenient about types, the
  /// same way every store's `fromJson` already is).
  final List<String> entryFields;

  /// For [MigrationValueKind.jsonMap]: top-level fields that must exist.
  final List<String> requiredFields;

  /// Provenance note (R1 table row / defining file).
  final String? note;

  /// Prefix specs match every key starting with [key]
  /// (e.g. `shelly.checkpoint.<conversationId>`).
  bool get isPrefix => key.endsWith('.');
}

/// Backup envelope key — a single JSON value holding the pre-migration
/// snapshot of every `shelly.*` data key (V3_MIGRATION_PLAN.md §1 backup).
const String kMigrationBackupKey = 'shelly.migration.backup.v3';

/// Terminal-state key written by the pipeline: `completed` or `rolledback`.
const String kMigrationStateKey = 'shelly.migration.state';

/// Migration bookkeeping namespace — never included in the backup snapshot.
const String kMigrationNamespace = 'shelly.migration.';

/// Prefix for migration output keys: `shelly.conversations` migrates to
/// `shelly.v3.conversations`, `shelly.checkpoint.a` to
/// `shelly.v3.checkpoint.a`. Output keys are never treated as source data
/// (a crashed run's leftovers must not leak into the next backup).
const String kMigratedKeyPrefix = 'shelly.v3.';

/// The R1 acceptance table. Order: exact keys first, then prefix specs.
const List<MigrationKeySpec> kMigrationKeySpecs = [
  // --- state/settings_store.dart (R1 §1.1) ---
  MigrationKeySpec(
    key: 'shelly.model.config',
    kind: MigrationValueKind.jsonMap,
    note: 'ModelConfig.toJson() — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.model.aux',
    kind: MigrationValueKind.jsonMap,
    note: 'aux ModelConfig.toJson() — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.model.aux.enabled',
    kind: MigrationValueKind.plainBool,
    note: 'bool — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.conversations',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id', 'title', 'updatedAt', 'messageCount'],
    note: 'List<ConversationSummary> — R1 §1.1, verify-critical',
  ),
  MigrationKeySpec(
    key: 'shelly.agent.profiles',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id'],
    note: 'List<AgentProfile> — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.agent.profile.active',
    kind: MigrationValueKind.plainString,
    note: 'active profile id — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.task.active',
    kind: MigrationValueKind.jsonMap,
    requiredFields: ['conversationId', 'taskId'],
    note: 'TaskRecoveryRecord — R1 §1.1 / R3',
  ),
  MigrationKeySpec(
    key: 'shelly.memory.settings',
    kind: MigrationValueKind.jsonMap,
    note: 'MemorySettings — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.mcp.servers',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id'],
    note: 'List<McpServerConfig> — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.mcp.stdio',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id', 'command'],
    note: 'List<McpStdioServerConfig> — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.mcp.toolprints',
    kind: MigrationValueKind.jsonMap,
    note: 'serverId → fingerprint map — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.tts.enabled',
    kind: MigrationValueKind.plainBool,
    note: 'bool — R1 §1.1',
  ),
  MigrationKeySpec(
    key: 'shelly.mcp.bridge',
    kind: MigrationValueKind.jsonMap,
    note: 'McpBridgeConfig — R1 §1.1',
  ),

  // --- other stores (R1 §1.2) ---
  MigrationKeySpec(
    key: 'shelly.memory.facts',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id', 'text'],
    note: 'List<MemoryFact> — R1 §1.2, verify-critical',
  ),
  MigrationKeySpec(
    key: 'shelly.crash.logs',
    kind: MigrationValueKind.jsonList,
    note: 'List<CrashEntry> — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.usage.stats',
    kind: MigrationValueKind.jsonList,
    note: 'List<UsageEntry> — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.sched.tasks',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id'],
    note: 'List<ScheduledTask> — R1 §1.2, verify-critical',
  ),
  MigrationKeySpec(
    key: 'shelly.memory.maintenance.lastRun',
    kind: MigrationValueKind.plainInt,
    note: 'epoch millis — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.memory.recallAgeDays',
    kind: MigrationValueKind.plainInt,
    note: 'int — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.memory.archivalCap',
    kind: MigrationValueKind.plainInt,
    note: 'int — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.lan.enabled',
    kind: MigrationValueKind.plainBool,
    note: 'bool — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.lan.token',
    kind: MigrationValueKind.plainString,
    note: 'pairing token — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.plugin.installed',
    kind: MigrationValueKind.plainStringList,
    note: 'installed DSH plugin ids — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.update.lastcheck',
    kind: MigrationValueKind.plainInt,
    note: 'epoch millis — R1 §1.2',
  ),
  MigrationKeySpec(
    key: 'shelly.sched.bgstate',
    kind: MigrationValueKind.jsonMap,
    note: 'due-task counter JSON (Dart writes, WorkManager reads) — R1 §1.2',
  ),

  // --- keys added after the R1 audit snapshot ---
  MigrationKeySpec(
    key: 'shelly.capability.trust',
    kind: MigrationValueKind.jsonMap,
    note: 'capability trust grants — post-R1 (PHASE 4ff)',
  ),
  MigrationKeySpec(
    key: 'shelly.mission.missions',
    kind: MigrationValueKind.jsonList,
    entryFields: ['id'],
    note: 'List<AgentMission> — post-R1 (PHASE 7ff)',
  ),

  // --- prefix specs last (R1 §1.1 / §1.2) ---
  MigrationKeySpec(
    key: 'shelly.checkpoint.',
    kind: MigrationValueKind.jsonMap,
    requiredFields: ['version', 'messages'],
    note: 'AgentCheckpoint per conversation — R1 §1.1 / R3, verify-critical',
  ),
  // `shelly.secure.<name>` lives in secure storage (platform/secure_box),
  // NOT in SharedPreferences, so it never appears in a prefs key scan; the
  // spec exists to document that exclusion (R1 §1.2 last row).
  MigrationKeySpec(
    key: 'shelly.secure.',
    kind: MigrationValueKind.plainString,
    note: 'secure-storage prefix, out of prefs scope — R1 §1.2',
  ),
];

/// Looks up the spec for [key]: exact match first, then prefix match.
/// Null for keys outside the R1 catalog.
MigrationKeySpec? migrationSpecForKey(String key) {
  for (final spec in kMigrationKeySpecs) {
    if (!spec.isPrefix && spec.key == key) return spec;
  }
  for (final spec in kMigrationKeySpecs) {
    if (spec.isPrefix && key.startsWith(spec.key)) return spec;
  }
  return null;
}
