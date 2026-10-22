import 'dart:async' show unawaited;

import 'client.dart';
import 'configuration.dart';
import 'histogram_bucketer.dart';
import 'strict_privacy.dart' as strict_privacy;

class _Bucket {
  int count = 0;
  double durationSumMs = 0;
  double maxDurationMs = 0;
  final Map<String, int> histogram = {};
}

/// Times work in-process, bucketed by transaction name (see `timeTransaction` in
/// `forge_ops_tracker_base.dart`), and periodically flushes each distinct bucket as one small
/// aggregate report, rather than one network call per timed call. Ported from
/// `gems/forge_ops_tracker/lib/forge_ops_tracker/performance_flusher.rb` and `sdks/go`'s own port
/// of it, including the one thing both of those learned the hard way: see [flush]'s own comment on
/// why it subtracts what it delivered instead of clearing the buckets.
///
/// **No background timer, deliberately.** Every other client in this repo flushes from a daemon
/// thread or goroutine that never keeps its process alive. Dart has no such thing: a pending
/// [Timer] keeps the isolate's event loop running, so a timer here would stop a plain Dart CLI
/// program from ever exiting on its own (for up to a full flush interval after the last timed call).
/// Instead, [record] checks whether a full flush interval has elapsed since the last flush and, if
/// so, starts one itself (after a flush that failed, since that attempt, so an endpoint that is down
/// is tried once per interval, not on every call); nothing else is ever scheduled. The cost is that a window with no further
/// [record] call after it sits unsent until the next one (or an explicit [flush]): for a long-lived
/// server that's a non-issue, and a Flutter app or CLI about to stop should call `flushPerformance`
/// itself (see README.md).
///
/// Single-threaded, so no locking: [record] and the bookkeeping in [flush] never run in parallel.
/// But [flush] awaits a network call in the middle, so [record] calls do interleave with it, which
/// is exactly the race the subtraction below exists for.
class PerformanceFlusher {
  PerformanceFlusher(this._configuration, {Client? client}) : _client = client ?? Client(_configuration);

  final Configuration _configuration;
  final Client _client;
  final Map<String, _Bucket> _buckets = {};
  DateTime _periodStartedAt = DateTime.now().toUtc();
  DateTime _lastFlushAt = DateTime.now().toUtc();
  bool _flushing = false;
  int _failedFlushes = 0;

  /// Buckets one timed call's duration under [transactionName]. Does nothing when
  /// [Configuration.trackPerformance] is off or reporting isn't enabled for this environment:
  /// nothing would ever be sent, so there's nothing worth tallying.
  void record(String transactionName, double durationMs) {
    if (!_configuration.trackPerformance || !_configuration.isEnabled) return;

    // Strict privacy: a raw path loses its ids, a route is kept (see strict_privacy.dart).
    final name = _configuration.strictPrivacy ? strict_privacy.spanName(transactionName) : transactionName;
    final bucket = _buckets.putIfAbsent(name, _Bucket.new);
    bucket.count++;
    bucket.durationSumMs += durationMs;
    if (durationMs > bucket.maxDurationMs) bucket.maxDurationMs = durationMs;
    // The distribution count/sum/max can't reconstruct: see histogram_bucketer.dart for why the
    // server approximates a percentile from these bucket counts.
    bucket.histogram.update(bucketFor(durationMs), (count) => count + 1, ifAbsent: () => 1);

    if (!_flushing && DateTime.now().toUtc().difference(_lastFlushAt) >= _configuration.performanceFlushInterval) {
      unawaited(flush());
    }
  }

  /// Snapshots the buffered buckets and delivers them as one batch. A failed delivery keeps every
  /// bucket where it is, so the next flush's batch just grows instead of losing what was already
  /// tallied: there's no other copy of this data anywhere. That holds for [maxFailedFlushes] flushes
  /// in a row; the last of them drops the batch instead. A batch the server rejects (see
  /// [DeliveryStatus]) is dropped at once: it would be refused again every time.
  ///
  /// Only exactly what this snapshot delivered (or dropped) is removed afterward, subtracted from whatever is
  /// in each bucket by then, never the map cleared outright. [record] keeps running while this
  /// awaits the network, so a [record] call for a transaction already in the snapshot, or a
  /// brand-new one, can land in the exact window between the snapshot and delivery succeeding.
  /// Clearing the map afterward, as if delivery had covered everything now in it, would silently
  /// discard that concurrently-recorded data forever. This is a real bug `sdks/go` had and fixed
  /// (confirmed there by a deterministic test, not assumed), and that `gems/forge_ops_tracker`'s
  /// reference implementation still has, unfixed; see this package's own test for the same
  /// deterministic reproduction.
  ///
  /// A second call while one is already in flight does nothing, rather than delivering the same
  /// snapshot twice.
  Future<void> flush() async {
    if (_flushing || _buckets.isEmpty) return;
    _flushing = true;
    try {
      final periodEndedAt = DateTime.now().toUtc();
      _lastFlushAt = periodEndedAt;
      final delivered = {
        for (final entry in _buckets.entries)
          entry.key: (
            count: entry.value.count,
            durationSumMs: entry.value.durationSumMs,
            maxDurationMs: entry.value.maxDurationMs,
            histogram: Map<String, int>.of(entry.value.histogram),
          ),
      };
      final samples = [
        for (final entry in delivered.entries)
          {
            'transaction_name': entry.key,
            'environment': _configuration.environment,
            'release': _configuration.release,
            'period_started_at': _timestamp(_periodStartedAt),
            'period_ended_at': _timestamp(periodEndedAt),
            'request_count': entry.value.count,
            'duration_sum_ms': entry.value.durationSumMs,
            'max_duration_ms': entry.value.maxDurationMs,
            'histogram': entry.value.histogram,
          },
      ];

      final status = await _client.sendPerformanceSamples(samples);
      if (status == DeliveryStatus.failed && ++_failedFlushes < maxFailedFlushes) return;
      _failedFlushes = 0;
      if (status != DeliveryStatus.delivered) {
        final reason =
            status == DeliveryStatus.failed ? '$maxFailedFlushes flushes in a row failed' : 'the server rejected them';
        _configuration.log('dropping ${samples.length} performance sample(s): $reason');
      }

      for (final entry in delivered.entries) {
        final current = _buckets[entry.key];
        if (current == null) continue;
        current.count -= entry.value.count;
        current.durationSumMs =
            (current.durationSumMs - entry.value.durationSumMs).clamp(0, double.infinity).toDouble();
        entry.value.histogram.forEach((label, count) {
          final remaining = (current.histogram[label] ?? 0) - count;
          if (remaining > 0) {
            current.histogram[label] = remaining;
          } else {
            current.histogram.remove(label);
          }
        });
        if (current.count <= 0) _buckets.remove(entry.key);
        // maxDurationMs is deliberately left as whatever is currently on the bucket, sent or not:
        // unlike count/durationSumMs, a max can't be correctly "subtracted" back out (the true max
        // of what's left is anything at or below it, not knowable from the two numbers alone), and
        // leaving it never overstates the next period's own max, only potentially understates how
        // far back it was actually set.
      }
      _periodStartedAt = periodEndedAt;
    } catch (e) {
      _configuration.log('performance flush error: ${e.runtimeType}: $e');
    } finally {
      _flushing = false;
    }
  }

  /// Test-only: `(count, durationSumMs, maxDurationMs)` per transaction, as currently tallied.
  Map<String, (int, double, double)> get tallies => {
        for (final entry in _buckets.entries)
          entry.key: (entry.value.count, entry.value.durationSumMs, entry.value.maxDurationMs),
      };

  static String _timestamp(DateTime time) => time.toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
}
