/// Host-conditional [ProcessRunner] wiring: the real dart:io runner on
/// VM/Android, a reporting stub on the web dev harness.
library;

export 'process_runner_stub.dart'
    if (dart.library.io) 'process_runner_io.dart';
