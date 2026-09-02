import 'package:flutter/semantics.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

void main() {
  // Expose the Flutter semantics tree as DOM nodes so browser-based
  // verification tooling (frontend MCP, screen readers) can interact with
  // the web dev harness. No-op cost on other platforms.
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  runApp(const ProviderScope(child: ShellyApp()));
}
