import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;
import 'package:forge_ops_tracker/src/metric_buffer.dart';
import 'package:test/test.dart';

void main() {
  group('custom metrics and infrastructure monitoring', () {
    fot.Configuration configuration() => fot.Configuration()
      ..dsn = 'https://key@tracker.example.com/api/v1/events'
      ..environment = 'production'
      ..release = 'a1b2c3d'
      ..serverName = 'web-1';

    MetricBuffer buffer(Future<fot.DeliveryStatus> Function(List<Map<String, Object?>>) deliver,
            {Duration interval = const Duration(hours: 1), List<String>? logs}) =>
        MetricBuffer(configuration()..logger = logs?.add, deliver, () => interval);

    List<String> names(List<Map<String, Object?>> entries) => [for (final e in entries) e['metric_name'] as String];

    test('delivers every entry as one batch, stamped with recorded_at', () async {
      final delivered = <List<Map<String, Object?>>>[];
      final b = buffer((entries) async {
        delivered.add(entries);
        return fot.DeliveryStatus.delivered;
      });

      expect(b.record({'metric_name': 'signup', 'value': 1.0}), isTrue);
      expect(b.record({'metric_name': 'refund', 'value': -12.5}), isTrue);
      await b.flush();

      expect(delivered, hasLength(1));
      expect(names(delivered.single), ['signup', 'refund']);
      expect(delivered.single[1]['value'], -12.5);
      expect(delivered.single[0]['recorded_at'], matches(RegExp(r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')));
      expect(b.length, 0);
    });

    test('drops NaN, infinite and non-numeric values so one bad entry cannot poison a batch', () {
      final b = buffer((entries) async => fot.DeliveryStatus.delivered);
      expect(b.record({'metric_name': 'nan', 'value': double.nan}), isFalse);
      expect(b.record({'metric_name': 'inf', 'value': double.infinity}), isFalse);
      expect(b.record({'metric_name': 'str', 'value': '12'}), isFalse);
      expect(b.record({'metric_name': 'ok', 'value': 3}), isTrue);
    });

    test('a failed delivery keeps every entry for the next flush', () async {
      var calls = 0;
      final delivered = <List<String>>[];
      final b = buffer((entries) async {
        delivered.add(names(entries));
        return ++calls > 1 ? fot.DeliveryStatus.delivered : fot.DeliveryStatus.failed;
      });

      b.record({'metric_name': 'a', 'value': 1});
      await b.flush();
      b.record({'metric_name': 'b', 'value': 2});
      await b.flush();
      await b.flush(); // nothing left: no third delivery

      expect(delivered, [
        ['a'],
        ['a', 'b'],
      ]);
    });

    test('an entry recorded while delivery is in flight is never lost', () async {
      final gate = Completer<void>();
      final inFlight = Completer<void>();
      final delivered = <List<String>>[];
      final b = buffer((entries) async {
        delivered.add(names(entries));
        if (delivered.length == 1) {
          inFlight.complete();
          await gate.future;
        }
        return fot.DeliveryStatus.delivered;
      });

      b.record({'metric_name': 'first', 'value': 1});
      final flushing = b.flush();
      await inFlight.future;
      b.record({'metric_name': 'during', 'value': 2});
      gate.complete();
      await flushing;
      await b.flush();

      expect(delivered, [
        ['first'],
        ['during'],
      ]);
    });

    test('the buffer is capped and drops further entries until a flush succeeds', () {
      final b = buffer((entries) async => fot.DeliveryStatus.failed);
      var accepted = 0;
      for (var i = 0; i < MetricBuffer.maxEntries + 50; i++) {
        if (b.record({'metric_name': 'm', 'value': 1})) accepted++;
      }
      expect(accepted, MetricBuffer.maxEntries);
    });

    test('a batch the server rejects is dropped and never sent again', () async {
      final logs = <String>[];
      final delivered = <List<String>>[];
      final b = buffer((entries) async {
        delivered.add(names(entries));
        return fot.DeliveryStatus.rejected;
      }, logs: logs);

      b.record({'metric_name': 'a', 'value': 1});
      await b.flush();
      expect(b.length, 0);
      await b.flush(); // nothing left: no second delivery
      b.record({'metric_name': 'b', 'value': 2});
      await b.flush();

      expect(delivered, [
        ['a'],
        ['b'],
      ]);
      expect(logs, List.filled(2, '[ForgeOpsTracker] dropping 1 metric(s): the server rejected them'));
    });

    test('a rejected batch frees a full buffer for new metrics', () async {
      final b = buffer((entries) async => fot.DeliveryStatus.rejected);
      for (var i = 0; i < MetricBuffer.maxEntries; i++) {
        b.record({'metric_name': 'm', 'value': 1});
      }
      expect(b.record({'metric_name': 'm', 'value': 1}), isFalse);

      await b.flush();

      expect(b.length, 0);
      expect(b.record({'metric_name': 'm', 'value': 1}), isTrue);
    });

    test('the fifth failed flush in a row drops the batch and starts clean', () async {
      final logs = <String>[];
      final delivered = <List<String>>[];
      final b = buffer((entries) async {
        delivered.add(names(entries));
        return fot.DeliveryStatus.failed;
      }, logs: logs);

      b.record({'metric_name': 'a', 'value': 1});
      for (var i = 0; i < 4; i++) {
        await b.flush();
      }
      expect(b.length, 1);
      expect(logs, isEmpty);
      await b.flush(); // the fifth: gives up on the batch
      await b.flush(); // nothing left: no sixth delivery

      expect(delivered, hasLength(5));
      expect(b.length, 0);
      expect(logs, ['[ForgeOpsTracker] dropping 1 metric(s): 5 flushes in a row failed']);

      // Clean again: the next batch gets its own five tries.
      b.record({'metric_name': 'b', 'value': 2});
      await b.flush();
      await b.flush();
      expect(b.length, 1);
    });

    test('a delivery in between resets the count of failed flushes', () async {
      var calls = 0;
      final b = buffer(
          (entries) async => ++calls == 5 ? fot.DeliveryStatus.delivered : fot.DeliveryStatus.failed);

      b.record({'metric_name': 'a', 'value': 1});
      for (var i = 0; i < 5; i++) {
        await b.flush();
      }
      expect(b.length, 0);
      b.record({'metric_name': 'b', 'value': 2});
      for (var i = 0; i < 4; i++) {
        await b.flush();
      }

      // Four failures after the delivery are not five in a row: 'b' is still held.
      expect(b.length, 1);
    });

    test('a capture starts a flush itself once a full interval has elapsed, with no timer involved', () async {
      final delivered = Completer<List<Map<String, Object?>>>();
      final b = buffer((entries) async {
        delivered.complete(entries);
        return fot.DeliveryStatus.delivered;
      }, interval: Duration.zero);

      b.record({'metric_name': 'tick', 'value': 1});

      expect(names(await delivered.future.timeout(const Duration(seconds: 3))), ['tick']);
    });

    group('through the public API', () {
      late HttpServer server;
      late List<({String path, String? auth, Map<String, Object?> body})> requests;

      setUp(() async {
        fot.resetForTesting();
        requests = [];
        server = await HttpServer.bind('localhost', 0);
        server.listen((request) async {
          final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>;
          requests.add((
            path: request.uri.path,
            auth: request.headers.value(HttpHeaders.authorizationHeader),
            body: body,
          ));
          request.response.statusCode = 202;
          await request.response.close();
        });
      });

      tearDown(() async {
        await server.close(force: true);
        fot.resetForTesting();
      });

      test('captureMetric and captureInfrastructureMetric deliver to their own endpoints', () async {
        fot.init((c) {
          c.dsn = 'http://key@localhost:${server.port}/api/v1/events';
          c.environment = 'production';
          c.release = 'a1b2c3d';
          c.serverName = 'web-1';
        });

        fot.captureMetric('signup');
        fot.captureMetric('payment', 49);
        fot.captureInfrastructureMetric('cpu', 0.42, hostname: 'db-1');
        fot.captureInfrastructureMetric('memory', 0.7);
        await fot.flushMetrics();

        final byPath = {for (final r in requests) r.path: r};
        final custom = (byPath['/api/v1/custom_metrics']!.body['metrics'] as List).cast<Map<String, Object?>>();
        expect(byPath['/api/v1/custom_metrics']!.auth, 'Bearer key');
        expect(names(custom), ['signup', 'payment']);
        expect(custom[0]['value'], 1);
        expect(custom[1]['value'], 49);
        expect(custom[0]['environment'], 'production');
        expect(custom[0]['release'], 'a1b2c3d');
        final infrastructure =
            (byPath['/api/v1/infrastructure_metrics']!.body['metrics'] as List).cast<Map<String, Object?>>();
        expect(infrastructure[0]['hostname'], 'db-1');
        expect(infrastructure[1]['hostname'], 'web-1');
      });

      test('captures are a no-op when reporting is not enabled, and flushMetrics without a capture is safe', () async {
        await fot.flushMetrics(); // no buffers yet
        fot.init((c) {
          c.dsn = 'http://key@localhost:${server.port}/api/v1/events';
          c.environment = 'development';
        });
        fot.captureMetric('signup');
        fot.captureInfrastructureMetric('cpu', 1);
        await fot.flushMetrics();

        expect(requests, isEmpty);
      });
    });

    test('the metric uris swap the trailing events segment', () {
      final config = configuration();
      expect(config.customMetricsUri.toString(), 'https://tracker.example.com/api/v1/custom_metrics');
      expect(config.infrastructureMetricsUri.toString(), 'https://tracker.example.com/api/v1/infrastructure_metrics');
    });
  });
}
