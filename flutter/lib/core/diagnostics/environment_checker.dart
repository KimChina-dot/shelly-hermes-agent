import '../gateway/model_discovery.dart';
import '../shell/shell_executor.dart';
import '../tools/workspace.dart';

enum CheckLevel { ok, warn, fail }

/// One row of the capability page's 运行环境 self-check.
class EnvironmentCheck {
  const EnvironmentCheck({
    required this.id,
    required this.label,
    required this.level,
    required this.detail,
  });

  final String id;
  final String label;
  final CheckLevel level;
  final String detail;
}

/// Gateway probe seam (wraps ModelDiscovery.testConnection so tests can
/// stub connectivity without network).
typedef GatewayProbe = Future<Duration> Function({
  required String baseUrl,
  required String model,
  required String apiKey,
});

Future<Duration> _defaultProbeGateway({
  required String baseUrl,
  required String model,
  required String apiKey,
}) =>
    ModelDiscovery().testConnection(
      baseUrl: baseUrl,
      model: model,
      apiKey: apiKey,
    );

/// One-shot diagnostics for the agent's execution environment: workspace
/// writability, shell availability, gateway connectivity plus the context
/// window the compactor plans against, and the plugin surfaces (DSH, MCP).
class EnvironmentChecker {
  EnvironmentChecker({
    required this.workspace,
    required this.processRunner,
    this.baseUrl = '',
    this.modelId = '',
    this.apiKey = '',
    this.contextWindowTokens = 0,
    this.probeGateway = _defaultProbeGateway,
    this.dshToolCount = 0,
    this.mcpServerNames = const [],
  });

  final Workspace workspace;
  final ProcessRunner processRunner;

  /// Empty model id / base url => the model rows report 未配置.
  final String baseUrl;
  final String modelId;
  final String apiKey;
  final int contextWindowTokens;

  final GatewayProbe probeGateway;
  final int dshToolCount;
  final List<String> mcpServerNames;

  static const _probePath = '.shelly-env-probe.txt';

  bool get _modelReady => baseUrl.isNotEmpty && modelId.isNotEmpty;

  Future<List<EnvironmentCheck>> run() {
    return Future.wait([
      _checkWorkspace(),
      _checkShell(),
      _checkGateway(),
      Future.value(_checkContextWindow()),
      Future.value(_checkDsh()),
      Future.value(_checkMcp()),
    ]);
  }

  Future<EnvironmentCheck> _checkWorkspace() async {
    const id = 'workspace';
    const label = '工作区(授权与可写)';
    try {
      await workspace.writeFile(_probePath, 'probe');
      final visible = await workspace.exists(_probePath);
      await workspace.deleteFile(_probePath);
      if (!visible) {
        return EnvironmentCheck(
            id: id, label: label, level: CheckLevel.fail, detail: '写入后无法读回,工作区异常');
      }
      return const EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.ok,
        detail: '已授权且可读写',
      );
    } catch (error) {
      return EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.fail,
        detail: '不可写或未授权:$error',
      );
    }
  }

  Future<EnvironmentCheck> _checkShell() async {
    const id = 'shell';
    const label = 'Shell 可用性';
    if (!processRunner.isSupported) {
      return const EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.warn,
        detail: '本设备不支持 Shell(文件与记忆工具不受影响)',
      );
    }
    try {
      final result = await processRunner
          .run(const ShellRequest(
            command: 'echo shelly-env-probe',
            timeout: Duration(seconds: 5),
          ))
          .timeout(const Duration(seconds: 8));
      if (result.timedOut || result.exitCode != 0) {
        return EnvironmentCheck(
          id: id,
          label: label,
          level: CheckLevel.fail,
          detail: result.stderr.isEmpty ? '探测命令执行失败' : result.stderr,
        );
      }
      return EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.ok,
        detail: '可执行(${result.duration.inMilliseconds}ms)',
      );
    } catch (error) {
      return EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.fail,
        detail: '执行探测失败:$error',
      );
    }
  }

  Future<EnvironmentCheck> _checkGateway() async {
    const id = 'gateway';
    const label = '模型网关连通性';
    if (!_modelReady) {
      return const EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.warn,
        detail: '模型未配置,当前为演示模式',
      );
    }
    try {
      final latency = await probeGateway(
        baseUrl: baseUrl,
        model: modelId,
        apiKey: apiKey,
      ).timeout(const Duration(seconds: 15));
      return EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.ok,
        detail: '连接正常 ${latency.inMilliseconds}ms · $modelId',
      );
    } catch (error) {
      return EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.fail,
        detail: '连接失败:$error',
      );
    }
  }

  EnvironmentCheck _checkContextWindow() {
    const id = 'context';
    const label = '模型上下文窗口';
    if (!_modelReady) {
      return const EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.warn,
        detail: '模型未配置,压缩不可用',
      );
    }
    if (contextWindowTokens <= 0) {
      return const EnvironmentCheck(
        id: id,
        label: label,
        level: CheckLevel.warn,
        detail: '未知窗口,按 32K 兜底',
      );
    }
    return EnvironmentCheck(
      id: id,
      label: label,
      level: CheckLevel.ok,
      detail: '$contextWindowTokens tokens',
    );
  }

  EnvironmentCheck _checkDsh() {
    return EnvironmentCheck(
      id: 'dsh',
      label: 'DSH 插件工具',
      level: CheckLevel.ok,
      detail: dshToolCount == 0 ? '未启用插件' : '$dshToolCount 个工具已启用',
    );
  }

  EnvironmentCheck _checkMcp() {
    if (mcpServerNames.isEmpty) {
      return const EnvironmentCheck(
        id: 'mcp',
        label: 'MCP 服务器',
        level: CheckLevel.ok,
        detail: '未连接服务器',
      );
    }
    final shown = mcpServerNames.take(3).join('、');
    final more = mcpServerNames.length > 3 ? ' 等 ${mcpServerNames.length} 台' : '';
    return EnvironmentCheck(
      id: 'mcp',
      label: 'MCP 服务器',
      level: CheckLevel.ok,
      detail: '$shown$more',
    );
  }
}
