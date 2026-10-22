import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;
import 'package:test/test.dart';

void main() {
  group('public API', () {
    late HttpServer server;

    setUp(() async {
      fot.resetForTesting();
      server =
          await HttpServer.bind('localhost', 0); // not every test below uses this, but tearDown always has one to close
    });

    tearDown(() async {
      await server.close(force: true);
      fot.resetForTesting();
    });

    test('init configures and returns the shared configuration', () {
      final config = fot.init((c) {
        c.dsn = 'https://key@tracker.example.com/api/v1/events';
        c.release = 'abc123';
      });

      expect(config.dsn, 'https://key@tracker.example.com/api/v1/events');
      expect(config.release, 'abc123');
      expect(fot.configuration(), same(config));
    });

    test('init warns once, through the logger, when a DSN is set but the environment is not enabled', () {
      final warnings = <String>[];
      void configure(fot.Configuration c) {
        c.dsn = 'https://key@tracker.example.com/api/v1/events';
        c.environment = 'development';
        c.logger = warnings.add;
      }

      fot.init(configure);
      fot.init(configure);

      expect(warnings, hasLength(1));
      expect(warnings.single, startsWith('[ForgeOps] Not sending: this environment is "development"'));
    });

    test('init does not warn without a DSN, or in an enabled environment', () {
      final warnings = <String>[];
      fot.init((c) {
        c.dsn = null;
        c.environment = 'development';
        c.logger = warnings.add;
      });
      fot.init((c) {
        c.dsn = 'https://key@tracker.example.com/api/v1/events';
        c.environment = 'production';
      });

      expect(warnings, isEmpty);
    });

    test('captureException delivers through the full stack', () async {
      final done = Completer<void>();
      String? authHeader;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        authHeader = request.headers.value(HttpHeaders.authorizationHeader);
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      try {
        throw Exception('boom');
      } catch (error, stackTrace) {
        fot.captureException(error, stackTrace);
      }

      await done.future.timeout(const Duration(seconds: 2));
      expect(authHeader, 'Bearer key');
    });

    test('runGuarded reports an escaping synchronous error, then rethrows it unchanged once delivered', () async {
      final done = Completer<void>();
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        done.complete();
        request.response.statusCode = 202;
        await request.response.close();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      // The rethrow lands in the zone runGuarded was called from, after delivery: an outer guarded
      // zone here stands in for the root zone, where it would crash the isolate (see
      // test/exit_test.dart for that, for real).
      final thrown = Exception('guarded boom');
      final rethrown = Completer<Object>();
      runZonedGuarded(() => fot.runGuarded(() => throw thrown), (error, _) => rethrown.complete(error));

      final error = await rethrown.future.timeout(const Duration(seconds: 2));
      expect(identical(error, thrown), isTrue);
      expect(done.isCompleted, isTrue, reason: 'delivered before the rethrow');
    });

    test('flush completes true right away when nothing was reported', () async {
      expect(await fot.flush(timeout: const Duration(milliseconds: 10)), isTrue);
    });

    test('flush completes true once a reported error has been delivered', () async {
      var received = 0;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        received++;
        request.response.statusCode = 202;
        await request.response.close();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      fot.captureException(Exception('boom'));
      fot.recordChange('config', 'Raised the pool size');

      expect(await fot.flush(), isTrue);
      expect(received, 2);
    });

    test('flush completes false once its timeout passes when ForgeOps never answers', () async {
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) {}); // never answers

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
        config.timeout = const Duration(seconds: 5);
      });

      fot.captureException(Exception('never answered'));

      final stopwatch = Stopwatch()..start();
      expect(await fot.flush(timeout: const Duration(milliseconds: 200)), isFalse);
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
    });

    test('resetForTesting discards configured state', () {
      fot.init((config) => config.dsn = 'https://key@tracker.example.com/events');
      fot.resetForTesting();

      expect(fot.configuration().dsn, isNull);
    });

    test('setUser attaches the user to a later captureException call', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      fot.setUser({'id': 42, 'email': 'alice@example.com'});
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, contains('alice@example.com'));
    });

    test('an explicit user argument overrides whatever setUser last set', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      fot.setUser({'id': 42});
      fot.captureException(Exception('boom'), StackTrace.current, null, {'id': 99});

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, contains('"id":99'));
    });

    test('resetForTesting clears the global user set via setUser', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.setUser({'id': 42});
      fot.resetForTesting();

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, isNot(contains('"user"')));
    });

    test('runWithUser scopes the user to its own call chain, including across an await', () async {
      final requestBodies = <String>[];
      final allReceived = <Completer<void>>[Completer<void>(), Completer<void>()];
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      var received = 0;
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requestBodies.add(body);
        request.response.statusCode = 202;
        await request.response.close();
        allReceived[received].complete();
        received++;
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      await fot.runWithUser({'id': 'scoped-user'}, () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        fot.captureException(Exception('boom inside runWithUser'));
      });
      // Outside runWithUser entirely: no ambient user, and specifically not the one the call
      // above set, proving the scoping is real and not a leftover global.
      fot.captureException(Exception('boom outside runWithUser'));

      await Future.wait([allReceived[0].future, allReceived[1].future]).timeout(const Duration(seconds: 2));
      expect(requestBodies[0], contains('scoped-user'));
      expect(requestBodies[1], isNot(contains('scoped-user')));
    });

    test('addBreadcrumb attaches the trail to a later captureException call', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      fot.addBreadcrumb('charging card', category: 'payment', data: {'order_id': 42});
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, contains('charging card'));
      expect(body, contains('"category":"payment"'));
    });

    test('addBreadcrumb does nothing when trackBreadcrumbs is disabled', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
        config.trackBreadcrumbs = false;
      });

      fot.addBreadcrumb('should not be recorded');
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, isNot(contains('breadcrumbs')));
    });

    test('clearBreadcrumbs empties the trail', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      fot.addBreadcrumb('first');
      fot.clearBreadcrumbs();
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, isNot(contains('breadcrumbs')));
    });

    test('addBreadcrumb caps the trail at maxBreadcrumbs, dropping the oldest first', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
        config.maxBreadcrumbs = 2;
      });

      fot.addBreadcrumb('first');
      fot.addBreadcrumb('second');
      fot.addBreadcrumb('third');
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, isNot(contains('"message":"first"')));
      expect(body, contains('"message":"second"'));
      expect(body, contains('"message":"third"'));
    });

    test('resetForTesting clears the global breadcrumb trail', () async {
      final done = Completer<void>();
      String? body;
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      fot.addBreadcrumb('leftover from a previous test');
      fot.resetForTesting();

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });
      fot.captureException(Exception('boom'));

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, isNot(contains('breadcrumbs')));
    });

    test('runWithBreadcrumbs scopes the trail to its own call chain, including across an await', () async {
      final requestBodies = <String>[];
      final allReceived = <Completer<void>>[Completer<void>(), Completer<void>()];
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      var received = 0;
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requestBodies.add(body);
        request.response.statusCode = 202;
        await request.response.close();
        allReceived[received].complete();
        received++;
      });

      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
      });

      await fot.runWithBreadcrumbs(() async {
        fot.addBreadcrumb('inside the scope');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        fot.captureException(Exception('boom inside runWithBreadcrumbs'));
      });
      // Outside runWithBreadcrumbs entirely: no breadcrumb ever recorded there, and specifically
      // not the one the call above added, proving the scoping is real and not a leftover global.
      fot.captureException(Exception('boom outside runWithBreadcrumbs'));

      await Future.wait([allReceived[0].future, allReceived[1].future]).timeout(const Duration(seconds: 2));
      expect(requestBodies[0], contains('inside the scope'));
      expect(requestBodies[1], isNot(contains('breadcrumbs')));
    });

    Future<List<String>> initAgainstSamplesServer({void Function(fot.Configuration)? configure}) async {
      final bodies = <String>[];
      await server.close(force: true);
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        bodies.add(await utf8.decoder.bind(request).join());
        request.response.statusCode = 202;
        await request.response.close();
      });
      fot.init((config) {
        config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        config.environment = 'production';
        config.performanceFlushInterval = const Duration(hours: 1); // flushed by hand below
        configure?.call(config);
      });
      return bodies;
    }

    test('recordPerformance tallies in-process and flushPerformance delivers one aggregate batch', () async {
      final bodies = await initAgainstSamplesServer();

      fot.recordPerformance('GET /users/:id', 10);
      fot.recordPerformance('GET /users/:id', 30);
      await fot.flushPerformance();

      expect(bodies.single, contains('"transaction_name":"GET /users/:id"'));
      expect(bodies.single, contains('"request_count":2'));
    });

    test('timeTransaction returns the body\'s own value and records how long it took', () async {
      final bodies = await initAgainstSamplesServer();

      final value = fot.timeTransaction('timed', () => 42);
      await fot.flushPerformance();

      expect(value, 42);
      expect(bodies.single, contains('"transaction_name":"timed"'));
    });

    test('timeTransaction records even when the body throws, and rethrows it unchanged', () async {
      final bodies = await initAgainstSamplesServer();

      expect(() => fot.timeTransaction<void>('timed throws', () => throw StateError('inside')), throwsStateError);
      await fot.flushPerformance();

      expect(bodies.single, contains('"transaction_name":"timed throws"'));
    });

    test('timeTransactionAsync times until the future completes, even if it fails', () async {
      final bodies = await initAgainstSamplesServer();

      final value = await fot.timeTransactionAsync('slow', () async {
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return 'done';
      });
      await expectLater(
          fot.timeTransactionAsync<void>('slow fails', () async => throw StateError('later')), throwsStateError);
      await fot.flushPerformance();

      expect(value, 'done');
      final body = jsonDecode(bodies.single) as Map<String, Object?>;
      final samples = {for (final s in body['samples']! as List) (s as Map)['transaction_name']: s};
      expect((samples['slow']!['duration_sum_ms'] as num) >= 50, isTrue,
          reason: 'timed across the await, not just the call');
      expect(samples, contains('slow fails'));
    });

    test('trackPerformance off records and delivers nothing', () async {
      final bodies = await initAgainstSamplesServer(configure: (c) => c.trackPerformance = false);

      fot.recordPerformance('never recorded', 10);
      await fot.flushPerformance();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(bodies, isEmpty);
    });
  });
}
