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
