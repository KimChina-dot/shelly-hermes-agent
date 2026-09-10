// PHASE 15 safety net (TEST_COVERAGE_MAP §3): assembly tests for the DSH
// provider graph — the audit found no direct tests for dsh_provider.dart,
// so any rewiring of the provider graph (e.g. a second registry instance
// appearing) had no gate. These tests pin the graph's shape: ONE shared
// registry + ONE trust policy feed the tool registry, and a plugin
// installed on the shared registry is visible to every consumer with the
// fail-closed trust gate enforced through the shared policy.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/dsh/manifest.dart';
import 'package:shelly_hermes/core/dsh/plugin.dart';
import 'package:shelly_hermes/core/dsh/tool_registry.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/state/dsh_provider.dart';

const _manifestText = '''
{
  "id": "dev.acme.vendor",
  "name": "Vendor Tools",
  "version": "1.2.0",
  "description": "Vendor CLI wrappers",
  "author": "ACME",
  "runtime": "shell",
  "permissions": ["workspace.read"],
  "tools": [
    {"name": "vendor_build", "description": "Runs vendor build", "risk": "medium", "command": "vendor build {target}"}
  ]
}
''';

void main() {
  test('the provider graph shares one registry and one trust policy', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final registry = container.read(dshRegistryProvider);
    final trust = container.read(dshTrustProvider);

    // Provider caching: every consumer sees the SAME instances — plugins
    // installed on the capabilities page are visible to every new task.
    expect(container.read(dshRegistryProvider), same(registry));
    expect(container.read(dshTrustProvider), same(trust));

    // The tool registry is wired to those very instances, not copies.
    final tools = container.read(dshToolsProvider);
    expect(tools.pluginRegistry, same(registry));
    expect(tools.trustPolicy, same(trust));
    expect(container.read(dshToolsProvider), same(tools));
  });

  test('an enabled plugin surfaces through the tool registry, gated by trust',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final registry = container.read(dshRegistryProvider);
    registry.register(ShellPlugin(DshManifest.parse(_manifestText)));

    final tools = container.read(dshToolsProvider);

    // Default posture is fail-closed: an undecided tool reads as blocked…
    expect(container.read(dshTrustProvider).trustFor('vendor_build'),
        DshTrust.blocked);
    // …and while the plugin is not enabled its tools are invisible and
    // refused outright.
    expect(tools.specs.map((s) => s.name), isNot(contains('vendor_build')));
    final unknown = await tools.execute(const ToolCall(
        id: 't0', name: 'vendor_build', argumentsJson: '{"target":"lib"}'));
    expect(unknown, contains('blocked by policy'));

    await registry.load('dev.acme.vendor');
    await registry.enable('dev.acme.vendor');

    expect(tools.specs.map((s) => s.name), contains('vendor_build'));
    expect(tools.openAiToolsJson().first['function']['name'], 'vendor_build');

    // First contact through execute records 'ask' on the SHARED trust
    // policy — the approval gateway already asked upstream, so execution
    // proceeds to the plugin itself (which fails: load() got no shell,
    // a plugin error, not a trust block).
    final firstContact = await tools.execute(const ToolCall(
        id: 't1', name: 'vendor_build', argumentsJson: '{"target":"lib"}'));
    expect(firstContact, contains('Error: plugin tool "vendor_build" failed'));
    expect(firstContact, isNot(contains('blocked')));
    expect(container.read(dshTrustProvider).trustFor('vendor_build'),
        DshTrust.ask);

    // Explicit revocation on the shared policy blocks the same graph.
    container.read(dshTrustProvider).setTrust('vendor_build', DshTrust.blocked);
    final revoked = await tools.execute(const ToolCall(
        id: 't2', name: 'vendor_build', argumentsJson: '{"target":"lib"}'));
    expect(revoked, contains('blocked by trust policy'));

    // Granting trust through the shared policy unlocks it again.
    container
        .read(dshTrustProvider)
        .setTrust('vendor_build', DshTrust.allowed);
    final unlocked = await tools.execute(const ToolCall(
        id: 't3', name: 'vendor_build', argumentsJson: '{"target":"lib"}'));
    expect(unlocked, contains('Error: plugin tool "vendor_build" failed'));
    expect(unlocked, isNot(contains('blocked')));

    // Disabling the plugin removes the tool from every consumer again.
    await registry.disable('dev.acme.vendor');
    expect(tools.specs.map((s) => s.name), isNot(contains('vendor_build')));
  });
}
