import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as fot;
import 'package:test/test.dart';

void main() {
  group('TraceParent', () {
    const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
    const spanId = '00f067aa0ba902b7';

    test('parses a valid version 00 header, trimming surrounding whitespace', () {
      final context = fot.TraceParent.parse('  00-$traceId-$spanId-01 ')!;
      expect(context.traceId, traceId);
      expect(context.parentSpanId, spanId);
    });

    test('accepts a future version with extra fields, but not version 00 with extra fields', () {
      expect(fot.TraceParent.parse('cc-$traceId-$spanId-01-what-the-future-holds')?.traceId, traceId);
      expect(fot.TraceParent.parse('00-$traceId-$spanId-01-extra'), isNull);
    });

    test('rejects version ff, all-zero ids, uppercase hex, and malformed values', () {
      for (final value in [
        null,
        '',
        'garbage',
        'ff-$traceId-$spanId-01',
        '00-${'0' * 32}-$spanId-01',
        '00-$traceId-${'0' * 16}-01',
        '00-${traceId.toUpperCase()}-$spanId-01',
        '00-$traceId-$spanId',
        '00-${traceId}a-$spanId-01',
        '0-$traceId-$spanId-01',
      ]) {
        expect(fot.TraceParent.parse(value), isNull, reason: '$value');
      }
    });

    test('builds a sampled version 00 header', () {
      expect(fot.TraceParent.build(traceId, spanId), '00-$traceId-$spanId-01');
    });

    test('generates lowercase hex ids that are never all zeros', () {
      for (var i = 0; i < 200; i++) {
        expect(fot.TraceParent.generateTraceId(), matches(RegExp(r'^(?!0{32}$)[0-9a-f]{32}$')));
        expect(fot.TraceParent.generateSpanId(), matches(RegExp(r'^(?!0{16}$)[0-9a-f]{16}$')));
      }
    });
  });

  group('trace propagation targets', () {
    test('default to every host with propagation on', () {
      final config = fot.Configuration();
      expect(config.propagateTraces, isTrue);
      expect(config.tracePropagationTargets, isNull);
      expect(config.shouldPropagateTrace('anything.test'), isTrue);
      expect(config.shouldPropagateTrace(null), isTrue);
    });

    test('a host matches exactly or as a subdomain on a dot boundary, ignoring case and a leading dot', () {
      final config = fot.Configuration()..tracePropagationTargets = ['Example.com', '.internal.test'];
      expect(config.shouldPropagateTrace('example.com'), isTrue);
      expect(config.shouldPropagateTrace('api.EXAMPLE.com'), isTrue);
      expect(config.shouldPropagateTrace('badexample.com'), isFalse);
      expect(config.shouldPropagateTrace('example.com.evil.test'), isFalse);
      expect(config.shouldPropagateTrace('db.internal.test'), isTrue);
      expect(config.shouldPropagateTrace(null), isFalse, reason: 'no host only gets the header when every host does');
      expect(config.shouldPropagateTrace(''), isFalse);
    });

    test('a RegExp is searched for in the lowercased host, and anything else matches nothing', () {
      final config = fot.Configuration()..tracePropagationTargets = [RegExp(r'^api\d+\.corp$'), 42];
      expect(config.shouldPropagateTrace('API7.corp'), isTrue);
      expect(config.shouldPropagateTrace('api.corp'), isFalse);
      expect(config.shouldPropagateTrace('42'), isFalse);
    });

    test('an empty list, or propagation off, matches nothing', () {
      final config = fot.Configuration()..tracePropagationTargets = [];
      expect(config.shouldPropagateTrace('example.com'), isFalse);
      config
        ..tracePropagationTargets = null
        ..propagateTraces = false;
      expect(config.shouldPropagateTrace('example.com'), isFalse);
    });
  });

  group('trace context', () {
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
        bodies.add(body.isEmpty ? const {} : jsonDecode(body) as Map<String, Object?>);
        request.response.statusCode = 202;
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      fot.resetForTesting();
    });

    void configure({bool tracing = true, void Function(fot.Configuration config)? extra}) {
      fot.init((c) {
        c.dsn = 'http://key@localhost:${server.port}/api/v1/events';
        c.environment = 'production';
        c.trackTracing = tracing;
        c.traceCaptureThreshold = Duration.zero;
        extra?.call(c);
      });
    }

    List<Map<String, Object?>> bodiesTo(String path) =>
        [for (var i = 0; i < requests.length; i++) if (requests[i].uri.path == path) bodies[i]];

    Future<List<Map<String, Object?>>> events(int count) async {
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (bodiesTo('/api/v1/events').length < count && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return bodiesTo('/api/v1/events');
    }

    Map<String, Object?> span(Map<String, Object?> trace, String name) =>
        (trace['spans'] as List).cast<Map<String, Object?>>().firstWhere((s) => s['name'] == name);

    test('trace continues an incoming traceparent: same trace id, root parented to the caller span', () async {
      configure();
      const incoming = '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01';

      final seen = await fot.traceAsync('POST /orders', () async => fot.currentTraceId(), traceparent: incoming);
      fot.trace('GET /health', () {}, traceparent: incoming);
      await fot.flushSpans();

      expect(seen, '4bf92f3577b34da6a3ce929d0e0e4736');
      final traces = bodiesTo('/api/v1/spans');
      expect(traces.length, 2);
      for (final trace in traces) {
        expect(trace['trace_id'], '4bf92f3577b34da6a3ce929d0e0e4736');
        expect((trace['spans'] as List).first['parent_span_id'], '00f067aa0ba902b7');
      }
    });

    test('a malformed traceparent starts a fresh trace, and one inside an open trace is ignored', () async {
      configure();

      await fot.traceAsync('outer', () async {
        final outerId = fot.currentTraceId();
        fot.trace('inner', () => expect(fot.currentTraceId(), outerId),
            traceparent: '00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01');
      }, traceparent: '00-${'0' * 32}-00f067aa0ba902b7-01');
      await fot.flushSpans();

      final trace = bodiesTo('/api/v1/spans').single;
      expect(trace['trace_id'], isNot('0' * 32));
      expect(span(trace, 'outer')['parent_span_id'], isNull);
      expect(span(trace, 'inner')['parent_span_id'], span(trace, 'outer')['span_id']);
    });

    test('httpSpan hands the body a traceparent naming the http span it records', () async {
      configure();
      late Map<String, String> sent;
      late String traceId;

      await fot.traceAsync('checkout', () async {
        traceId = fot.currentTraceId()!;
        await fot.spanAsync('place order', () async {
          final result = fot.httpSpan('post', Uri.parse('https://api.example.com/orders/42?token=x'), (headers) {
            sent = headers;
            return 7;
          }, data: {'status': 201});
          expect(result, 7);
        });
      });
      await fot.flushSpans();

      final trace = bodiesTo('/api/v1/spans').single;
      final http = span(trace, 'POST api.example.com');
      expect(sent, {'traceparent': '00-$traceId-${http['span_id']}-01'});
      expect(http['kind'], 'http');
      expect(http['parent_span_id'], span(trace, 'place order')['span_id']);
      expect(http['data'], {'status': 201});
    });

    test('httpSpanAsync sends the header over a real request and records the span even if the body throws',
        () async {
      configure();
      final client = HttpClient();
      final uri = Uri.parse('http://localhost:${server.port}/orders');

      await expectLater(
          fot.traceAsync('checkout', () async {
            await fot.httpSpanAsync('GET', uri, (headers) async {
              final request = await client.getUrl(uri);
              headers.forEach(request.headers.set);
              await (await request.close()).drain<void>();
            });
            await fot.httpSpanAsync('GET', uri, (headers) async => throw StateError('network down'));
          }),
          throwsStateError);
      await fot.flushSpans();
      client.close();

      final orders = requests.firstWhere((r) => r.uri.path == '/orders');
      final trace = bodiesTo('/api/v1/spans').single;
      final httpSpans = (trace['spans'] as List).cast<Map<String, Object?>>().where((s) => s['kind'] == 'http').toList();
      expect(httpSpans.length, 2);
      expect(orders.headers.value('traceparent'), '00-${trace['trace_id']}-${httpSpans.first['span_id']}-01');
      expect(httpSpans.first['name'], 'GET localhost');
    });

    test('outside a trace httpSpan hands over no headers and records nothing', () async {
      configure();
      expect(fot.httpSpan('GET', Uri.parse('https://api.example.com/'), (headers) => headers), isEmpty);
      expect(await fot.httpSpanAsync('GET', Uri.parse('https://api.example.com/'), (headers) async => headers), isEmpty);
      expect(fot.currentTraceId(), isNull);
      await fot.flushSpans();
      expect(requests, isEmpty);
    });

    test('propagateTraces off or an untargeted host gets no header, but the span is still recorded', () async {
      configure(extra: (c) => c.tracePropagationTargets = ['example.com']);

      await fot.traceAsync('t', () async {
        expect(fot.httpSpan('GET', Uri.parse('https://api.example.com/'), (h) => h), isNotEmpty);
        expect(fot.httpSpan('GET', Uri.parse('https://third-party.test/'), (h) => h), isEmpty);
        fot.configuration().propagateTraces = false;
        expect(fot.httpSpan('GET', Uri.parse('https://api.example.com/'), (h) => h), isEmpty);
      });
      await fot.flushSpans();

      final spans = bodiesTo('/api/v1/spans').single['spans'] as List;
      expect(spans.where((s) => (s as Map)['kind'] == 'http').length, 3);
    });

    test('an error captured inside a trace carries its trace id, across awaits; outside it has none', () async {
      configure();
      late String traceId;

      await fot.traceAsync('checkout', () async {
        traceId = fot.currentTraceId()!;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        fot.captureException(StateError('inside'), StackTrace.current);
      });
      fot.captureException(StateError('outside'), StackTrace.current);

      final sent = await events(2);
      final inside = sent.firstWhere((e) => (e['message'] as String).contains('inside'));
      final outside = sent.firstWhere((e) => (e['message'] as String).contains('outside'));
      expect(inside['trace_id'], traceId);
      expect(traceId, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(outside.containsKey('trace_id'), isFalse);
    });

    test('an error that escaped a trace keeps its trace id when captured afterward', () async {
      configure();
      String? traceId;
      final error = StateError('escaped');

      try {
        fot.trace('checkout', () {
          traceId = fot.currentTraceId();
          fot.trace('nested', () => throw error);
        });
      } catch (caught) {
        fot.captureException(caught, StackTrace.current);
      }
      // A string can't carry it, but must not break capture either.
      try {
        await fot.traceAsync('t', () async => throw 'a plain string');
      } catch (caught) {
        fot.captureException(caught, StackTrace.current);
      }

      final sent = await events(2);
      expect(sent.firstWhere((e) => e['exception_class'] == 'StateError')['trace_id'], traceId);
      expect(sent.firstWhere((e) => e['exception_class'] == 'String').containsKey('trace_id'), isFalse);
    });

    test('with trackTracing off a trace still has an id for errors and headers, but sends no spans', () async {
      configure(tracing: false);
      late String traceId;
      late Map<String, String> headers;

      await fot.traceAsync('checkout', () async {
        traceId = fot.currentTraceId()!;
        headers = fot.httpSpan('GET', Uri.parse('https://api.example.com/'), (h) => h);
        fot.captureException(StateError('boom'), StackTrace.current);
      });
      await fot.flushSpans();

      expect(headers['traceparent'], startsWith('00-$traceId-'));
      expect((await events(1)).single['trace_id'], traceId);
      expect(bodiesTo('/api/v1/spans'), isEmpty);
    });

    test('with reporting disabled there is no trace at all', () async {
      configure(extra: (c) => c.environment = 'development');
      expect(fot.trace('t', () => fot.currentTraceId()), isNull);
      expect(fot.trace('t', () => fot.httpSpan('GET', Uri.parse('https://a.test/'), (h) => h)), isEmpty);
    });

    test('the event builder adds trace_id after scrubbing and leaves it out when null', () {
      final builder = fot.EventBuilder(fot.Configuration());
      const traceId = '4bf92f3577b34da6a3ce929d0e0e4736';
      expect(builder.build(StateError('x'), StackTrace.current, traceId: traceId)['trace_id'], traceId);
      expect(builder.build(StateError('x'), StackTrace.current).containsKey('trace_id'), isFalse);
    });
  });
}
