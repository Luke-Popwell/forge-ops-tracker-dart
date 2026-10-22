/// Flutter-specific automatic error capture on top of `package:forge_ops_tracker`. A separate
/// package rather than folded into that one, specifically so a plain Dart (non-Flutter) consumer
/// never has to pull in the Flutter SDK: the same "distinct enough to earn its own package"
/// reasoning behind Go's Gin integration living in its own nested module elsewhere in this repo.
library;

import 'package:flutter/foundation.dart';
import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;

/// Installs both Flutter-specific automatic capture hooks. Call once, after
/// `forge_ops_tracker.init(...)`, before `runApp(...)`:
///
///     void main() {
///       forge_ops_tracker.init((config) {
///         config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events';
///       });
///       installFlutterErrorHandlers();
///       runApp(MyApp());
///     }
///
/// Covers two genuinely different Flutter error paths, both with zero further wiring needed:
///
/// - **[FlutterError.onError]**: fires for an error the framework itself catches while building,
///   laying out, or painting a widget: what would otherwise render Flutter's own red "error"
///   screen in debug mode (or a gray screen in release). Chains to whatever handler was already
///   installed (Flutter's own default, which prints a formatted error to the console, unless
///   something else already replaced it) rather than replacing it: the error screen still
///   renders exactly as it would without this package installed.
/// - **[PlatformDispatcher.onError]**: fires for anything that escapes the root [Zone] instead:
///   an error in an async callback, a `Future` whose error was never caught, anything
///   `FlutterError.onError` doesn't see because it never went through a widget build. Returning
///   `false` (this handler's own return value, unless a previously-installed handler said
///   otherwise) tells the engine "not handled," which is what lets its own default
///   printed-to-stderr behavior still happen: the same "report, then don't change program
///   behavior" rule the plain Dart `runGuarded` helper follows for non-Flutter code.
void installFlutterErrorHandlers() {
  final previousFlutterOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    forge_ops_tracker.captureException(
      details.exception,
      details.stack,
      {
        if (details.library != null) 'library': details.library!,
        if (details.context != null) 'context': details.context.toString(),
      },
    );
    if (previousFlutterOnError != null) {
      previousFlutterOnError(details);
    } else {
      FlutterError.presentError(details);
    }
  };

  final previousPlatformOnError = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    forge_ops_tracker.captureException(error, stackTrace);
    return previousPlatformOnError?.call(error, stackTrace) ?? false;
  };
}
