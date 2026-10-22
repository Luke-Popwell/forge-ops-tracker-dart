# flutter_forge_ops_tracker

Flutter-specific automatic error capture on top of
[`forge_ops_tracker`](https://pub.dev/packages/forge_ops_tracker), the core Dart client for
[ForgeOps](https://getforgeops.net). A separate package
rather than folded into that one, specifically so a plain Dart (non-Flutter) consumer never has
to pull in the Flutter SDK.

## Installation

```yaml
# pubspec.yaml
dependencies:
  forge_ops_tracker: ^0.17.0
  flutter_forge_ops_tracker: ^0.2.0
```

Or: `flutter pub add forge_ops_tracker flutter_forge_ops_tracker`

## Usage

Call `installFlutterErrorHandlers()` once, after configuring the core client, before `runApp`:

```dart
import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;
import 'package:flutter_forge_ops_tracker/flutter_forge_ops_tracker.dart';

void main() {
  forge_ops_tracker.init((config) {
    config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events';
  });
  installFlutterErrorHandlers();
  runApp(MyApp());
}
```

This wires two Flutter-specific error paths the core client's own `runGuarded` helper doesn't
see on its own:

- **`FlutterError.onError`**: an error the framework itself catches while building, laying out,
  or painting a widget, what would otherwise render Flutter's own red "error" screen in debug
  mode. Chains to whatever handler was already installed rather than replacing it, so that error
  screen still renders exactly as it would without this package.
- **`PlatformDispatcher.onError`**: anything that escapes the root `Zone` instead, an error in an
  async callback, a `Future` whose error was never caught. Reports, then preserves whatever the
  engine's own default behavior would otherwise be, the same "report, don't change program
  behavior" rule the core client's `runGuarded` follows for non-Flutter code.

See the core [`forge_ops_tracker` README](https://pub.dev/packages/forge_ops_tracker) for
configuration options, PII scrubbing, and delivery behavior, all shared with this package since
it's the same client underneath.

### Strict privacy

Strict privacy is a core client setting, so it covers every error this package reports too. Turn it
on in `init` (or with `FORGE_OPS_STRICT_PRIVACY=true`) and errors go out without their message (a
`message_fingerprint` instead), breadcrumbs, SQL statement, source context or the user's email and
username, with only the context and tag keys in `config.privacyAllowedFields`:

```dart
forge_ops_tracker.init((config) {
  config.dsn = '...';
  config.strictPrivacy = true;
  config.privacyAllowedFields = ['error_code'];
});
```

See the core README's "Strict privacy" section for the full list. ForgeOps applies the same rules
again on arrival when the project's own Strict privacy setting is on.

## Running the tests

```bash
cd sdks/dart/flutter_forge_ops_tracker
flutter pub get
flutter test
flutter analyze
```
