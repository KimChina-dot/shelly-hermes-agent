// V3.1 搬迁锚点(PHASE 19 冻结,V3 计划 P14):move → lib/capability/dsh/dsh_provider.dart。
// 能力层 provider 装配归位,并消除 capability→state 反向边(dynamic_skill_host 直连)。
// 命令与风险见 docs/audit/V31_MIGRATION_CHECKLIST.md M2;facade export 行是唯一 features 改写点。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/dsh/registry.dart';
import '../core/dsh/tool_registry.dart';

/// App-wide DSH plugin host (PHASE 11-16 wiring). The registry is shared so
/// plugins installed on the capabilities page are visible to every new task.
final dshRegistryProvider = Provider<DshPluginRegistry>((ref) {
  return DshPluginRegistry();
});

final dshTrustProvider = Provider<DshTrustPolicy>((ref) {
  return DshTrustPolicy();
});

final dshToolsProvider = Provider<DshToolRegistry>((ref) {
  return DshToolRegistry(
    pluginRegistry: ref.watch(dshRegistryProvider),
    trustPolicy: ref.watch(dshTrustProvider),
  );
});
