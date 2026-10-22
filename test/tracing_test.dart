import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;
import 'package:forge_ops_tracker/src/span_buffer.dart';
import 'package:test/test.dart';

void main() {
  group('distributed tracing', () {
    late HttpServer server;
    late List<HttpRequest> requests;
    late List<Map<String, Object?>> bodies;

    setUp(() async {
      fot.resetForTesting();
      requests = [];
      bodies = [];
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add(request);
        bodies.add(jsonDecode(body) as Map<String, Object?>);
        request.response.statusCode = 202;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      fot.resetForTesting();
    });

    void configure(
        {bool tracing = true,
        Duration threshold = const Duration(milliseconds: 10),
        String environment = 'production'}) {
      fot.init((c) {
        c.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        c.environment = environment;
        c.release = 'a1b2c3d';
        c.trackTracing = tracing;
        c.traceCaptureThreshold = threshold;
      });
    }

    Map<String, Object?> span(Map<String, Object?> trace, String name) =>
        (trace['spans'] as List).cast<Map<String, Object?>>().firstWhere((s) => s['name'] == name);

    test('a slow trace is delivered to spans with nested spans and the wire shape', () async {
      configure();

      await fot.traceAsync('GET /checkout', () async {
        await fot.spanAsync('charge', () async {
          fot.recordSpan('SELECT users',
              kind: 'database', startedAt: DateTime.utc(2023, 11, 14, 22, 13, 20, 123), durationMs: 3);
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }, data: {'order': 42});
        fot.recordSpan('sibling', kind: 'database', startedAt: DateTime.now(), durationMs: 1);
      });
      await fot.flushSpans();

      expect(requests.single.uri.path, '/api/v1/spans');
      final trace = bodies.single;
      expect(trace['trace_id'], matches(RegExp(r'^[0-9a-f]{32}$')));
      final root = span(trace, 'GET /checkout');
      final charge = span(trace, 'charge');
      expect(root['parent_span_id'], isNull);
      expect(root['kind'], 'controller');
      expect(root['span_id'], matches(RegExp(r'^[0-9a-f]{16}$')));
      expect(charge['parent_span_id'], root['span_id']);
      expect(span(trace, 'SELECT users')['parent_span_id'], charge['span_id']);
      expect(span(trace, 'sibling')['parent_span_id'], root['span_id']);
      expect(span(trace, 'SELECT users')['started_at'], '2023-11-14T22:13:20.123Z');
      expect(charge['environment'], 'production');
      expect(charge['release'], 'a1b2c3d');
      expect(charge['data'], {'order': 42});
    });

    test('an unknown kind is sent as other since the server would reject the whole trace', () async {
      configure();

      await fot.traceAsync('t', () async {
        fot.recordSpan('q', kind: 'db', startedAt: DateTime.now(), durationMs: 1);
        fot.recordSpan('r', kind: 'database', startedAt: DateTime.now(), durationMs: 1);
        await Future<void>.delayed(const Duration(milliseconds: 30));
      });
      await fot.flushSpans();

      expect(span(bodies.single, 'q')['kind'], 'other');
      expect(span(bodies.single, 'r')['kind'], 'database');
    });

    test('parallel futures inside one span each parent under it, and a later span goes back to the root', () async {
      configure();

      await fot.traceAsync('t', () async {
        await fot.spanAsync('outer', () async {
          await Future.wait([
            fot.spanAsync('a', () => Future<void>.delayed(const Duration(milliseconds: 20))),
            fot.spanAsync('b', () => Future<void>.delayed(const Duration(milliseconds: 5))),
          ]);
        });
        await fot.spanAsync('after', () => Future<void>.delayed(const Duration(milliseconds: 5)));
      });
      await fot.flushSpans();

      final trace = bodies.single;
      expect(span(trace, 'a')['parent_span_id'], span(trace, 'outer')['span_id']);
      expect(span(trace, 'b')['parent_span_id'], span(trace, 'outer')['span_id']);
      expect(span(trace, 'after')['parent_span_id'], span(trace, 't')['span_id']);
    });

    test('a body that throws still records its span, sends the trace and rethrows unchanged', () async {
      configure();

      await expectLater(
        fot.traceAsync(
            't',
            () => fot.spanAsync('bad', () async {
                  await Future<void>.delayed(const Duration(milliseconds: 30));
                  throw StateError('boom');
                })),
        throwsA(isA<StateError>()),
      );
      await fot.flushSpans();

      expect(span(bodies.single, 'bad')['name'], 'bad');
    });

    test('the synchronous forms return the body value and time it', () async {
      configure();

      final value = fot.trace('t', () {
        sleep(const Duration(milliseconds: 30));
        return fot.span('inner', () => 7);
      });
      await fot.flushSpans();

      expect(value, 7);
      expect(span(bodies.single, 'inner')['parent_span_id'], span(bodies.single, 't')['span_id']);
    });

    test('a fast trace sends nothing', () async {
      configure(threshold: const Duration(seconds: 60));

      await fot.traceAsync(
          'fast', () async => fot.recordSpan('q', kind: 'database', startedAt: DateTime.now(), durationMs: 1));
      await fot.flushSpans();

      expect(requests, isEmpty);
    });

    test('trackTracing off or reporting disabled records and sends nothing, and the body still runs', () async {
      configure(tracing: false);
      expect(
          await fot.traceAsync('x', () async {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            return 5;
          }),
          5);

      configure(environment: 'development');
      expect(fot.trace('x', () => 6), 6);
      await fot.flushSpans();

      expect(requests, isEmpty);
    });

    test('span and recordSpan outside a trace just run the body and record nothing', () async {
      configure();
      expect(fot.span('free', () => 7), 7);
      expect(await fot.spanAsync('free', () async => 8), 8);
      fot.recordSpan('free', startedAt: DateTime.now(), durationMs: 1);
      await fot.flushSpans();
      expect(requests, isEmpty);
    });

    test('a trace inside a trace records a span instead of starting a second trace', () async {
      configure();

      await fot.traceAsync('outer', () async {
        await fot.traceAsync('inner', () => Future<void>.delayed(const Duration(milliseconds: 30)));
      });
      await fot.flushSpans();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(requests.length, 1);
      expect(span(bodies.single, 'inner')['parent_span_id'], span(bodies.single, 'outer')['span_id']);
    });

    test('two concurrent traces stay apart', () async {
      configure();

      await Future.wait([
        fot.traceAsync(
            'one', () => fot.spanAsync('one child', () => Future<void>.delayed(const Duration(milliseconds: 30)))),
        fot.traceAsync(
            'two', () => fot.spanAsync('two child', () => Future<void>.delayed(const Duration(milliseconds: 30)))),
      ]);
      await fot.flushSpans();

      expect(bodies.length, 2);
      for (final body in bodies) {
        expect((body['spans'] as List).length, 2);
      }
    });

    test('a trace holds at most 500 spans including the root', () {
      final config = fot.Configuration()
        ..dsn = 'http://key@localhost:1/api/v1/events'
        ..traceCaptureThreshold = Duration.zero;
      final buffer = SpanBuffer(config);
      for (var i = 0; i < 700; i++) {
        buffer.record(
            spanId: 'id$i',
            parentSpanId: buffer.rootSpanId,
            name: 'q',
            kind: 'database',
            startedAt: DateTime.now(),
            durationMs: 1);
      }

      expect((buffer.finish('root', DateTime.now(), 5)!['spans'] as List).length, 500);
      expect(buffer.finish('root', DateTime.now(), 5), isNull, reason: 'finish is idempotent');
    });

    test('a database span sends its statement masked as db.statement, with db.system', () async {
      configure();

      await fot.traceAsync('t', () async {
        await fot.spanAsync('Load orders', () => Future<void>.delayed(const Duration(milliseconds: 30)),
            kind: 'database',
            data: {'rows': 3},
            statement: "SELECT * FROM orders WHERE email = 'a@b.co' AND total > 4200",
            dbSystem: 'SQLite');
        fot.span('Sync count', () => 1,
            kind: 'database', statement: "SELECT count(*) FROM carts WHERE id = 77", dbSystem: 'sqlite');
        fot.recordSpan('Count',
            kind: 'database',
            startedAt: DateTime.now(),
            durationMs: 1,
            data: {'db.statement': "SELECT count(*) FROM carts WHERE token = 'secret-token'"});
        fot.recordSpan('Not db',
            kind: 'service', startedAt: DateTime.now(), durationMs: 1, statement: "SELECT 'x'", dbSystem: 'sqlite');
      });
      await fot.flushSpans();

      final trace = bodies.single;
      expect(span(trace, 'Load orders')['data'], {
        'rows': 3,
        'db.statement': 'SELECT * FROM orders WHERE email = ? AND total > ?',
        'db.system': 'sqlite',
      });
      expect(span(trace, 'Sync count')['data'],
          {'db.statement': 'SELECT count(*) FROM carts WHERE id = ?', 'db.system': 'sqlite'});
      expect(span(trace, 'Count')['data'], {'db.statement': 'SELECT count(*) FROM carts WHERE token = ?'});
      expect(span(trace, 'Not db')['data'], <String, Object?>{});
      final wire = jsonEncode(trace);
      for (final secret in ['a@b.co', 'secret-token']) {
        expect(wire, isNot(contains(secret)));
      }
    });

    test('a MySQL or MariaDB database span masks "double quoted" values too, and no other does', () {
      expect(SpanBuffer.spanData('database', null, statement: 'SELECT id FROM t WHERE token = "abc123secret"', dbSystem: 'MySQL'),
          {'db.statement': 'SELECT id FROM t WHERE token = ?', 'db.system': 'mysql'});
      expect(
          SpanBuffer.spanData('database', {'db.system': 'mariadb', 'db.statement': 'SELECT id FROM t WHERE name = "jane"'}),
          {'db.statement': 'SELECT id FROM t WHERE name = ?', 'db.system': 'mariadb'});
      expect(SpanBuffer.spanData('database', null, statement: 'SELECT "user id" FROM t', dbSystem: 'postgresql'),
          {'db.statement': 'SELECT "user id" FROM t', 'db.system': 'postgresql'});
    });

    test('a database statement is cut at 4000 characters', () {
      final sql = 'SELECT ${'a, ' * 3000}b FROM t';
      final statement = SpanBuffer.spanData('database', null, statement: sql)!['db.statement'] as String;
      expect(statement.length, 4003);
      expect(statement, endsWith('...'));
    });

    test('spansUri swaps the trailing events segment', () {
      final config = fot.Configuration()..dsn = 'https://key@tracker.example.com/api/v1/events';
      expect(config.spansUri.toString(), 'https://tracker.example.com/api/v1/spans');
    });
  });
}
