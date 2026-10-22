/// Dart error reporting client for ForgeOps:
///
///     import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;
///
///     void main() {
///       forge_ops_tracker.init((config) {
///         config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events';
///       });
///       forge_ops_tracker.runGuarded(() {
///         // your app
///       });
///     }
///
/// See the README for what gets captured automatically vs. what needs an explicit
/// [captureException] call.
library;

export 'src/client.dart' show Client, DeliveryStatus;
export 'src/configuration.dart' show Configuration;
export 'src/delivery_queue.dart' show DeliveryQueue;
export 'src/event_builder.dart' show EventBuilder;
export 'src/forge_ops_tracker_base.dart';
export 'src/performance_flusher.dart' show PerformanceFlusher;
export 'src/pii_scrubber.dart' show redacted, scrub, scrubString;
export 'src/reporter.dart' show Reporter;
export 'src/trace_parent.dart' show TraceParent, TraceParentContext;
