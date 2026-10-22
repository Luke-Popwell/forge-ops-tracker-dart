import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Every test here runs test/fixtures/exit_child.dart as a real child process against a local
// listener: what's under test is what happens as a process ends, which this test's own process
// can't do.

class _ChildResult {
  _ChildResult(this.exitCode, this.stdout, this.stderr, this.messages, this.elapsed);

  final int exitCode;
  final String stdout;
  final String stderr;
  final List<String> messages;
  final Duration elapsed;
}

/// With [environment] set, the child gets only this process's variables minus `FORGE_OPS_*`, plus
/// [environment], where `{port}` in a value becomes the listener's port.
Future<_ChildResult> _runChild(String mode, {bool hang = false, Map<String, String>? environment}) async {
  final messages = <String>[];
  final server = await HttpServer.bind('localhost', 0);
  server.listen((request) async {
    final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>;
    messages.add(body['message'] as String);
    if (hang) return;
    request.response.statusCode = 202;
    await request.response.close();
  });
  try {
    final stopwatch = Stopwatch()..start();
    final childEnvironment = environment == null
        ? null
        : {
            for (final entry in Platform.environment.entries)
              if (!entry.key.startsWith('FORGE_OPS_')) entry.key: entry.value,
            for (final entry in environment.entries) entry.key: entry.value.replaceAll('{port}', '${server.port}'),
          };
    final result = await Process.run(
      Platform.resolvedExecutable,
      ['test/fixtures/exit_child.dart', mode, '${server.port}'],
      environment: childEnvironment,
      includeParentEnvironment: childEnvironment == null,
    );
    return _ChildResult(result.exitCode, result.stdout as String, result.stderr as String, messages, stopwatch.elapsed);
  } finally {
    await server.close(force: true);
  }
}

void main() {
  // The exit code the Dart VM uses for an unhandled exception.
  const unhandledExceptionExitCode = 255;

  test('runGuarded delivers a synchronous crash before the process dies of it', () async {
    final result = await _runChild('sync');

    expect(result.messages, ['Bad state: sync crash']);
    expect(result.exitCode, unhandledExceptionExitCode);
    expect(result.stderr, contains('Unhandled exception'));
    expect(result.stderr, contains('sync crash'));
  });

  test('runGuarded delivers an unawaited future\'s crash before the process dies of it', () async {
    final result = await _runChild('async');

    expect(result.messages, ['Bad state: async crash']);
    expect(result.exitCode, unhandledExceptionExitCode);
    expect(result.stderr, contains('async crash'));
  });

  test('await flush() before exit() delivers what was just reported', () async {
    final result = await _runChild('exit');

    expect(result.messages, ['Bad state: reported, then exit']);
    expect(result.exitCode, 3);
  });

  test('flush gives up once its timeout passes when ForgeOps never answers', () async {
    final result = await _runChild('flush-timeout', hang: true);

    expect(result.exitCode, 0);
    final [delivered, elapsedMs] = result.stdout.trim().split(' ');
    expect(delivered, 'false');
    expect(int.parse(elapsedMs), inInclusiveRange(150, 1500));
  });

  const dsn = 'http://key@localhost:{port}/api/v1/events';

  test('with only FORGE_OPS_DSN set, an error is delivered: the environment defaults to production', () async {
    final result = await _runChild('dsn-only', environment: {'FORGE_OPS_DSN': dsn});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.messages, ['Bad state: sent from dsn-only']);
    expect(result.stderr, isNot(contains('Not sending')));
  });

  test('an explicit development environment sends nothing and warns exactly once', () async {
    final result =
        await _runChild('development', environment: {'FORGE_OPS_DSN': dsn, 'FORGE_OPS_ENVIRONMENT': 'development'});

    expect(result.exitCode, 0, reason: result.stderr);
    expect(result.messages, isEmpty);
    expect('[ForgeOps] Not sending: this environment is "development"'.allMatches(result.stderr).length, 1,
        reason: result.stderr);
    expect(result.stderr, contains('only production, staging are enabled. Set FORGE_OPS_ENVIRONMENT=production'));
  });

  test('a runGuarded crash still ends the process within a few seconds when ForgeOps never answers', () async {
    final result = await _runChild('sync', hang: true);

    expect(result.messages, ['Bad state: sync crash']);
    expect(result.exitCode, unhandledExceptionExitCode);
    expect(result.elapsed, lessThan(const Duration(seconds: 8)));
  });
}
