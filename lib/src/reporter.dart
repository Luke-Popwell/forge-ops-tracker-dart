import 'configuration.dart';
import 'delivery_queue.dart';
import 'event_builder.dart';

/// Orchestrates one capture: enabled check, build, enqueue. An error reporter that itself throws
/// while reporting an error is the worst possible failure mode, so every path here is wrapped to
/// guarantee this never propagates back into the caller: the same guarantee every other client
/// in this repo makes in its own equivalent class.
class Reporter {
  Reporter(this._configuration, {EventBuilder? eventBuilder, DeliveryQueue? deliveryQueue})
      : _eventBuilder = eventBuilder ?? EventBuilder(_configuration),
        _deliveryQueue = deliveryQueue ?? DeliveryQueue(_configuration);

  final Configuration _configuration;
  final EventBuilder _eventBuilder;
  final DeliveryQueue _deliveryQueue;

  /// Completes once every event reported so far has been delivered (or has failed). See
  /// `DeliveryQueue.flush`.
  Future<void> flush() => _deliveryQueue.flush();

  void report(
    Object? error,
    StackTrace? stackTrace, {
    Map<String, Object?>? context,
    Map<String, Object?>? user,
    List<Map<String, Object?>>? breadcrumbs,
    String? traceId,
  }) {
    try {
      if (!_configuration.isEnabled || error == null) return;
      _deliveryQueue
          .push(_eventBuilder.build(error, stackTrace,
          context: context, user: user, breadcrumbs: breadcrumbs, traceId: traceId));
    } catch (e) {
      _configuration.log('report failed: ${e.runtimeType}: $e');
    }
  }
}
