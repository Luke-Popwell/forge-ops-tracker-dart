import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('Reporter', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    test('report does nothing when disabled', () async {
      var received = 0;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        received++;
        await request.response.close();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..environment = 'development'; // not in enabledEnvironments
      final reporter = Reporter(config);

      reporter.report(Exception('boom'), StackTrace.current);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, 0);
    });

    test('report does nothing for a null error', () async {
      var received = 0;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        received++;
        await request.response.close();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..environment = 'production';
      final reporter = Reporter(config);

      reporter.report(null, null);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(received, 0);
    });

    test('report delivers when enabled', () async {
      final done = Completer<void>();
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..environment = 'production';
      final reporter = Reporter(config);

      reporter.report(Exception('boom'), StackTrace.current);

      await done.future.timeout(const Duration(seconds: 2));
    });

    test('report includes the given user, never scrubbed even though it is an email', () async {
      final done = Completer<void>();
      String? body;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..environment = 'production';
      final reporter = Reporter(config);

      reporter.report(Exception('boom'), StackTrace.current, user: {'id': 42, 'email': 'alice@example.com'});

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, contains('alice@example.com'));
    });

    test('report includes the given breadcrumbs in the delivered payload', () async {
      final done = Completer<void>();
      String? body;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        body = await utf8.decoder.bind(request).join();
        request.response.statusCode = 202;
        await request.response.close();
        done.complete();
      });

      final config = Configuration()
        ..dsn = 'http://key@localhost:${server.port}/api/v1/events'
        ..environment = 'production';
      final reporter = Reporter(config);
      final crumb = {
        'category': 'controller',
        'message': 'GET /orders/42',
        'level': 'info',
        'timestamp': '2024-01-15T10:29:58Z',
        'data': <String, Object?>{},
      };

      reporter.report(Exception('boom'), StackTrace.current, breadcrumbs: [crumb]);

      await done.future.timeout(const Duration(seconds: 2));
      expect(body, contains('GET /orders/42'));
    });

    test('report never throws even when delivery fails', () async {
      server = await HttpServer.bind('localhost', 0); // unused, just so tearDown has something to close
      final config = Configuration()
        ..dsn = 'http://key@localhost:1/api/v1/events' // nothing listening
        ..environment = 'production';
      final reporter = Reporter(config);

      // Must not throw: an error reporter that can crash the host app while reporting is the
      // worst possible failure mode.
      reporter.report(Exception('boom'), StackTrace.current);
    });
  });
}
