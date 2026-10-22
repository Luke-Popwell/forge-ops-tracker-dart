# Changelog

## 0.2.1

- The `forge_ops_tracker` dependency is now the range `>=0.7.1 <1.0.0` instead of `^0.7.1`. For a
  0.x version a caret allows only the same minor, so the caret would have stopped picking up the base
  package at its next minor release. No code changes.

## 0.2.0

- Now depends on `forge_ops_tracker` `^0.7.1`. The previous `^0.1.0` meant something narrower than it
  looks: for a 0.x version a caret allows only the same minor, so it kept resolving to the very old
  0.1.x release and never picked up any of the fixes and features since. No code changes.
- Documentation: the README and package description describe ForgeOps as a hosted service and link to
  getforgeops.net.

## 0.1.0

- Initial release: `FlutterError.onError` and `PlatformDispatcher.instance.onError` report
  uncaught Flutter/Dart errors automatically, on top of `package:forge_ops_tracker`'s own
  delivery. A separate package specifically so a plain Dart (non-Flutter) consumer of that base
  package never has to pull in the Flutter SDK.
