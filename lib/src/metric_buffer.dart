import 'dart:async' show unawaited;

import 'client.dart';
import 'configuration.dart';

/// Collects individual `captureMetric`/`captureInfrastructureMetric` calls in-process and
/// periodically flushes them as one batch, rather than one network call per capture. Unlike
/// `PerformanceFlusher` this keeps a *list* of individually meaningful entries instead of summing
/// them into buckets: a customer's own purchase or level completion is exactly the kind of thing
/// they will want a genuinely accurate count/sum of later, so the server stores one row per entry
/// as-is. Ported from `gems/forge_ops_tracker`'s `metric_buffer.rb` and
/// `infrastructure_metric_buffer.rb`, which are the same class twice; here it is one class
/// instantiated twice, told which delivery function and flush interval to use.
///
/// Three deliberate differences from the Ruby buffers:
///
/// - A flush snapshots the first N entries and, on success, removes exactly those N, instead of
///   resetting the whole list, so an entry recorded while the request is in flight (a flush awaits the
///   network, so [record] calls really do interleave with it) is kept for the next flush rather than
///   lost.
/// - The buffer is capped at [maxEntries], and once full further entries are dropped until a flush
///   empties it: an endpoint that is down fails every flush, and an uncapped buffer would keep growing
///   until the batch is given up on. Dropping the newest rather than the oldest keeps the entries
///   a flush is delivering at the front of the list, which is what makes removing exactly them
///   afterward exact.
/// - A NaN or infinite value is dropped at record time: `jsonEncode` throws on one, and one bad entry
///   would make every batch behind it fail to send.
///
/// **No background timer, deliberately**, for the reason `PerformanceFlusher` documents: a pending
/// `Timer` would stop a plain Dart CLI program from ever exiting on its own. Instead [record] starts a
/// flush itself once a full interval has elapsed since the last one, and a program about to stop should
/// `await flushMetrics()` (see README.md).
class MetricBuffer {
  MetricBuffer(this._configuration, this._deliver, this._interval);

  static const int maxEntries = 1000;

  final Configuration _configuration;
  final Future<DeliveryStatus> Function(List<Map<String, Object?>> entries) _deliver;
  final Duration Function() _interval;
  final List<Map<String, Object?>> _entries = [];
  DateTime _lastFlushAt = DateTime.now().toUtc();
  bool _flushing = false;
  int _failedFlushes = 0;

  int get length => _entries.length;

  /// Adds one entry (everything but `recorded_at`, which is stamped here); returns whether it was kept.
  bool record(Map<String, Object?> entry) {
    final value = entry['value'];
    if (value is! num || value.isNaN || value.isInfinite) {
      _configuration.log('dropped a metric with a non-numeric or non-finite value');
      return false;
    }
    if (_entries.length >= maxEntries) {
      _configuration.log('metric buffer full, dropping a metric');
      return false;
    }

    final now = DateTime.now().toUtc();
    _entries.add({...entry, 'recorded_at': _timestamp(now)});

    if (!_flushing && now.difference(_lastFlushAt) >= _interval()) {
      unawaited(flush());
    }
    return true;
  }

  /// Delivers everything buffered so far as one batch. A failed delivery keeps every entry, so the
  /// next flush's batch just grows, until [maxFailedFlushes] flushes in a row have failed: that one
  /// drops the batch. A batch the server rejects (a plan without the feature answers 403) is dropped
  /// at once, since it would be refused again every time. At most one flush runs at a time.
  Future<void> flush() async {
    if (_flushing || _entries.isEmpty) return;
    _flushing = true;
    _lastFlushAt = DateTime.now().toUtc();
    try {
      final snapshot = List<Map<String, Object?>>.of(_entries);
      final status = await _deliver(snapshot);
      if (status == DeliveryStatus.failed && ++_failedFlushes < maxFailedFlushes) return;
      _failedFlushes = 0;
      if (status != DeliveryStatus.delivered) {
        final reason =
            status == DeliveryStatus.failed ? '$maxFailedFlushes flushes in a row failed' : 'the server rejected them';
        _configuration.log('dropping ${snapshot.length} metric(s): $reason');
      }

      // Exactly the entries just delivered or dropped: anything recorded while the request was in flight sits
      // after them and stays for the next flush.
      _entries.removeRange(0, snapshot.length);
    } finally {
      _flushing = false;
    }
  }

  /// Drops every entry without delivering anything.
  void discard() {
    _entries.clear();
    _failedFlushes = 0;
  }

  static String _timestamp(DateTime time) => '${time.toIso8601String().split('.').first}Z';
}
