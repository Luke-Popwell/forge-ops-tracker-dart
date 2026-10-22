// Run as a child process by test/strict_privacy_test.dart, with FORGE_OPS_STRICT_PRIVACY and
// FORGE_OPS_PRIVACY_ALLOWED_FIELDS set: prints the defaults a new Configuration read from them.
import 'package:forge_ops_tracker/forge_ops_tracker.dart';

void main() {
  final config = Configuration();
  print('${config.strictPrivacy} ${config.privacyAllowedFields}');
}
