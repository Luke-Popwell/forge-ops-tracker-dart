import 'dart:io';

import 'strict_privacy.dart' as strict_privacy;

/// Holds a single ForgeOps DSN plus everything else the client needs to build and deliver
/// events. Mirrors `gems/forge_ops_tracker`'s `Configuration`: a single DSN string
/// carries both the ingestion URL and the project's api_key:
/// `https://<api_key>@host/api/v1/events`.
class Configuration {
  String? dsn = Platform.environment['FORGE_OPS_DSN'];
  /// Starts as [resolveEnvironment] of this process's environment variables: `FORGE_OPS_ENVIRONMENT`,
  /// or `'production'` when it isn't set.
  String environment = resolveEnvironment(Platform.environment);
  String? release = Platform.environment['FORGE_OPS_RELEASE'];
  String? serverName = _safeHostname();

  /// The package name (as it appears in a Dart `StackTrace`'s own `"package:<name>/..."`
  /// locations, e.g. `"my_app"`) used to mark backtrace frames as `in_app`. Unset by default,
  /// meaning every frame reports as not-in-app until you set it: the same safe default the
  /// Rails gem uses when `app_root` is unset, and the Java/Kotlin clients use when
  /// `appPackagePrefix` is unset. A Dart `StackTrace` carries no real filesystem path (see
  /// `EventBuilder`'s own comment), so file-path matching (the Ruby/Python/PHP/Node clients'
  /// approach) isn't possible here: this is this client's equivalent of the JVM clients' own
  /// package-prefix check.
  String? packageName;

  Set<String> enabledEnvironments = {'production', 'staging'};
  int queueSize = 1000;
  Duration timeout = const Duration(seconds: 2);
  bool scrubPii = true;

  /// Whether [EventBuilder] reads a few lines of source off disk around each in-app frame's
  /// culprit line (see `EventBuilder`'s own `_attachSourceContext`). Defaults to `true` so a
  /// snippet shows up with zero extra setup, but this field isn't the durable protection against
  /// literal source code leaving a deployment it shouldn't: ForgeOps' own per-project setting is,
  /// since it applies server-side regardless of what any given app happens to have this field set
  /// to locally. Set to `false` here if this app should never even attempt the disk read in the
  /// first place.
  bool captureSourceContext = true;

  /// When an error carries the SQL behind a failed local database call (`package:sqlite3`'s
  /// `SqliteException`, sqflite's `DatabaseException` text, and anything that wraps one), send the
  /// names of the table and view it touched, so an issue says where to start looking. Names are
  /// identifiers, never values, which is why this defaults on. [captureSqlStatement] is the
  /// separate, opt-in step of also sending the statement itself, with every string and number
  /// replaced by `?`; off by default because even a masked statement describes your schema, and
  /// ForgeOps' own per-project setting is what durably governs whether the server stores it.
  bool captureSqlObjects = true;

  bool captureSqlStatement = false;

  /// Whether [addBreadcrumb] records anything at all. Defaults to `true`, matching every other
  /// client in this repo's own default.
  bool trackBreadcrumbs = true;

  /// How many of the most recent breadcrumbs are kept; older ones are dropped as new ones come
  /// in. 30, matching every other client's own default (see `gems/forge_ops_tracker`'s own
  /// reference default, which this repo's other clients all trace back to).
  int maxBreadcrumbs = 30;

  /// Whether `recordPerformance`/`timeTransaction` time anything at all. On by default, the same
  /// "on unless you turn it off" posture error reporting itself already has. This client has no
  /// web framework integration, so nothing is timed automatically: this only gates the manual API.
  bool trackPerformance = true;

  /// How often the in-process tallies are flushed as one small aggregate report, rather than one
  /// network call per timed call. Matches `gems/forge_ops_tracker`'s own default (60s). Checked
  /// whenever a duration is recorded, not from a timer: see `PerformanceFlusher`'s own comment on
  /// why Dart can't have a background one.
  Duration performanceFlushInterval = const Duration(seconds: 60);

  /// Whether `trace`/`traceAsync` send their trace (when slow) to `/spans`. On by default. With it
  /// off, a `trace` body still has a trace id, attached to errors captured inside it and handed out
  /// by `httpSpan`/`httpSpanAsync` (see [propagateTraces]), since that id is also what links an error
  /// here to one in another service; its spans are just never sent. This client has no web framework
  /// integration, so nothing starts a trace automatically: this only gates the manual API.
  bool trackTracing = true;

  /// Whether `httpSpan`/`httpSpanAsync` hand their body a W3C `traceparent` header
  /// (https://www.w3.org/TR/trace-context/) for the outgoing call, so the service being called
  /// continues this trace instead of starting its own. On by default, matching
  /// `gems/forge_ops_tracker`'s `propagate_traces`. Off still records the `http` span; it only
  /// stops the header.
  bool propagateTraces = true;

  /// Which hosts get that header. `null` (the default) means every host. Otherwise each entry is a
  /// host [String], matching that exact host or any subdomain of it on a dot boundary
  /// (`'example.com'` matches `'api.example.com'` but not `'badexample.com'`; case-insensitive, a
  /// leading dot ignored), or a [RegExp] (any [Pattern]) searched for anywhere in the lowercased
  /// host, so anchor it yourself. Anything else matches nothing. Worth narrowing when the app also
  /// calls third-party APIs that reject unknown headers or shouldn't learn your trace ids.
  List<Object>? tracePropagationTargets;

  /// Whether an outgoing call to [host] should carry a `traceparent` header: see [propagateTraces]
  /// and [tracePropagationTargets]. A call with no host at all only gets one when every host does.
  bool shouldPropagateTrace(String? host) {
    if (!propagateTraces) return false;
    final targets = tracePropagationTargets;
    if (targets == null) return true;
    final normalized = (host ?? '').toLowerCase();
    if (normalized.isEmpty) return false;
    return targets.any((target) {
      if (target is String) {
        final domain = target.toLowerCase().startsWith('.') ? target.substring(1).toLowerCase() : target.toLowerCase();
        return domain.isNotEmpty && (normalized == domain || normalized.endsWith('.$domain'));
      }
      if (target is Pattern) return target.allMatches(normalized).isNotEmpty;
      return false;
    });
  }

  /// How long between flushes of the buffered `captureMetric` / `captureInfrastructureMetric`
  /// entries (see `MetricBuffer`); one flush starts from a capture once this has elapsed, since Dart
  /// has no background timer to flush on. There is no `trackMetrics` flag the way `trackPerformance`
  /// has one: these are explicit calls the host app's own code makes, not automatic instrumentation,
  /// so there is nothing to turn off that simply not calling them doesn't already do.
  Duration metricFlushInterval = const Duration(seconds: 60);
  Duration infrastructureMetricFlushInterval = const Duration(seconds: 60);

  /// A trace is only sent when its root took at least this long. One second, matching every other
  /// client's default.
  Duration traceCaptureThreshold = const Duration(seconds: 1);

  /// Strict privacy, for apps that can't let personal or health data leave this process: every
  /// error event goes out without its message (a `message_fingerprint` instead, so errors still
  /// group), breadcrumbs, SQL statement, source context, or the user's email/username, and with
  /// only the context/tag keys named in [privacyAllowedFields]. Breadcrumbs aren't recorded at all,
  /// `http` spans are named by method and host only, and span data keeps only `db.statement` and
  /// `db.system`. See `strict_privacy.dart`. Off by default; `FORGE_OPS_STRICT_PRIVACY=true` turns
  /// it on, and a value set in `init` wins over the environment. ForgeOps applies the same rules
  /// again on arrival when the project's own Strict privacy setting is on.
  bool strictPrivacy = strict_privacy.envFlag(Platform.environment['FORGE_OPS_STRICT_PRIVACY']);

  /// Context and tag keys strict privacy still sends (only plain string, number or bool values
  /// under these exact top-level keys), e.g. `['error_code', 'feature']`. Defaults to
  /// `FORGE_OPS_PRIVACY_ALLOWED_FIELDS`, comma separated, or none.
  List<String> privacyAllowedFields = strict_privacy.envList(Platform.environment['FORGE_OPS_PRIVACY_ALLOWED_FIELDS']);

  /// Called with a debug-level message on delivery failures; `null` (the default) discards them.
  void Function(String message)? logger;

  // Parses fresh on every call rather than caching: Uri.parse is cheap, and a cache would need
  // to be invalidated every time `dsn` is reassigned, which a plain mutable field (deliberately
  // simple, no custom setter) can't hook into. The Go and Rust clients in this repo make the
  // same "parse fresh, don't cache" choice for the same reason.
  Uri? _parse() {
    final currentDsn = dsn;
    if (currentDsn == null || currentDsn.trim().isEmpty) return null;

    // Uri.parse throws FormatException on genuinely malformed input: a bad DSN is a
    // configuration mistake, not something that should ever crash the host app, same "never
    // throw back into the caller" guarantee as every other client.
    try {
      final uri = Uri.parse(currentDsn);
      return uri.host.isNotEmpty ? uri : null;
    } on FormatException {
      return null;
    }
  }

  /// The DSN's userinfo component, URL-decoded: null if the DSN is unset, malformed, or has no
  /// userinfo.
  String? get apiKey {
    final parsed = _parse();
    if (parsed == null || parsed.userInfo.isEmpty) return null;
    return Uri.decodeComponent(parsed.userInfo);
  }

  /// The ingestion URL with credentials stripped out: they travel as the Authorization header
  /// instead.
  Uri? get ingestionUri {
    final parsed = _parse();
    if (parsed == null) return null;
    return parsed.replace(userInfo: '');
  }

  /// Same derivation as [ingestionUri], with the trailing `/events` swapped for
  /// `/performance_samples`: one DSN, two endpoints, matching the Ruby gem's own
  /// `Configuration#performance_samples_uri`.
  Uri? get performanceSamplesUri {
    final uri = ingestionUri;
    if (uri == null) return null;
    if (!uri.path.endsWith('/events')) return uri;
    return uri.replace(path: '${uri.path.substring(0, uri.path.length - '/events'.length)}/performance_samples');
  }

  /// Same derivation again, swapping the trailing `/events` for `/custom_metrics`.
  Uri? get customMetricsUri => _swapEventsSuffix('/custom_metrics');

  /// Same derivation again, swapping the trailing `/events` for `/infrastructure_metrics`.
  Uri? get infrastructureMetricsUri => _swapEventsSuffix('/infrastructure_metrics');

  /// Same derivation again, swapping the trailing `/events` for `/changes` (see `recordChange`).
  Uri? get changesUri => _swapEventsSuffix('/changes');

  Uri? _swapEventsSuffix(String replacement) {
    final uri = ingestionUri;
    if (uri == null) return null;
    if (!uri.path.endsWith('/events')) return uri;
    return uri.replace(path: '${uri.path.substring(0, uri.path.length - '/events'.length)}$replacement');
  }

  /// Same derivation again, swapping the trailing `/events` for `/spans`.
  Uri? get spansUri {
    final uri = ingestionUri;
    if (uri == null) return null;
    if (!uri.path.endsWith('/events')) return uri;
    return uri.replace(path: '${uri.path.substring(0, uri.path.length - '/events'.length)}/spans');
  }

  /// The environment a new [Configuration] starts with: `FORGE_OPS_ENVIRONMENT` when set (and not
  /// blank), otherwise `'production'`, so an app that sets nothing but a DSN still sends its errors.
  /// Dart has no standard "which environment is this" variable the way Node has `NODE_ENV`, so
  /// there's no second variable to fall back on.
  static String resolveEnvironment(Map<String, String> env) {
    final value = env['FORGE_OPS_ENVIRONMENT']?.trim();
    return value != null && value.isNotEmpty ? value : 'production';
  }

  /// The one-line warning `init` prints when a DSN is configured but [environment] isn't one of
  /// [enabledEnvironments], so nothing would be sent; `null` when there's nothing to warn about (no
  /// DSN, or the environment is enabled).
  String? get disabledEnvironmentWarning {
    if (!(dsn?.trim().isNotEmpty ?? false) || apiKey == null || enabledEnvironments.contains(environment)) {
      return null;
    }
    final verb = enabledEnvironments.length == 1 ? 'is' : 'are';
    return '[ForgeOps] Not sending: this environment is "$environment", and only '
        '${enabledEnvironments.join(', ')} $verb enabled. Set FORGE_OPS_ENVIRONMENT=production '
        '(or add "$environment" to the enabled environments) to send from here.';
  }

  bool get isEnabled =>
      (dsn?.trim().isNotEmpty ?? false) && apiKey != null && enabledEnvironments.contains(environment);

  void log(String message) {
    logger?.call('[ForgeOpsTracker] $message');
  }

  static String? _safeHostname() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return null;
    }
  }
}
