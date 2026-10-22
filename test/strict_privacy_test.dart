import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;
import 'package:forge_ops_tracker/forge_ops_tracker.dart' show Configuration, EventBuilder;
import 'package:forge_ops_tracker/src/strict_privacy.dart';
import 'package:test/test.dart';

// A byte-identical copy of sdks/strict_privacy_vectors.json, generated from the server's own
// app/services/strict_privacy.rb: the results every SDK and the server have to agree on.
final File _fixture = File('test/fixtures/strict_privacy_vectors.json');
final Map<String, Object?> _vectors = jsonDecode(_fixture.readAsStringSync()) as Map<String, Object?>;

List<Map<String, Object?>> _entries(String key) => (_vectors[key] as List).cast<Map<String, Object?>>();

class _SqlError implements Exception {
  _SqlError(this.message, this.sql);

  final String message;
  final String sql;

  @override
  String toString() => message;
}

(Object, StackTrace) _throwAndCatch(Object error) {
  try {
    throw error;
  } catch (error, stackTrace) {
    return (error, stackTrace);
  }
}

Configuration _newConfiguration() => Configuration()
  ..environment = 'production'
  ..release = 'abc123'
  ..serverName = 'web-1'
  ..packageName = 'forge_ops_tracker'
  ..captureSourceContext = true
  ..captureSqlStatement = true;

Map<String, Object?> _build(Configuration config) {
  final (error, stackTrace) = _throwAndCatch(_SqlError(
      "Couldn't find Patient with id=8821 (jane@example.com)", "SELECT * FROM patients WHERE email = 'jane@example.com'"));
  return EventBuilder(config).build(
    error,
    stackTrace,
    context: {'error_code': 'E42', 'diagnosis': 'flu', 'nested': {'error_code': 'x'}},
    user: {'id': 7, 'email': 'jane@example.com', 'username': 'jane'},
    breadcrumbs: [
      {'category': 'http', 'message': 'GET /patients/7'},
    ],
    traceId: 'a' * 32,
  );
}

void main() {
  group('strict privacy vectors', () {
    // That the fixture matches the repo's sdks/strict_privacy_vectors.json is checked by the
    // server's own suite (spec/models/sdk_strict_privacy_vectors_spec.rb): a published package's
    // tests can't read outside its own directory.

    for (final vector in _entries('fingerprint')) {
      test('fingerprint vector ${jsonEncode(vector['message'])}', () {
        expect(normalizeMessage(vector['message'] as String), vector['normalized']);
        expect(messageFingerprint(vector['message'] as String), vector['fingerprint']);
      });
    }

    for (final vector in _entries('path')) {
      test('path vector ${jsonEncode(vector['path'])}', () {
        expect(strictPath(vector['path'] as String), vector['strict']);
      });
    }

    for (final vector in _entries('span_name')) {
      test('span_name vector ${jsonEncode(vector['name'])}', () {
        expect(spanName(vector['name'] as String), vector['strict']);
      });
    }

    test('the self-contained SHA-256 matches known digests, across block boundaries', () {
      expect(sha256Hex([]), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(sha256Hex(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      expect(sha256Hex(utf8.encode('a' * 1000)), '41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3');
    });
  });

  group('EventBuilder with strict privacy', () {
    test('keeps only structured facts', () {
      final config = _newConfiguration()
        ..strictPrivacy = true
        ..privacyAllowedFields = ['error_code', 'nested', 'missing'];

      final payload = _build(config);

      expect(payload.containsKey('message'), isFalse);
      // From the message as it would have been sent: scrubbed, since scrubPii is on.
      expect(payload['message_fingerprint'], messageFingerprint("Couldn't find Patient with id=8821 ([EMAIL FILTERED])"));
      expect(payload['message_fingerprint'], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(payload.containsKey('breadcrumbs'), isFalse);
      expect(payload.containsKey('endpoint'), isFalse);
      expect(payload.containsKey('sql_statement'), isFalse);
      expect(payload['sql_objects'], isNotNull);
      expect(payload['context'], {'error_code': 'E42'});
      expect(payload.containsKey('tags'), isFalse);
      expect(payload['user'], {'id': '7'});
      expect(payload['trace_id'], 'a' * 32);
      expect(payload['exception_class'], '_SqlError');
      final frames = (payload['backtrace'] as List).cast<Map<String, Object?>>();
      expect(frames, isNotEmpty);
      for (final frame in frames) {
        expect(frame.keys.toSet(), {'file', 'line', 'method', 'in_app'});
      }
      expect(jsonEncode(payload), isNot(matches(RegExp('jane|flu|8821'))));
    });

    test('strictEvent drops source context, endpoint and free text from a payload that has them', () {
      final payload = strictEvent({
        'exception_class': 'StateError',
        'message': 'Bad state: Jane',
        'endpoint': 'GET /patients/7',
        'sql_statement': 'SELECT ?',
        'breadcrumbs': [
          {'message': 'Jane'},
        ],
        'tags': {'error_code': 'E1', 'ward': 'oncology'},
        'backtrace': [
          {'file': 'package:app/a.dart', 'line': 3, 'method': 'main', 'in_app': true, 'context_line': 'x', 'pre_context': ['y'], 'post_context': ['z']},
        ],
      }, 'f' * 32, ['error_code']);

      expect(payload, {
        'exception_class': 'StateError',
        'message_fingerprint': 'f' * 32,
        'backtrace': [
          {'file': 'package:app/a.dart', 'line': 3, 'method': 'main', 'in_app': true},
        ],
        'tags': {'error_code': 'E1'},
      });
    });

    test('the fingerprint is taken from the unscrubbed message when scrubPii is off', () {
      final config = _newConfiguration()
        ..strictPrivacy = true
        ..scrubPii = false;

      expect(_build(config)['message_fingerprint'], messageFingerprint("Couldn't find Patient with id=8821 (jane@example.com)"));
    });

    test('leaves context, tags and user out when nothing is allowed or there is no id', () {
      final config = _newConfiguration()..strictPrivacy = true;
      final (error, stackTrace) = _throwAndCatch(_SqlError('boom', ''));

      final payload = EventBuilder(config).build(error, stackTrace,
          context: {'error_code': 'E42'}, user: {'email': 'jane@example.com'});

      expect(payload.containsKey('context'), isFalse);
      expect(payload.containsKey('tags'), isFalse);
      expect(payload.containsKey('user'), isFalse);
      expect(payload['message_fingerprint'], '81f52337ebb4cb1669bb802c708807dd');
    });

    test('with strict privacy off, events are exactly as before', () {
      final config = _newConfiguration()..privacyAllowedFields = ['error_code']; // ignored while off

      // Built from the same line, so the two backtraces are identical too.
      final [payload, untouched] = [config, _newConfiguration()].map(_build).toList();

      expect(payload['message'], "Couldn't find Patient with id=8821 ([EMAIL FILTERED])");
      expect(payload.containsKey('message_fingerprint'), isFalse);
      expect(payload['breadcrumbs'], hasLength(1));
      expect(payload['sql_statement'], isA<String>());
      expect((payload['context'] as Map).keys, ['error_code', 'diagnosis', 'nested']);
      expect(payload['user'], {'id': 7, 'email': 'jane@example.com', 'username': 'jane'});
      untouched['occurred_at'] = payload['occurred_at']; // the only field that may differ between two builds
      expect(payload, untouched);
    });
  });

  group('Configuration', () {
    test('both options are off and empty by default', () {
      final config = Configuration();
      expect(config.strictPrivacy, isFalse);
      expect(config.privacyAllowedFields, isEmpty);
    },
        skip: Platform.environment.containsKey('FORGE_OPS_STRICT_PRIVACY') ||
                Platform.environment.containsKey('FORGE_OPS_PRIVACY_ALLOWED_FIELDS')
            ? 'this shell sets the strict privacy environment variables'
            : false);

    test('the environment variables parse the way init reads them', () {
      expect(envFlag('true'), isTrue);
      expect(envFlag(' TRUE '), isTrue);
      expect(envFlag('1'), isTrue);
      expect(envFlag('false'), isFalse);
      expect(envFlag(null), isFalse);
      expect(envList('error_code, feature,,'), ['error_code', 'feature']);
      expect(envList(null), isEmpty);
    });

    test('FORGE_OPS_STRICT_PRIVACY and FORGE_OPS_PRIVACY_ALLOWED_FIELDS set the defaults', () async {
      final result = await Process.run(Platform.resolvedExecutable, ['test/fixtures/strict_privacy_env_child.dart'],
          environment: {
        'FORGE_OPS_STRICT_PRIVACY': 'true',
        'FORGE_OPS_PRIVACY_ALLOWED_FIELDS': 'error_code,feature',
      });
      expect(result.stdout.toString().trim(), 'true [error_code, feature]', reason: result.stderr.toString());
    });
  });

  group('the full stack with strict privacy', () {
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

    void configure({bool strict = true}) {
      fot.init((c) {
        c.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        c.environment = 'production';
        c.strictPrivacy = strict;
        c.privacyAllowedFields = ['error_code'];
        c.traceCaptureThreshold = Duration.zero;
      });
    }

    test('captureException sends no message or breadcrumbs, and breadcrumbs are not recorded', () async {
      configure();

      fot.addBreadcrumb('Viewed patient Jane Doe');
      fot.captureException(Exception('Patient Jane Doe not found'), null, {'error_code': 'E1', 'name': 'Jane'});
      expect(await fot.flush(), isTrue);

      final event = bodies.single;
      expect(event.containsKey('message'), isFalse);
      expect(event.containsKey('breadcrumbs'), isFalse);
      expect(event['message_fingerprint'], messageFingerprint('Exception: Patient Jane Doe not found'));
      expect(event['context'], {'error_code': 'E1'});
      expect(jsonEncode(event), isNot(contains('Jane')));
    });

    test('spans go out by method and host, with only db.statement and db.system as data', () async {
      configure();

      await fot.traceAsync('/patients/42', () async {
        await fot.httpSpanAsync('GET', Uri.parse('https://api.example.com/patients/42?x=1'), (headers) async => null,
            data: {'status': 200});
        fot.recordSpan('load',
            kind: 'database',
            startedAt: DateTime.now(),
            durationMs: 1,
            statement: 'SELECT * FROM notes WHERE id = 3',
            dbSystem: 'sqlite',
            data: {'rows': 2});
      });
      await fot.flushSpans();

      final spans = (bodies.single['spans'] as List).cast<Map<String, Object?>>();
      final root = spans.firstWhere((s) => s['kind'] == 'controller');
      final http = spans.firstWhere((s) => s['kind'] == 'http');
      final database = spans.firstWhere((s) => s['kind'] == 'database');
      expect(root['name'], '/patients/:path');
      expect(http['name'], 'GET api.example.com');
      expect(http['data'], isEmpty);
      expect(database['data'], {'db.system': 'sqlite', 'db.statement': 'SELECT * FROM notes WHERE id = ?'});
    });

    for (final strict in [true, false]) {
      test('performance samples: a raw-path transaction name loses its ids only with strict privacy on ($strict)',
          () async {
        configure(strict: strict);

        fot.recordPerformance('GET /patients/42', 10);
        fot.recordPerformance('GET /patients/43', 10);
        fot.recordPerformance('job:reindex', 10);
        await fot.flushPerformance();

        final samples = (bodies.single['samples'] as List).cast<Map<String, Object?>>();
        final names = samples.map((sample) => sample['transaction_name'] as String).toList()..sort();
        expect(names, strict ? ['GET /patients/:path', 'job:reindex'] : ['GET /patients/42', 'GET /patients/43', 'job:reindex']);
      });
    }

    test('with strict privacy off, events and spans are unchanged', () async {
      configure(strict: false);

      fot.addBreadcrumb('clicked save');
      fot.captureException(Exception('boom 42'), null, {'error_code': 'E1', 'feature': 'x'});
      await fot.traceAsync('/patients/42', () async {
        await fot.httpSpanAsync('GET', Uri.parse('https://api.example.com/x'), (headers) async => null,
            data: {'status': 200});
      });
      expect(await fot.flush(), isTrue);

      final event = bodies.firstWhere((b) => b.containsKey('exception_class'));
      expect(event['message'], 'Exception: boom 42');
      expect(event.containsKey('message_fingerprint'), isFalse);
      expect(event['breadcrumbs'], hasLength(1));
      expect(event['context'], {'error_code': 'E1', 'feature': 'x'});
      final spans = (bodies.firstWhere((b) => b.containsKey('spans'))['spans'] as List).cast<Map<String, Object?>>();
      expect(spans.firstWhere((s) => s['kind'] == 'controller')['name'], '/patients/42');
      expect(spans.firstWhere((s) => s['kind'] == 'http')['data'], {'status': 200});
    });
  });
}
