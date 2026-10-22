import 'dart:async';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('DeliveryQueue', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('push delivers in the background', () async {
      var received = 0;
      final done = Completer<void>();
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        received++;
        request.response.statusCode = 202;
        await request.response.close();
        if (received >= 2) done.complete();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..queueSize = 10;
      final queue = DeliveryQueue(config);

      queue.push({'n': 1});
      queue.push({'n': 2});

      await done.future.timeout(const Duration(seconds: 2));
      expect(received, 2);
    });

    test('drops when full', () async {
      // A handler that blocks until released, so the drain loop stays busy on the first delivery
      // long enough for the queue behind it to actually fill up.
      final release = Completer<void>();
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        await release.future;
        request.response.statusCode = 202;
        await request.response.close();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..queueSize = 1;
      final queue = DeliveryQueue(config);

      expect(queue.push({'n': 1}), isTrue, reason: 'first push should have succeeded');
      await Future<void>.delayed(const Duration(milliseconds: 200)); // let the drain loop pick it up and start blocking

      expect(queue.push({'n': 2}), isTrue, reason: 'second push should have filled the size-1 queue');
      expect(queue.push({'n': 3}), isFalse, reason: 'third push should have been dropped: queue was full');

      release.complete();
    });
  });
}
