import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/capability/dsh/dynamic_skill_host.dart';
import 'package:shelly_hermes/capability/registry/capability.dart';
import 'package:shelly_hermes/capability/registry/capability_registry.dart';
import 'package:shelly_hermes/core/dsh/manifest.dart';
import 'package:shelly_hermes/core/dsh/plugin.dart';
import 'package:shelly_hermes/core/dsh/registry.dart';
import 'package:shelly_hermes/core/dsh/tool_registry.dart';

void main() {
  late DshPluginRegistry pluginRegistry;
  late DshToolRegistry dshTools;
  late CapabilityRegistry capabilities;
  late DynamicSkillHost host;

  setUp(() {
    pluginRegistry = DshPluginRegistry();
    dshTools = DshToolRegistry(
      pluginRegistry: pluginRegistry,
      trustPolicy: DshTrustPolicy(),
    );
    capabilities = CapabilityRegistry();
    host = DynamicSkillHost(pluginRegistry: pluginRegistry, dshTools: dshTools);
  });

  test('enabled plugins register as dsh_* capabilities', () async {
    final manifest = _manifest('weather', '天气查询');
    pluginRegistry.register(ShellPlugin(manifest));
    const manifestId = 'dev.test.weather'; // = _manifest 内的 id
    await pluginRegistry.load(manifestId);
    await pluginRegistry.enable(manifestId);

    final ids = host.syncInto(capabilities);

    expect(ids, ['dev.test.weather']);
    final cap = capabilities.byId('dev.test.weather')!;
    expect(cap.category, CapabilityCategory.dsh);
    expect(cap.riskLevel, CapabilityRiskLevel.l2Execute);
  });

  test('disabled plugins are skipped', () {
    pluginRegistry.register(ShellPlugin(_manifest('weather', '天气查询')));

    final ids = host.syncInto(capabilities);

    expect(ids, isEmpty);
    expect(capabilities.byId('dev.test.weather'), isNull);
  });

  test('a re-sync replaces the previous batch (disable removes stale caps)',
      () async {
    final manifest = _manifest('weather', '天气查询');
    pluginRegistry.register(ShellPlugin(manifest));
    const manifestId = 'dev.test.weather'; // = _manifest 内的 id
    await pluginRegistry.load(manifestId);
    await pluginRegistry.enable(manifestId);
    host.syncInto(capabilities);
    expect(capabilities.byId('dev.test.weather'), isNotNull);

    await pluginRegistry.disable(manifestId);
    host.syncInto(capabilities);

    expect(capabilities.byId('dev.test.weather'), isNull);
  });
}

DshManifest _manifest(String id, String name) => DshManifest(
      id: 'dev.test.$id',
      name: name,
      version: '1.0.0',
      description: '$name 插件',
      author: 'test',
      runtime: 'shell',
      tools: [
        const DshToolDecl(
            name: 'run', description: '执行一条命令', command: 'echo'),
      ],
    );
