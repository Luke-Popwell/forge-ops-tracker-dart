import 'configuration.dart';
import 'sql_statement.dart';
import 'trace_parent.dart';

/// One trace's worth of spans (a request's, or a job's, own call tree), sharing a single trace id.
/// Held in a [Zone] value by `trace`/`traceAsync` in forge_ops_tracker_base.dart, the same
/// per-call-chain scoping `runWithUser`/`runWithBreadcrumbs` use, so a Dart server handling more
/// than one request at a time keeps each request's trace apart, across `await`s.
///
/// Which span is the parent of a new one is a second Zone value (the current span id), not a stack
/// in here: `span`/`spanAsync` run their body in a child zone whose current span is the new one, so
/// parallel `Future`s started inside one span each see it as their parent, and a span opened after
/// another one closed goes back to the outer parent for free. This class only collects.
///
/// Kinds are the closed set the ingestion API accepts (controller, service, database, redis, http,
/// job, other): anything else is sent as `other`, since one bad kind would make the server reject
/// the whole trace. A trace holds at most [maxSpans] spans including the root.
///
/// Ids are W3C trace context ids (see [TraceParent]). [traceId] and [remoteParentSpanId] come from
/// an incoming `traceparent` header when this trace continues another service's; the root span then
/// points at that remote span, which the server nests it under even though it arrives in a different
/// upload.
class SpanBuffer {
  SpanBuffer(this._configuration, {String? traceId, this.remoteParentSpanId})
      : traceId = traceId ?? TraceParent.generateTraceId(),
        rootSpanId = TraceParent.generateSpanId();

  static const int maxSpans = 500;
  static const Set<String> _kinds = {'controller', 'service', 'database', 'redis', 'http', 'job', 'other'};

  final Configuration _configuration;
  final String traceId;
  final String rootSpanId;
  final String? remoteParentSpanId;
  final List<Map<String, Object?>> _spans = [];
  bool _finished = false;

  static String newSpanId() => TraceParent.generateSpanId();

  /// Records a finished span. Dropped once the trace has finished or is full. For a `database`
  /// span, [statement] and [dbSystem] are added to its data as described on [spanData].
  void record({
    required String spanId,
    required String parentSpanId,
    required String name,
    required String kind,
    required DateTime startedAt,
    required double durationMs,
    Map<String, Object?>? data,
    String? statement,
    String? dbSystem,
  }) {
    if (_finished || _spans.length >= maxSpans - 1) return; // leave room for the root
    _spans.add(_build(spanId, parentSpanId, name, kind, startedAt, durationMs,
        spanData(kind, data, statement: statement, dbSystem: dbSystem)));
  }

  /// A span's data, with a `database` span's SQL added as `db.statement`, masked with [maskSql]
  /// (every string and number literal becomes `?`, cut at 4000 characters), and its `db.system`,
  /// lowercased. A `db.statement` passed in [data] directly is masked too, so raw SQL can never go
  /// out on a span; with a `db.system` of `mysql` or `mariadb`, so is "double quoted" text. Any
  /// other kind's data is returned unchanged.
  static Map<String, Object?>? spanData(String kind, Map<String, Object?>? data, {String? statement, String? dbSystem}) {
    if (kind != 'database') return data;
    final result = <String, Object?>{...?data};
    final system = dbSystem ?? result['db.system'];
    result.remove('db.system');
    final lowered = system is String && system.trim().isNotEmpty ? system.trim().toLowerCase() : null;
    if (lowered != null) result['db.system'] = lowered;
    final raw = statement ?? result['db.statement'];
    result.remove('db.statement');
    final masked = raw is String ? maskSql(raw, system: lowered) : null;
    if (masked != null) result['db.statement'] = masked;
    return result;
  }

  /// The wire payload once the root has ended, or null when it was faster than
  /// [Configuration.traceCaptureThreshold] (or the trace already finished): idempotent, so a second
  /// call sends nothing.
  Map<String, Object?>? finish(String rootName, DateTime startedAt, double durationMs) {
    if (_finished) return null;
    _finished = true;
    if (durationMs < _configuration.traceCaptureThreshold.inMicroseconds / 1000) return null;

    return {
      'trace_id': traceId,
      'spans': [
        _build(rootSpanId, remoteParentSpanId, rootName, 'controller', startedAt, durationMs, null),
        ..._spans,
      ],
    };
  }

  Map<String, Object?> _build(String spanId, String? parentSpanId, String name, String kind, DateTime startedAt,
          double durationMs, Map<String, Object?>? data) =>
      {
        'span_id': spanId,
        'parent_span_id': parentSpanId,
        'name': name,
        'kind': _kinds.contains(kind) ? kind : 'other',
        'started_at': _timestamp(startedAt),
        'duration_ms': (durationMs * 100).roundToDouble() / 100,
        'environment': _configuration.environment,
        'release': _configuration.release,
        'data': data ?? const <String, Object?>{},
      };

  // ISO 8601 with exactly millisecond precision, UTC: toIso8601String prints microseconds when there
  // are any.
  static String _timestamp(DateTime time) =>
      time.toUtc().toIso8601String().replaceFirstMapped(RegExp(r'\.(\d{3})\d*Z$'), (m) => '.${m[1]}Z');
}
