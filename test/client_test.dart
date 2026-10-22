import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('Client', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('delivers successfully on a 2xx response and sends the authorization header', () async {
      String? receivedAuth;
      String? receivedBody;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        receivedAuth = request.headers.value(HttpHeaders.authorizationHeader);
        receivedBody = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
      });

      final config = Configuration()..dsn = 'http://the-api-key@localhost:${server.port}/api/v1/events';
      final client = Client(config);

      final delivered = await client.deliver({'message': 'boom'});

      expect(delivered, isTrue);
      expect(receivedAuth, 'Bearer the-api-key');
      expect(receivedBody, '{"message":"boom"}');
    });

    test('returns false on a non-2xx response', () async {
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        request.response.statusCode = 500;
        await request.response.close();
      });

      final config = Configuration()..dsn = 'http://key@localhost:${server.port}/api/v1/events';
      final client = Client(config);

      expect(await client.deliver({'message': 'boom'}), isFalse);
    });

    test('the send methods tell a rejection from a failure that may pass', () async {
      var status = 202;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        await request.drain<void>();
        request.response.statusCode = status;
        await request.response.close();
      });
      final config = Configuration()..dsn = 'http://key@localhost:${server.port}/api/v1/events';
      final client = Client(config);

      expect(await client.sendMetrics([]), DeliveryStatus.delivered);
      for (status in [400, 401, 403, 404, 413, 422]) {
        expect(await client.sendMetrics([]), DeliveryStatus.rejected, reason: 'status $status');
        expect(await client.sendPerformanceSamples([]), DeliveryStatus.rejected, reason: 'status $status');
        expect(await client.sendInfrastructureMetrics([]), DeliveryStatus.rejected, reason: 'status $status');
        expect(await client.deliverMetrics([]), isFalse, reason: 'status $status');
      }
      for (status in [408, 429, 500, 502, 503]) {
        expect(await client.sendMetrics([]), DeliveryStatus.failed, reason: 'status $status');
        expect(await client.deliverMetrics([]), isFalse, reason: 'status $status');
      }
    });

    test('the send methods answer failed rather than throwing when nothing is listening', () async {
      final probe = await ServerSocket.bind('localhost', 0);
      final closedPort = probe.port;
      await probe.close();
      server = await HttpServer.bind('localhost', 0); // unused, just so tearDown has something to close

      final config = Configuration()
        ..dsn = 'http://key@localhost:$closedPort/api/v1/events'
        ..timeout = const Duration(milliseconds: 300);

      expect(await Client(config).sendPerformanceSamples([]), DeliveryStatus.failed);
    });

    test('returns false when there is no ingestion uri', () async {
      server = await HttpServer.bind('localhost', 0); // unused, just so tearDown has something to close
      final config = Configuration()..dsn = null;
      final client = Client(config);

      expect(await client.deliver({'message': 'boom'}), isFalse);
    });

    test('returns false rather than throwing when nothing is listening', () async {
      final probe = await ServerSocket.bind('localhost', 0);
      final closedPort = probe.port;
      await probe.close();
      server = await HttpServer.bind('localhost', 0); // unused, just so tearDown has something to close

      final config = Configuration()
        ..dsn = 'http://key@localhost:$closedPort/api/v1/events'
        ..timeout = const Duration(milliseconds: 300);
      final client = Client(config);

      expect(await client.deliver({'message': 'boom'}), isFalse);
    });
  });
}
