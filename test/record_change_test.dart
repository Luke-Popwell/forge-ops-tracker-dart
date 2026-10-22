import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;
import 'package:test/test.dart';

void main() {
  group('recordChange', () {
    late HttpServer server;
    late List<({String path, String? auth, Map<String, Object?> body})> requests;
    var status = 202;

    setUp(() async {
      fot.resetForTesting();
      requests = [];
      status = 202;
      server = await HttpServer.bind('localhost', 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add((
          path: request.uri.path,
          auth: request.headers.value(HttpHeaders.authorizationHeader),
          body: jsonDecode(body) as Map<String, Object?>,
        ));
        request.response.statusCode = status;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      fot.resetForTesting();
    });

    void configure({String environment = 'production'}) {
      fot.init((c) {
        c.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        c.environment = environment;
      });
    }

    test('posts the change to /changes with the bearer key and the documented shape', () async {
      configure();

      fot.recordChange('feature_flag', 'Enabled new checkout',
          details: {'flag': 'new_checkout', 'to': true},
          service: 'mobile',
          actor: 'luke',
          url: 'https://example.com/flags/1',
          id: 'change-1',
          occurredAt: DateTime.utc(2026, 9, 25, 12, 0, 0));
      await fot.flushChanges();

      final request = requests.single;
      expect(request.path, '/api/v1/changes');
      expect(request.auth, 'Bearer key');
      expect(request.body, {
        'kind': 'feature_flag',
        'title': 'Enabled new checkout',
        'environment': 'production',
        'occurred_at': '2026-09-25T12:00:00.000Z',
        'details': {'flag': 'new_checkout', 'to': true},
        'service': 'mobile',
        'actor': 'luke',
        'url': 'https://example.com/flags/1',
        'id': 'change-1',
      });
    });

    test('defaults environment and occurred_at, and leaves unset optional keys out', () async {
      configure(environment: 'staging');

      fot.recordChange('config', 'Raised the upload limit');
      await fot.flushChanges();

      final body = requests.single.body;
      expect(body.keys, unorderedEquals(['kind', 'title', 'environment', 'occurred_at']));
      expect(body['environment'], 'staging');
      expect(DateTime.parse(body['occurred_at'] as String).isUtc, isTrue);
    });

    test('an unknown kind is sent as other, and every known kind is kept', () async {
      configure();

      fot.recordChange('deploy', 'Unknown kind');
      for (final kind in fot.changeKinds) {
        fot.recordChange(kind, 'Kind $kind');
      }
      await fot.flushChanges();

      expect(requests.first.body['kind'], 'other');
      expect([for (final r in requests.skip(1)) r.body['kind']], fot.changeKinds.toList());
    });

    test('a long title is cut to 200 characters and a blank one sends nothing', () async {
      configure();

      fot.recordChange('other', 'x' * 250);
      fot.recordChange('other', '   ');
      await fot.flushChanges();

      expect(requests, hasLength(1));
      expect(requests.single.body['title'], 'x' * 200);
    });

    test('is a no-op when reporting is not enabled', () async {
      configure(environment: 'development');

      fot.recordChange('config', 'Ignored');
      await fot.flushChanges();

      expect(requests, isEmpty);
    });

    test('never throws on a 403, a 500, or an unreachable host', () async {
      configure();
      status = 403;
      expect(() => fot.recordChange('config', 'Plan without change tracking'), returnsNormally);
      await fot.flushChanges();
      status = 500;
      expect(() => fot.recordChange('config', 'Server error'), returnsNormally);
      await fot.flushChanges();
      expect(requests, hasLength(2));

      final port = server.port;
      await server.close(force: true);
      fot.init((c) {
        c.dsn = 'http://key@localhost:$port/api/v1/events';
        c.environment = 'production';
        c.timeout = const Duration(milliseconds: 500);
      });
      expect(() => fot.recordChange('config', 'Nobody listening'), returnsNormally);
      await fot.flushChanges();
    });
  });
}
