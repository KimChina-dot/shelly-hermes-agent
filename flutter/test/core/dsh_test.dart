import 'package:flutter_test/flutter_test.dart';
import 'package:shelly_hermes/core/agent_core.dart';
import 'package:shelly_hermes/core/dsh/hermes_bridge.dart';
import 'package:shelly_hermes/core/dsh/installer.dart';
import 'package:shelly_hermes/core/dsh/manifest.dart';
import 'package:shelly_hermes/core/dsh/plugin.dart';
import 'package:shelly_hermes/core/dsh/registry.dart';
import 'package:shelly_hermes/core/dsh/tool_registry.dart';
import 'package:shelly_hermes/core/hermes/knowledge_store.dart';
import 'package:shelly_hermes/core/models.dart';
import 'package:shelly_hermes/core/shell/shell_executor.dart';
import 'package:shelly_hermes/core/tools/workspace.dart';

class _RecordingRunner implements ProcessRunner {
  final List<String> executed = [];

  @override
  bool get isSupported => true;

  @override
  Future<ShellResult> run(ShellRequest request,
      {CancellationSignal? cancellation}) async {
    executed.add(request.command);
    return ShellResult(exitCode: 0, duration: Duration.zero, stdout: 'ok');
  }
}

const _manifestText = '''
{
  "id": "dev.acme.vendor",
  "name": "Vendor Tools",
  "version": "1.2.0",
  "description": "Vendor CLI wrappers",
  "author": "ACME",
  "runtime": "shell",
  "permissions": ["terminal.execute", "workspace.read"],
  "tools": [
    {"name": "vendor_build", "description": "Runs vendor build", "risk": "medium", "command": "vendor build {target}"},
    {"name": "vendor_report", "description": "Runs vendor report", "risk": "low", "command": "vendor report"}
  ]
}
''';

void main() {
  group('DshManifest', () {
    test('parses and validates a good manifest', () {
      final manifest = DshManifest.parse(_manifestText);
      expect(manifest.id, 'dev.acme.vendor');
      expect(manifest.runtime, 'shell');
      expect(
          manifest.permissions,
          containsAll(
              [DshPermissions.terminalExecute, DshPermissions.workspaceRead]));
      expect(manifest.tools, hasLength(2));
      expect(manifest.tools.first.command, 'vendor build {target}');
    });

    test('rejects bad id, version, runtime, unknown permissions, empty tools',
        () {
      for (final (json, problem) in [
        (
          '{"id":"vendor","name":"V","version":"1.0.0","runtime":"shell","tools":[{"name":"a","command":"a"}]}',
          'reverse-DNS'
        ),
        (
          '{"id":"dev.a.v","name":"V","version":"1.x","runtime":"shell","tools":[{"name":"a","command":"a"}]}',
          'semver'
        ),
        (
          '{"id":"dev.a.v","name":"V","version":"1.0.0","runtime":"wasm","tools":[{"name":"a","command":"a"}]}',
          "runtime must be 'shell' or 'dart'"
        ),
        (
          '{"id":"dev.a.v","name":"V","version":"1.0.0","runtime":"shell","permissions":["root"],"tools":[{"name":"a","command":"a"}]}',
          'unknown permission: root'
        ),
        (
          '{"id":"dev.a.v","name":"V","version":"1.0.0","runtime":"shell","tools":[]}',
          'at least one tool'
        ),
      ]) {
        expect(() => DshManifest.parse(json),
            throwsA(isA<DshManifestException>()),
            reason: problem);
      }
    });

    test('rejects invalid JSON and non-objects', () {
      expect(() => DshManifest.parse('nope'),
          throwsA(isA<DshManifestException>()));
      expect(() => DshManifest.parse('[1,2]'),
          throwsA(isA<DshManifestException>()));
    });
  });

  group('DshHostContext permissions', () {
    test('denies undeclared capabilities', () async {
      final context = DshHostContext(
        pluginId: 'dev.a.p',
        permissions: {DshPermissions.workspaceRead},
        workspace: MemoryWorkspace(),
      );
      // workspace.read granted — the view is reachable and can read.
      expect(await context.workspace.readFile('x.txt'), isNull);
      expect(
        () => DshHostContext(
          pluginId: 'dev.a.p',
          permissions: {DshPermissions.workspaceRead},
          workspace: MemoryWorkspace(),
        ).shell,
        throwsA(isA<DshPermissionDenied>()),
      );
      expect(
        context.workspace.writeFile('x.txt', 'nope'),
        throwsA(isA<DshPermissionDenied>()),
      );
    });
  });

  group('DshPluginRegistry lifecycle', () {
    test('full lifecycle register→load→enable→disable→unload→unregister',
        () async {
      final registry = DshPluginRegistry();
      final plugin = ShellPlugin(DshManifest.parse(_manifestText));
      registry.register(plugin);
      expect(registry.lifecycleOf('dev.acme.vendor'), DshLifecycle.registered);
      await registry.load('dev.acme.vendor',
          shell: ShellExecutor(runner: _RecordingRunner()));
      await registry.enable('dev.acme.vendor');
      expect(registry.lifecycleOf('dev.acme.vendor'), DshLifecycle.enabled);
      expect(registry.listEnabled(), hasLength(1));
      await registry.disable('dev.acme.vendor');
      await registry.unload('dev.acme.vendor');
      registry.unregister('dev.acme.vendor');
      expect(registry.find('dev.acme.vendor'), isNull);
    });

    test('invalid transitions are rejected', () async {
      final registry = DshPluginRegistry();
      registry.register(ShellPlugin(DshManifest.parse(_manifestText)));
      await expectLater(
        registry.enable('dev.acme.vendor'),
        throwsA(isA<DshRegistryError>()),
      );
      registry.unregister('dev.acme.vendor');
      expect(
        () => registry.unregister('dev.acme.vendor'),
        throwsA(isA<DshRegistryError>()),
      );
    });

    test('duplicate ids and tool-name collisions are rejected', () {
      final registry = DshPluginRegistry();
      final plugin = ShellPlugin(DshManifest.parse(_manifestText));
      registry.register(plugin);
      expect(() => registry.register(ShellPlugin(plugin.manifest)),
          throwsA(isA<DshRegistryError>()));
      final clone = DshManifest.fromJson({
        ...plugin.manifest.toJson(),
        'id': 'dev.other.clone',
      });
      expect(() => registry.register(ShellPlugin(clone)),
          throwsA(isA<DshRegistryError>()));
    });
  });

  group('DshToolRegistry + trust policy', () {
    late DshPluginRegistry plugins;
    late DshTrustPolicy trust;
    late DshToolRegistry tools;
    late _RecordingRunner runner;

    setUp(() async {
      plugins = DshPluginRegistry();
      trust = DshTrustPolicy();
      tools = DshToolRegistry(pluginRegistry: plugins, trustPolicy: trust);
      runner = _RecordingRunner();
      plugins.register(ShellPlugin(DshManifest.parse(_manifestText)));
      await plugins.load('dev.acme.vendor',
          shell: ShellExecutor(runner: runner));
      await plugins.enable('dev.acme.vendor');
    });

    test('specs and schemas expose plugin tools', () {
      expect(tools.specs.map((s) => s.name),
          containsAll(['vendor_build', 'vendor_report']));
      expect(tools.openAiToolsJson(), hasLength(2));
    });

    test('unknown plugin tools are blocked', () async {
      final out = await tools.execute(const ToolCall(
        id: 't1',
        name: 'vendor_missing',
        argumentsJson: '{}',
      ));
      expect(out, contains('blocked by policy'));
      expect(runner.executed, isEmpty);
    });

    test('asked tools execute when approval let them through', () async {
      trust.setTrust('vendor_report', DshTrust.ask);
      final out = await tools.execute(const ToolCall(
        id: 't2',
        name: 'vendor_report',
        argumentsJson: '{}',
      ));
      expect(out, contains('risk=low'));
      expect(runner.executed.single, 'vendor report');
    });

    test('allowed tools run without ceremony', () async {
      trust.setTrust('vendor_build', DshTrust.allowed);
      await tools.execute(const ToolCall(
        id: 't3',
        name: 'vendor_build',
        argumentsJson: '{"target":"web"}',
      ));
      expect(runner.executed.single, 'vendor build web');
    });

    test('disabled plugins disappear from the tool surface', () async {
      await plugins.disable('dev.acme.vendor');
      expect(tools.specs, isEmpty);
      final out = await tools.execute(const ToolCall(
        id: 't4',
        name: 'vendor_report',
        argumentsJson: '{}',
      ));
      expect(out, contains('blocked'));
    });
  });

  group('DshInstaller', () {
    late MemoryWorkspace ws;
    late DshPluginRegistry plugins;
    late DshInstaller installer;

    setUp(() {
      ws = MemoryWorkspace();
      plugins = DshPluginRegistry();
      installer = DshInstaller(registry: plugins, workspace: ws);
    });

    test('installs from a local manifest file end-to-end', () async {
      ws.files['dev.acme/manifest.json'] = _manifestText;
      final plugin = await installer.installFrom('dev.acme/manifest.json');
      expect(plugin.manifest.id, 'dev.acme.vendor');
      expect(plugins.lifecycleOf('dev.acme.vendor'), DshLifecycle.enabled);
      expect(ws.files['.shelly/plugins/dev.acme.vendor/manifest.json'],
          contains('dev.acme.vendor'));
    });

    test('dart-runtime plugins must be embedded', () {
      const dartManifest = '''
{"id":"dev.a.embedded","name":"E","version":"1.0.0","runtime":"dart",
 "tools":[{"name":"embedded_tool","description":"d"}]}
''';
      expect(
        installer.installFromText(dartManifest),
        throwsA(isA<DshManifestException>()),
      );
    });

    test('uninstall walks the lifecycle backwards and cleans files',
        () async {
      ws.files['dev.acme/manifest.json'] = _manifestText;
      await installer.installFrom('dev.acme/manifest.json');
      await installer.uninstall('dev.acme.vendor');
      expect(plugins.find('dev.acme.vendor'), isNull);
      expect(
        ws.files
            .containsKey('.shelly/plugins/dev.acme.vendor/manifest.json'),
        isFalse,
      );
    });
  });

  group('DshHermesBridge', () {
    test('lifecycle events land in the ledger', () async {
      final ws = MemoryWorkspace();
      final bridge = DshHermesBridge(
        store: HermesKnowledgeStore(workspace: ws),
      );
      await bridge.recordInstalled('dev.acme.vendor', '1.2.0');
      await bridge.recordFailed('dev.other.x', 'no shell');
      final entries = await HermesKnowledgeStore(workspace: ws).loadAll();
      expect(entries, hasLength(2));
      expect(entries.first.category, 'fact');
      expect(entries.first.content, contains('dev.acme.vendor'));
      expect(entries.last.content, contains('no shell'));
    });
  });
}
