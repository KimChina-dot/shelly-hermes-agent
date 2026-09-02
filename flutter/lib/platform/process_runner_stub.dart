import '../core/agent_core.dart';
import '../core/shell/shell_executor.dart';

/// Web/dev-harness fallback: shell execution is genuinely unavailable in a
/// browser, so the tool reports it instead of crashing.
class UnsupportedProcessRunner implements ProcessRunner {
  const UnsupportedProcessRunner();

  @override
  bool get isSupported => false;

  @override
  Future<ShellResult> run(ShellRequest request,
          {CancellationSignal? cancellation}) async =>
      ShellResult(
        exitCode: -1,
        duration: Duration.zero,
        stderr: 'shell execution is not supported on this host',
      );
}

ProcessRunner createProcessRunner() => const UnsupportedProcessRunner();
