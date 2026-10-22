// Run as a child process by test/exit_test.dart: `dart test/fixtures/exit_child.dart <mode> <port>`.
// Each mode ends the process in its own way, right after reporting something.
import 'dart:async';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;

Future<void> main(List<String> args) async {
  final mode = args[0];
  final port = args[1];

  // These two configure nothing in code, as a new app following the README would: the DSN, and
  // FORGE_OPS_ENVIRONMENT when set, come from the environment exit_test.dart gives this process.
  if (mode == 'dsn-only' || mode == 'development') {
    fot.init();
    if (mode == 'development') fot.init();
    fot.captureException(StateError('sent from $mode'));
    await fot.flush();
    exit(0);
  }

  fot.init((config) {
    config.dsn = 'http://key@localhost:$port/api/v1/events';
    config.environment = 'production';
  });

  switch (mode) {
    case 'sync':
      fot.runGuarded(() => throw StateError('sync crash'));
    case 'async':
      fot.runGuarded(() {
        Future<void>(() => throw StateError('async crash'));
      });
    case 'exit':
      fot.captureException(StateError('reported, then exit'));
      await fot.flush();
      exit(3);
    case 'flush-timeout':
      fot.captureException(StateError('never answered'));
      final stopwatch = Stopwatch()..start();
      final delivered = await fot.flush(timeout: const Duration(milliseconds: 200));
      stdout.writeln('$delivered ${stopwatch.elapsedMilliseconds}');
      exit(0);
  }
}
