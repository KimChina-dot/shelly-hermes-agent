import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, Process, ProcessSignal;

import '../core/agent_core.dart';
import '../core/shell/shell_executor.dart';

/// dart:io backed [ProcessRunner] for VM and Android hosts. Commands run
/// through the platform shell (`cmd.exe /c` on Windows, `/bin/sh -c`
/// elsewhere). Timeout and cancellation both kill the process tree's root
/// process; children spawned detached from it may linger — documented
/// limitation of Process.kill.
class IoProcessRunner implements ProcessRunner {
  const IoProcessRunner();

  @override
  bool get isSupported => true;

  @override
  Future<ShellResult> run(
    ShellRequest request, {
    CancellationSignal? cancellation,
  }) async {
    if (cancellation?.isCancelled ?? false) {
      return const ShellResult(
        exitCode: -1,
        duration: Duration.zero,
        cancelled: true,
      );
    }
    final started = Stopwatch()..start();
    final argv = Platform.isWindows
        ? ['cmd.exe', '/c', request.command]
        : ['/bin/sh', '-c', request.command];

    Process process;
    try {
      process = await Process.start(
        argv[0],
        argv.sublist(1),
        workingDirectory: request.workingDirectory,
      );
    } catch (error) {
      return ShellResult(
        exitCode: -1,
        duration: started.elapsed,
        stderr: error.toString(),
      );
    }

    final stdout = StringBuffer();
    final stderr = StringBuffer();
    final stdoutDone = process.stdout
        .transform(utf8.decoder)
        .listen(stdout.write)
        .asFuture<void>();
    final stderrDone = process.stderr
        .transform(utf8.decoder)
        .listen(stderr.write)
        .asFuture<void>();

    var timedOut = false;
    var cancelled = false;
    final timer = Timer(request.timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigterm);
    });

    int exitCode;
    try {
      if (cancellation == null) {
        exitCode = await process.exitCode;
      } else {
        exitCode = await _raceCancellation(process, cancellation, () {
          cancelled = true;
          process.kill(ProcessSignal.sigterm);
        });
      }
    } finally {
      timer.cancel();
    }
    await Future.wait([stdoutDone, stderrDone]);

    return ShellResult(
      exitCode: exitCode,
      duration: started.elapsed,
      stdout: stdout.toString(),
      stderr: stderr.toString(),
      timedOut: timedOut,
      cancelled: cancelled,
    );
  }

  Future<int> _raceCancellation(
    Process process,
    CancellationSignal cancellation,
    void Function() onCancel,
  ) {
    final completer = Completer<int>();
    process.exitCode.then((code) {
      if (!completer.isCompleted) completer.complete(code);
    });
    // Polling the cooperative flag keeps the port synchronous-friendly;
    // a 100ms cadence is imperceptible against process lifetimes.
    final poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!completer.isCompleted && cancellation.isCancelled) {
        onCancel();
      }
    });
    return completer.future.whenComplete(poll.cancel);
  }
}

/// Factory consumed by the app shell; on io hosts this is the real runner.
ProcessRunner createProcessRunner() => const IoProcessRunner();
