import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

class _SampleError extends Error {
  @override
  String toString() => 'boom';
}

(Object, StackTrace) _throwAndCatch() {
  try {
    throw _SampleError();
  } catch (error, stackTrace) {
    return (error, stackTrace);
  }
}

Configuration _newConfiguration() => Configuration()
  ..environment = 'production'
  ..release = 'abc123'
  ..serverName = 'web-1';

void main() {
  group('EventBuilder', () {
    test('builds payload with exception class, message, and configured metadata', () {
      final builder = EventBuilder(_newConfiguration());
      final (error, stackTrace) = _throwAndCatch();

      final payload = builder.build(error, stackTrace, context: {'url': 'https://example.com'});

      expect(payload['exception_class'], '_SampleError');
      expect(payload['message'], 'boom');
      expect(payload['environment'], 'production');
      expect(payload['release'], 'abc123');
      expect(payload['server_name'], 'web-1');
      expect(payload['context'], {'url': 'https://example.com'});
      expect(payload['occurred_at'], isA<String>());
      expect(payload['sdk_name'], 'dart');
      expect(payload['occurred_at'], endsWith('Z'));
    });

    test('parses real stack frames with method, file, and line', () {
      final builder = EventBuilder(_newConfiguration());
      final (error, stackTrace) = _throwAndCatch();

      final frames = builder.build(error, stackTrace)['backtrace'] as List;

      expect(frames, isNotEmpty);
      final frame = frames.first as Map;
      expect(frame['method'], isA<String>());
      expect(frame['file'], isA<String>());
      expect(frame['line'], isA<int>());
      expect(frame['in_app'], isA<bool>());
    });

    test('marks a frame as in_app when packageName matches', () {
      final config = _newConfiguration()..packageName = 'my_app';
      final builder = EventBuilder(config);
      // A synthetic StackTrace (StackTrace.fromString) rather than a real one caught from `test/`
      // code: `dart test` runs test files under their own file:// location, not a
      // "package:forge_ops_tracker/..." one, so a real captured trace here wouldn't actually
      // exercise the packageName-match branch at all. This is the real frame format
      // (verified directly against a real caught trace elsewhere in this file), just with a
      // package location under this test's control.
      final stackTrace = StackTrace.fromString(
        '#0      ChargeService.chargeCard (package:my_app/charge_service.dart:42:7)\n'
        '#1      main (package:my_app/main.dart:10:3)\n',
      );

      final frames = builder.build(Exception('boom'), stackTrace)['backtrace'] as List;

      expect(frames, hasLength(2));
      expect((frames[0] as Map)['in_app'], isTrue);
      expect((frames[0] as Map)['file'], 'package:my_app/charge_service.dart');
      expect((frames[0] as Map)['line'], 42);
      expect((frames[0] as Map)['method'], 'ChargeService.chargeCard');
    });

    test('a dart: or third-party package: frame is never in_app', () {
      final config = _newConfiguration()..packageName = 'my_app';
      final builder = EventBuilder(config);
      final stackTrace = StackTrace.fromString(
        '#0      List.forEach (dart:core/list.dart:300:1)\n'
        '#1      SomeHelper.run (package:some_other_pkg/helper.dart:5:3)\n',
      );

      final frames = builder.build(Exception('boom'), stackTrace)['backtrace'] as List;

      expect(frames.every((f) => (f as Map)['in_app'] == false), isTrue);
    });

    test('no frame is in_app when packageName is unset', () {
      final builder = EventBuilder(_newConfiguration());
      final (error, stackTrace) = _throwAndCatch();

      final frames = builder.build(error, stackTrace)['backtrace'] as List;

      expect(frames.every((f) => (f as Map)['in_app'] == false), isTrue);
    });

    test('returns an empty backtrace for a null stack trace', () {
      final builder = EventBuilder(_newConfiguration());

      final payload = builder.build(_SampleError(), null);

      expect(payload['backtrace'], isEmpty);
    });

    test('scrubs likely pii out of message and context by default', () {
      final builder = EventBuilder(_newConfiguration());

      final payload = builder.build(
        Exception('failed for user@example.com'),
        null,
        context: {
          'user': {'email': 'ada@example.com', 'password': 'hunter2'},
        },
      );

      expect(payload['message'], 'Exception: failed for [EMAIL FILTERED]');
      expect(payload['context'], {
        'user': {'email': '[EMAIL FILTERED]', 'password': redacted},
      });
    });

    test('leaves payload untouched when scrubPii is disabled', () {
      final config = _newConfiguration()..scrubPii = false;
      final builder = EventBuilder(config);

      final payload =
          builder.build(Exception('failed for user@example.com'), null, context: {'email': 'ada@example.com'});

      expect(payload['message'], 'Exception: failed for user@example.com');
      expect(payload['context'], {'email': 'ada@example.com'});
    });

    test('includes the user when given one, never scrubbed even though it is an email', () {
      final builder = EventBuilder(_newConfiguration());

      final payload = builder.build(Exception('boom'), null, user: {'id': 42, 'email': 'ada@example.com'});

      expect(payload['user'], {'id': 42, 'email': 'ada@example.com'});
    });

    test('omits the user key entirely when none was given', () {
      final builder = EventBuilder(_newConfiguration());

      final payload = builder.build(Exception('boom'), null);

      expect(payload.containsKey('user'), isFalse);
    });

    test('includes breadcrumbs when given', () {
      final builder = EventBuilder(_newConfiguration());
      final crumb = {
        'category': 'controller',
        'message': 'GET /orders/42',
        'level': 'info',
        'timestamp': '2024-01-15T10:29:58Z',
        'data': <String, Object?>{},
      };

      final payload = builder.build(Exception('boom'), null, breadcrumbs: [crumb]);

      expect(payload['breadcrumbs'], [crumb]);
    });

    test('omits the breadcrumbs key entirely when none were given, or the list is empty', () {
      final builder = EventBuilder(_newConfiguration());

      expect(builder.build(Exception('boom'), null).containsKey('breadcrumbs'), isFalse);
      expect(builder.build(Exception('boom'), null, breadcrumbs: []).containsKey('breadcrumbs'), isFalse);
    });

    test('scrubs likely pii out of a breadcrumb message and data', () {
      final builder = EventBuilder(_newConfiguration());
      final crumb = {
        'category': 'custom',
        'message': 'emailed alice@example.com',
        'level': 'info',
        'timestamp': '2024-01-15T10:29:58Z',
        'data': {'email': 'alice@example.com', 'password': 'hunter2'},
      };

      final payload = builder.build(Exception('boom'), null, breadcrumbs: [crumb]);

      final scrubbed = (payload['breadcrumbs'] as List).first as Map;
      expect(scrubbed['message'], isNot(contains('alice@example.com')));
      expect(scrubbed['category'], 'custom');
      expect(scrubbed['level'], 'info');
      expect(scrubbed['timestamp'], '2024-01-15T10:29:58Z');
      expect((scrubbed['data'] as Map)['password'], redacted);
    });
  });

  group('source context capture', () {
    // A package: location (the only shape EventBuilder's own in_app check recognizes: see its
    // "A dart:...  location..." doc comment) only ever resolves to a real file underneath the
    // owning package's own lib/ directory (Isolate.resolvePackageUriSync's own contract), so a
    // real temp file for this suite has to live there too rather than under the OS temp
    // directory: always written fresh and removed again in tearDown, never a committed fixture.
    late Directory tempDir;

    setUp(() {
      tempDir = Directory(
        'lib/.forge_ops_tracker_test_tmp_${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    File writeSourceFile(String contents) {
      final file = File('${tempDir.path}/app_file.dart');
      file.writeAsStringSync(contents);
      return file;
    }

    String locationFor(File file) =>
        'package:forge_ops_tracker/${tempDir.path.substring(4)}/${file.uri.pathSegments.last}';

    Map<String, Object?> frameFor(String location, int line, {bool captureSourceContext = true}) {
      final config = _newConfiguration()
        ..packageName = 'forge_ops_tracker'
        ..captureSourceContext = captureSourceContext;
      final builder = EventBuilder(config);
      final stackTrace = StackTrace.fromString('#0      call ($location:$line:1)\n');

      final frames = builder.build(Exception('boom'), stackTrace)['backtrace'] as List;
      return frames.first as Map<String, Object?>;
    }

    test('attaches context_line/pre_context/post_context around the culprit line, by default', () {
      final file = writeSourceFile(List.generate(20, (i) => 'line ${i + 1}').join('\n'));

      final frame = frameFor(locationFor(file), 10);

      expect(frame['context_line'], 'line 10');
      expect(frame['pre_context'], [for (var n = 5; n <= 9; n++) 'line $n']);
      expect(frame['post_context'], [for (var n = 11; n <= 15; n++) 'line $n']);
    });

    test('clamps pre_context/post_context at the start and end of the file rather than throwing', () {
      final file = writeSourceFile(List.generate(3, (i) => 'line ${i + 1}').join('\n'));

      final first = frameFor(locationFor(file), 1);
      final last = frameFor(locationFor(file), 3);

      expect(first['pre_context'], <String>[]);
      expect(first['post_context'], ['line 2', 'line 3']);
      expect(last['pre_context'], ['line 1', 'line 2']);
      expect(last['post_context'], <String>[]);
    });

    test('truncates a line longer than the max context line length', () {
      final file = writeSourceFile('x' * 600);

      final frame = frameFor(locationFor(file), 1);

      expect(frame['context_line'], '${'x' * 500}...');
    });

    test('never attaches context to a frame that is not in_app', () {
      final file = writeSourceFile(List.generate(20, (i) => 'line ${i + 1}').join('\n'));
      final config = _newConfiguration(); // packageName left unset: every frame is not in_app
      final builder = EventBuilder(config);
      final stackTrace = StackTrace.fromString('#0      call (${locationFor(file)}:10:1)\n');

      final frame = (builder.build(Exception('boom'), stackTrace)['backtrace'] as List).first as Map;

      expect(frame['in_app'], isFalse);
      expect(frame.containsKey('context_line'), isFalse);
      expect(frame.containsKey('pre_context'), isFalse);
      expect(frame.containsKey('post_context'), isFalse);
    });

    test('leaves the frame untouched, with no context, when captureSourceContext is disabled', () {
      final file = writeSourceFile(List.generate(20, (i) => 'line ${i + 1}').join('\n'));

      final frame = frameFor(locationFor(file), 10, captureSourceContext: false);

      expect(frame.containsKey('context_line'), isFalse);
      expect(frame.containsKey('pre_context'), isFalse);
      expect(frame.containsKey('post_context'), isFalse);
    });

    test('leaves the frame untouched when the recorded file cannot be read', () {
      final location = 'package:forge_ops_tracker/${tempDir.path.substring(4)}/does_not_exist.dart';

      final frame = frameFor(location, 1);

      expect(frame.containsKey('context_line'), isFalse);
    });
  });
}
