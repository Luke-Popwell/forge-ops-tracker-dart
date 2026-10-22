import 'package:flutter/foundation.dart';
import 'package:flutter_forge_ops_tracker/flutter_forge_ops_tracker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;

void main() {
  setUp(forge_ops_tracker.resetForTesting);
  tearDown(() {
    // Restore plain defaults so a later test file in the same run isn't left with this test's
    // handlers still installed.
    FlutterError.onError = FlutterError.presentError;
    PlatformDispatcher.instance.onError = null;
    forge_ops_tracker.resetForTesting();
  });

  test('FlutterError.onError reports then chains to the previously-installed handler', () {
    var previousRan = false;
    FlutterErrorDetails? previousDetails;
    FlutterError.onError = (details) {
      previousRan = true;
      previousDetails = details;
    };

    installFlutterErrorHandlers();

    final details = FlutterErrorDetails(exception: Exception('widget build boom'), stack: StackTrace.current, library: 'my_widget');
    FlutterError.onError!(details);

    expect(previousRan, isTrue, reason: 'the previously-installed FlutterError.onError should still have run');
    expect(previousDetails, same(details));
  });

  test('PlatformDispatcher.onError reports then chains to the previously-installed handler and its return value', () {
    var previousRan = false;
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      previousRan = true;
      return true; // "handled": this handler's return value should win over the default false
    };

    installFlutterErrorHandlers();

    final handled = PlatformDispatcher.instance.onError!(Exception('async boom'), StackTrace.current);

    expect(previousRan, isTrue, reason: 'the previously-installed PlatformDispatcher.onError should still have run');
    expect(handled, isTrue, reason: 'the previously-installed handler said handled=true: that should be honored, not overridden to false');
  });

  test('PlatformDispatcher.onError defaults to false (not handled) when there was no previous handler', () {
    PlatformDispatcher.instance.onError = null;

    installFlutterErrorHandlers();

    final handled = PlatformDispatcher.instance.onError!(Exception('async boom'), StackTrace.current);

    expect(handled, isFalse, reason: 'with no previous handler, this should report but still say not handled, the same "don\'t change default behavior" rule as everywhere else in this repo');
  });

  test('installFlutterErrorHandlers does not throw even when forge_ops_tracker has no DSN configured', () {
    installFlutterErrorHandlers();

    // Must not throw: an error handler that itself throws while handling an error is the worst
    // possible failure mode, same invariant every other client in this repo holds to.
    FlutterError.onError!(FlutterErrorDetails(exception: Exception('boom'), stack: StackTrace.current));
    PlatformDispatcher.instance.onError!(Exception('boom'), StackTrace.current);
  });
}
