import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('Configuration', () {
    test('defaults', () {
      final config = Configuration();
      expect(config.queueSize, 1000);
      expect(config.timeout, const Duration(seconds: 2));
      expect(config.scrubPii, isTrue);
      expect(config.enabledEnvironments, containsAll(['production', 'staging']));
    });

    test('resolveEnvironment uses FORGE_OPS_ENVIRONMENT, else production', () {
      expect(Configuration.resolveEnvironment({'FORGE_OPS_ENVIRONMENT': 'staging'}), 'staging');
      expect(Configuration.resolveEnvironment({'FORGE_OPS_ENVIRONMENT': 'development'}), 'development');
      expect(Configuration.resolveEnvironment({}), 'production');
      expect(Configuration.resolveEnvironment({'FORGE_OPS_ENVIRONMENT': '  '}), 'production');
    });

    test('disabledEnvironmentWarning names the environment and the enabled ones when a DSN is set', () {
      final config = Configuration()
        ..dsn = 'https://abc123@forgeops.example/api/v1/events'
        ..environment = 'development'
        ..enabledEnvironments = {'production', 'staging'};

      expect(
        config.disabledEnvironmentWarning,
        '[ForgeOps] Not sending: this environment is "development", and only production, staging are enabled. '
        'Set FORGE_OPS_ENVIRONMENT=production (or add "development" to the enabled environments) to send from here.',
      );
    });

    test('disabledEnvironmentWarning is null without a DSN, or when the environment is enabled', () {
      final config = Configuration()
        ..dsn = null
        ..environment = 'development';
      expect(config.disabledEnvironmentWarning, isNull);

      config
        ..dsn = 'https://abc123@forgeops.example/api/v1/events'
        ..environment = 'staging';
      expect(config.disabledEnvironmentWarning, isNull);
    });

    test('apiKey and ingestionUri', () {
      final config = Configuration()..dsn = 'https://abc123@forgeops.example/api/v1/events';

      expect(config.apiKey, 'abc123');
      expect(config.ingestionUri.toString(), 'https://forgeops.example/api/v1/events');
    });

    test('apiKey url-decodes the userinfo', () {
      final config = Configuration()..dsn = 'https://ab%2Fc@forgeops.example/api/v1/events';

      expect(config.apiKey, 'ab/c');
    });

    test('empty or malformed dsn has no apiKey or ingestionUri', () {
      for (final dsn in ['', 'not a url']) {
        final config = Configuration()..dsn = dsn;
        expect(config.apiKey, isNull, reason: 'dsn = $dsn');
        expect(config.ingestionUri, isNull, reason: 'dsn = $dsn');
      }
    });

    test('dsn with no userinfo has no apiKey but still has an ingestionUri', () {
      final config = Configuration()..dsn = 'https://forgeops.example/no-userinfo';

      expect(config.apiKey, isNull);
      expect(config.ingestionUri.toString(), 'https://forgeops.example/no-userinfo');
    });

    test('reassigning dsn is reflected immediately, not cached from the first read', () {
      final config = Configuration()..dsn = 'https://first@forgeops.example/events';
      expect(config.apiKey, 'first');

      config.dsn = 'https://second@forgeops.example/events';
      expect(config.apiKey, 'second');
    });

    test('isEnabled requires dsn, apiKey, and an enabled environment', () {
      final config = Configuration()..dsn = 'https://key@host/path';

      config.environment = 'production';
      expect(config.isEnabled, isTrue);

      config.environment = 'development';
      expect(config.isEnabled, isFalse);

      config.environment = 'production';
      config.dsn = null;
      expect(config.isEnabled, isFalse);
    });

    test('log calls the configured logger with a prefix', () {
      final config = Configuration();
      String? received;
      config.logger = (message) => received = message;

      config.log('something happened');

      expect(received, '[ForgeOpsTracker] something happened');
    });

    test('log does nothing when no logger is configured', () {
      Configuration().log('should not throw');
    });
  });
}
