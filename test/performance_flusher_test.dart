import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('PerformanceFlusher', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind('localhost', 0);
    });

    tearDown(() async {
      await server.close(force: true);
    });

    Configuration configurationFor(int port, {void Function(Configuration)? configure}) {
      final config = Configuration()
        ..dsn = 'http://key@localhost:$port/api/v1/events'
        ..environment = 'production'
        ..performanceFlushInterval = const Duration(hours: 1); // tests flush by hand
      configure?.call(config);
      return config;
    }

    // Answers every request with [status], recording each body and the path it arrived on.
    List<({String path, String body})> serve({int status = 202, Completer<void>? gate, Completer<void>? received}) {
      final requests = <({String path, String body})>[];
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add((path: request.uri.path, body: body));
        if (received != null && !received.isCompleted) received.complete();
        if (gate != null) await gate.future;
        request.response.statusCode = status;
        await request.response.close();
      });
      return requests;
    }

    test('buckets by transaction name with count, sum, and max', () {
      final flusher = PerformanceFlusher(configurationFor(1));

      flusher.record('GET /users/:id', 10);
      flusher.record('GET /users/:id', 30);
      flusher.record('POST /orders', 5);

      expect(flusher.tallies['GET /users/:id'], (2, 40.0, 30.0));
      expect(flusher.tallies['POST /orders'], (1, 5.0, 5.0));
    });

    test('record does nothing when trackPerformance is off', () {
      final flusher = PerformanceFlusher(configurationFor(1, configure: (c) => c.trackPerformance = false));

      flusher.record('GET /x', 10);

      expect(flusher.tallies, isEmpty);
    });

    test('record does nothing when reporting is not enabled for this environment', () {
      final flusher = PerformanceFlusher(configurationFor(1, configure: (c) => c.environment = 'development'));

      flusher.record('GET /x', 10);

      expect(flusher.tallies, isEmpty);
    });

    test('flush delivers one batch to performance_samples and empties the buckets', () async {
      final requests = serve();
      final flusher = PerformanceFlusher(configurationFor(server.port, configure: (c) => c.release = 'a1b2c3d'));
      flusher.record('GET /users/:id', 10);
      flusher.record('GET /users/:id', 30);

      await flusher.flush();

      expect(requests, hasLength(1));
      expect(requests.single.path, '/api/v1/performance_samples');
      final body = jsonDecode(requests.single.body) as Map<String, Object?>;
      final sample = (body['samples']! as List).single as Map<String, Object?>;
      expect(sample['transaction_name'], 'GET /users/:id');
      expect(sample['request_count'], 2);
      expect(sample['duration_sum_ms'], 40);
      expect(sample['max_duration_ms'], 30);
      expect(sample['environment'], 'production');
      expect(sample['release'], 'a1b2c3d');
      expect(sample['period_started_at'], matches(RegExp(r'Z$')));
      expect(flusher.tallies, isEmpty);
    });

    test('flush does nothing when there is nothing to send', () async {
      final requests = serve();
      final flusher = PerformanceFlusher(configurationFor(server.port));

      await flusher.flush();

      expect(requests, isEmpty);
    });

    test('a failed delivery keeps every bucket so the next flush carries more', () async {
      var calls = 0;
      final bodies = <String>[];
      server.listen((request) async {
        bodies.add(await utf8.decoder.bind(request).join());
        request.response.statusCode = ++calls == 1 ? 500 : 202;
        await request.response.close();
      });
      final flusher = PerformanceFlusher(configurationFor(server.port));
      flusher.record('GET /x', 10);

      await flusher.flush();
      expect(flusher.tallies['GET /x'], (1, 10.0, 10.0));

      flusher.record('GET /x', 20);
      await flusher.flush();

      expect(bodies[1], contains('"request_count":2'));
      expect(flusher.tallies, isEmpty);
    });

    for (final status in [400, 401, 403, 413, 422]) {
      test('a batch the server rejects with a $status is dropped and never sent again', () async {
        final logs = <String>[];
        var calls = 0;
        final bodies = <String>[];
        server.listen((request) async {
          bodies.add(await utf8.decoder.bind(request).join());
          request.response.statusCode = ++calls == 1 ? status : 202;
          await request.response.close();
        });
        final flusher = PerformanceFlusher(configurationFor(server.port, configure: (c) => c.logger = logs.add));
        flusher.record('GET /x', 10);

        await flusher.flush();
        expect(flusher.tallies, isEmpty);
        await flusher.flush(); // nothing left: no second delivery
        expect(bodies, hasLength(1));

        flusher.record('GET /x', 20);
        await flusher.flush();

        expect(bodies[1], contains('"request_count":1'));
        expect(logs, ['[ForgeOpsTracker] dropping 1 performance sample(s): the server rejected them']);
      });
    }

    for (final statuses in [
      [500, 502, 503, 504, 500],
      [408, 429, 408, 429, 408],
    ]) {
      test('keeps the batch through four failed flushes ($statuses), and the fifth in a row drops it', () async {
        final logs = <String>[];
        var calls = 0;
        server.listen((request) async {
          await request.drain<void>();
          request.response.statusCode = statuses[calls++];
          await request.response.close();
        });
        final flusher = PerformanceFlusher(configurationFor(server.port, configure: (c) => c.logger = logs.add));
        flusher.record('GET /x', 10);

        for (var i = 0; i < 4; i++) {
          await flusher.flush();
        }
        expect(flusher.tallies['GET /x'], (1, 10.0, 10.0));
        expect(logs, isEmpty);

        await flusher.flush(); // the fifth: gives up on the batch
        expect(flusher.tallies, isEmpty);
        await flusher.flush(); // nothing left: no sixth delivery

        expect(calls, 5);
        expect(logs, ['[ForgeOpsTracker] dropping 1 performance sample(s): 5 flushes in a row failed']);
      });
    }

    test('a network failure keeps the batch, and a delivery in between resets the count of failed flushes', () async {
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.statusCode = 202;
        await request.response.close();
      });
      final probe = await ServerSocket.bind('localhost', 0);
      final closedPort = probe.port;
      await probe.close();
      final logs = <String>[];
      final config = configurationFor(closedPort, configure: (c) {
        c.timeout = const Duration(milliseconds: 300);
        c.logger = logs.add;
      });
      final flusher = PerformanceFlusher(config);
      flusher.record('GET /x', 10);

      for (var i = 0; i < 4; i++) {
        await flusher.flush(); // nothing is listening
      }
      expect(flusher.tallies['GET /x'], (1, 10.0, 10.0));

      config.dsn = 'http://key@localhost:${server.port}/api/v1/events';
      await flusher.flush();
      expect(calls, 1);
      expect(flusher.tallies, isEmpty);

      config.dsn = 'http://key@localhost:$closedPort/api/v1/events';
      flusher.record('GET /x', 20);
      for (var i = 0; i < 4; i++) {
        await flusher.flush();
      }

      // Four failures after the delivery are not five in a row: the tally is still held.
      expect(flusher.tallies['GET /x'], (1, 20.0, 20.0));
      expect(logs.where((line) => line.contains('dropping')), isEmpty);
    });

    test('after a failed flush, record waits a full interval before starting another', () async {
      var calls = 0;
      server.listen((request) async {
        await request.drain<void>();
        calls++;
        request.response.statusCode = 500;
        await request.response.close();
      });
      final flusher = PerformanceFlusher(
          configurationFor(server.port, configure: (c) => c.performanceFlushInterval = const Duration(milliseconds: 200)));
      await Future<void>.delayed(const Duration(milliseconds: 250));

      flusher.record('GET /x', 10); // a full interval has passed: starts a flush, which fails
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 1);
      for (var i = 0; i < 10; i++) {
        flusher.record('GET /x', 10);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(calls, 1);
      expect(flusher.tallies['GET /x']!.$1, 11);
    });

    test('a record that lands during delivery is never lost', () async {
      // Deterministic reproduction of the race flush()'s own comment describes: the server holds
      // its response until this test has recorded again, guaranteeing record() runs strictly
      // between the snapshot and delivery succeeding.
      final gate = Completer<void>();
      final received = Completer<void>();
      serve(gate: gate, received: received);
      final flusher = PerformanceFlusher(configurationFor(server.port));
      flusher.record('GET /x', 10);

      final flushing = flusher.flush();
      await received.future;

      flusher.record('GET /x', 25); // same transaction, mid-delivery
      flusher.record('GET /new', 7); // a brand-new one, mid-delivery
      gate.complete();
      await flushing;

      expect(flusher.tallies['GET /x'], (1, 25.0, 25.0));
      expect(flusher.tallies['GET /new'], (1, 7.0, 7.0));
    });

    test('a second flush while one is in flight does nothing rather than delivering the same snapshot twice', () async {
      final gate = Completer<void>();
      final received = Completer<void>();
      final requests = serve(gate: gate, received: received);
      final flusher = PerformanceFlusher(configurationFor(server.port));
      flusher.record('GET /x', 10);

      final first = flusher.flush();
      await received.future;
      await flusher.flush(); // returns immediately: the first is still awaiting the server
      gate.complete();
      await first;

      expect(requests, hasLength(1));
    });

    test('delivers a latency histogram per bucket alongside count, sum, and max', () async {
      final requests = serve();
      final flusher = PerformanceFlusher(configurationFor(server.port));
      for (final duration in [10.0, 40.0, 120.0, 700.0, 12000.0]) {
        flusher.record('GET /posts', duration);
      }

      await flusher.flush();

      final sample = (jsonDecode(requests.single.body)['samples'] as List).single as Map<String, dynamic>;
      expect(sample['histogram'], {'50': 2, '250': 1, '1000': 1, 'inf': 1});
      expect((sample['histogram'] as Map).values.reduce((a, b) => (a as int) + (b as int)), sample['request_count']);
    });

    test('keeps histogram counts for the next flush when delivery fails', () async {
      final bodies = <String>[];
      var calls = 0;
      server.listen((request) async {
        bodies.add(await utf8.decoder.bind(request).join());
        request.response.statusCode = ++calls == 1 ? 500 : 202;
        await request.response.close();
      });
      final flusher = PerformanceFlusher(configurationFor(server.port));
      flusher.record('GET /posts', 10);
      await flusher.flush(); // the first delivery fails: the histogram must survive it

      flusher.record('GET /posts', 300);
      await flusher.flush();

      final sample = (jsonDecode(bodies[1])['samples'] as List).single as Map<String, dynamic>;
      expect(sample['histogram'], {'50': 1, '500': 1});
    });

    test('a histogram count recorded during delivery is sent on the next flush, not lost', () async {
      final gate = Completer<void>();
      final received = Completer<void>();
      final requests = serve(gate: gate, received: received);
      final flusher = PerformanceFlusher(configurationFor(server.port));
      flusher.record('GET /posts', 10);

      final flushing = flusher.flush();
      await received.future;
      flusher.record('GET /posts', 300); // same transaction, mid-delivery
      flusher.record('GET /new', 5); // a brand-new one, mid-delivery
      gate.complete();
      await flushing;
      await flusher.flush();

      final first = (jsonDecode(requests[0].body)['samples'] as List).single as Map<String, dynamic>;
      expect(first['histogram'], {'50': 1});
      final second = {
        for (final s in (jsonDecode(requests[1].body)['samples'] as List)) (s as Map)['transaction_name']: s,
      };
      expect((second['GET /posts'] as Map)['histogram'], {'500': 1});
      expect((second['GET /new'] as Map)['histogram'], {'50': 1});
    });

    test('record itself starts a flush once a full interval has elapsed, with no timer involved', () async {
      final requests = serve();
      final flusher = PerformanceFlusher(
          configurationFor(server.port, configure: (c) => c.performanceFlushInterval = Duration.zero));

      flusher.record('GET /x', 10);
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(requests, hasLength(1));
      expect(requests.single.body, contains('"transaction_name":"GET /x"'));
    });
  });
}
