import 'dart:async' show unawaited;
import 'dart:collection' show Queue;

import 'client.dart';
import 'configuration.dart';

/// A small in-process bounded queue drained by a single async loop, so delivery never blocks the
/// call site that caught the error. Dart has no OS threads the way Ruby/Python/JVM clients in
/// this repo do: concurrency here is cooperative, single-threaded scheduling via the event loop,
/// so "background worker" means "an async function that isn't awaited," not a separate thread.
/// That single-threaded model is also what makes this safe without any explicit locking: [push]
/// is fully synchronous, and Dart never runs two pieces of code truly in parallel, so there's no
/// race between a [push] call and [_drain]'s own queue access the way a multi-threaded client
/// needs a lock to prevent.
///
/// The drain loop is started lazily, on first [push], same as every other client in this repo
/// with a background delivery worker: there's no reason to start one for a host app that never
/// actually reports anything.
class DeliveryQueue {
  /// [deliver] picks which endpoint a payload goes to; the default is the ingestion endpoint (an
  /// error event). The tracing queue passes `(client, trace) => client.deliverSpans(trace)`.
  DeliveryQueue(this._configuration, {Client? client, Future<bool> Function(Client, Map<String, Object?>)? deliver})
      : _client = client ?? Client(_configuration),
        _deliver = deliver ?? ((client, payload) => client.deliver(payload));

  final Configuration _configuration;
  final Client _client;
  final Future<bool> Function(Client, Map<String, Object?>) _deliver;
  final Queue<Map<String, Object?>> _queue = Queue();
  bool _draining = false;
  Future<void> _drainFuture = Future<void>.value();

  /// Enqueues a payload, dropping it (and returning false) if the queue is already full rather
  /// than blocking the caller.
  bool push(Map<String, Object?> payload) {
    if (_queue.length >= _configuration.queueSize) {
      _configuration.log('delivery queue full, dropping event');
      return false;
    }
    _queue.add(payload);
    _ensureDraining();
    return true;
  }

  void _ensureDraining() {
    if (_draining) return;
    _draining = true;
    _drainFuture = _drain();
    unawaited(_drainFuture);
  }

  Future<void> _drain() async {
    while (_queue.isNotEmpty) {
      final payload = _queue.removeFirst();
      try {
        await _deliver(_client, payload);
      } catch (e) {
        // Per-item, not wrapping the whole loop: one bad delivery must not kill the worker for
        // every event after it. Client.deliver already turns every failure mode of its own into
        // a plain false return rather than throwing; this is a second, redundant layer of safety
        // around it.
        _configuration.log('delivery worker error: ${e.runtimeType}: $e');
      }
    }
    _draining = false;
  }

  /// Completes once everything queued so far has been delivered (or has failed). A Dart program that
  /// exits right after finishing a slow trace should await this first: delivery runs on the event
  /// loop, not a thread, so a process that ends does not wait for it.
  Future<void> flush() async {
    while (_draining) {
      await _drainFuture;
    }
  }
}
