import 'dart:math';

/// A usable incoming `traceparent` header's two ids: the caller's trace, and the caller's span
/// that this work runs under.
class TraceParentContext {
  const TraceParentContext(this.traceId, this.parentSpanId);

  final String traceId;
  final String parentSpanId;
}

/// Reads and writes the W3C Trace Context `traceparent` header (https://www.w3.org/TR/trace-context/),
/// the vendor-neutral format for carrying one trace across service boundaries:
/// `00-<32 hex trace id>-<16 hex parent span id>-<2 hex flags>`. Mirrors `gems/forge_ops_tracker`'s
/// own `TraceParent`: [parse] lets `trace`/`traceAsync` continue a caller's trace, and [build] is what
/// `httpSpan`/`httpSpanAsync` hand the caller to send to the next service along.
///
/// Strict on the way in, the posture the spec asks receivers to take: a malformed value, uppercase
/// hex, the reserved version `ff`, or an all-zero trace or parent id all mean "no usable header"
/// ([parse] returns null and a fresh trace starts), never half-trusted. A future version is still
/// accepted when its first four fields have version 00's shape; version 00 itself must have exactly
/// four.
class TraceParent {
  TraceParent._();

  /// The header's name.
  static const String header = 'traceparent';

  static final RegExp _pattern = RegExp(r'^([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})(-.*)?$');
  static final String _invalidTraceId = '0' * 32;
  static final String _invalidSpanId = '0' * 16;
  static final Random _random = Random.secure();

  // Always "01" (sampled) on the way out: whether a trace is sent is only decided once it's over (see
  // Configuration.traceCaptureThreshold), long after this header has gone out, so "this may be
  // recorded" is the only honest answer. The next service makes its own decision either way.
  static const String _sampledFlags = '01';

  /// The two ids of a usable header value, or null for anything else (including null).
  static TraceParentContext? parse(String? value) {
    if (value == null) return null;
    final match = _pattern.firstMatch(value.trim());
    if (match == null) return null;
    final version = match[1]!;
    final traceId = match[2]!;
    final parentId = match[3]!;
    if (version == 'ff') return null;
    if (version == '00' && match[5] != null) return null;
    if (traceId == _invalidTraceId || parentId == _invalidSpanId) return null;
    return TraceParentContext(traceId, parentId);
  }

  /// The header value naming [spanId] (the caller's own span) in trace [traceId].
  static String build(String traceId, String spanId) => '00-$traceId-$spanId-$_sampledFlags';

  /// 32 lowercase hex characters, never all zeros (the spec's one invalid value).
  static String generateTraceId() => _nonZeroHex(16);

  /// 16 lowercase hex characters, never all zeros.
  static String generateSpanId() => _nonZeroHex(8);

  // The one all-zero value in 2^64 (or 2^128) is drawn again rather than sent: a receiver discards a
  // header carrying it.
  static String _nonZeroHex(int bytes) {
    while (true) {
      final raw = List.generate(bytes, (_) => _random.nextInt(256));
      if (raw.any((byte) => byte != 0)) {
        return raw.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
      }
    }
  }
}
