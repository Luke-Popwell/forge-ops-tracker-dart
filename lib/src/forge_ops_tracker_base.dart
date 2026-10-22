import 'dart:async';
import 'dart:io' show stderr;

import 'configuration.dart';
import 'client.dart';
import 'delivery_queue.dart';
import 'metric_buffer.dart';
import 'performance_flusher.dart';
import 'reporter.dart';
import 'span_buffer.dart';
import 'strict_privacy.dart' as strict_privacy;
import 'trace_parent.dart';

Configuration? _configuration;

// Whether init has already printed Configuration.disabledEnvironmentWarning: once per process.
bool _disabledEnvironmentWarned = false;
Reporter? _reporter;
PerformanceFlusher? _performanceFlusher;
DeliveryQueue? _spanQueue;
DeliveryQueue? _changeQueue;
MetricBuffer? _metricBuffer;
MetricBuffer? _infrastructureMetricBuffer;

// The Zone key `runWithUser` stores its value under, and the box type it stores there. A plain
// `Map<String, Object?>?` value directly under the key can't tell "never called `runWithUser` in
// this call chain" apart from "called `runWithUser(null, ...)` in this call chain": both read
// back as `null` from `Zone.current[key]`. Boxing the value (even a null one) inside `_UserBox`
// makes that distinction a type check instead: a chain that never entered `runWithUser` finds no
// `_UserBox` at all and falls through to [_globalCurrentUser]; a chain that did, honors exactly
// what it was given, `null` included, with no such fallback.
final Object _userZoneKey = #forgeOpsTrackerCurrentUser;

class _UserBox {
  const _UserBox(this.value);
  final Map<String, Object?>? value;
}

// See `setUser`'s own doc comment for why this exists alongside `runWithUser` rather than being
// the only mechanism.
Map<String, Object?>? _globalCurrentUser;

Map<String, Object?>? _normalizeUser(Map<String, Object?>? user) => (user == null || user.isEmpty) ? null : user;

Map<String, Object?>? _currentUser() {
  final boxed = Zone.current[_userZoneKey];
  if (boxed is _UserBox) return boxed.value;
  return _globalCurrentUser;
}

// Same Zone-key/box shape as `_userZoneKey`/`_UserBox` above, for the identical reason: a Dart
// server handling more than one request at a time on the same isolate needs each request's own
// isolated trail, not one shared globally. The box here holds a reference to a mutable, growable
// `List` rather than a fixed value, since a breadcrumb trail accumulates over a call chain's own
// lifetime rather than being set once: `addBreadcrumb`/`clearBreadcrumbs` mutate whichever list
// [_currentBreadcrumbTrail] resolves to, in place.
final Object _breadcrumbZoneKey = #forgeOpsTrackerBreadcrumbs;

class _BreadcrumbBox {
  const _BreadcrumbBox(this.list);
  final List<Map<String, Object?>> list;
}

// See `setUser`'s own doc comment for why this exists alongside `runWithBreadcrumbs` rather than
// being the only mechanism.
final List<Map<String, Object?>> _globalBreadcrumbs = <Map<String, Object?>>[];

List<Map<String, Object?>> _currentBreadcrumbTrail() {
  final boxed = Zone.current[_breadcrumbZoneKey];
  if (boxed is _BreadcrumbBox) return boxed.list;
  return _globalBreadcrumbs;
}

/// The shared [Configuration] instance, created on first access.
Configuration configuration() => _configuration ??= Configuration();

Reporter _sharedReporter() => _reporter ??= Reporter(configuration());

// The two metric buffers, created together on first use: independent of each other (a program may
// only ever call one), but cheap enough that creating both is simpler than tracking which.
(MetricBuffer, MetricBuffer) _sharedMetricBuffers() {
  if (_metricBuffer == null) {
    final config = configuration();
    final client = Client(config);
    _metricBuffer = MetricBuffer(config, client.sendMetrics, () => config.metricFlushInterval);
    _infrastructureMetricBuffer =
        MetricBuffer(config, client.sendInfrastructureMetrics, () => config.infrastructureMetricFlushInterval);
  }
  return (_metricBuffer!, _infrastructureMetricBuffer!);
}

DeliveryQueue _sharedSpanQueue() =>
    _spanQueue ??= DeliveryQueue(configuration(), deliver: (client, trace) => client.deliverSpans(trace));

DeliveryQueue _sharedChangeQueue() =>
    _changeQueue ??= DeliveryQueue(configuration(), deliver: (client, change) => client.deliverChange(change));

PerformanceFlusher _sharedPerformanceFlusher() => _performanceFlusher ??= PerformanceFlusher(configuration());

/// Configures the client. Call once at startup. Pass a closure to set any [Configuration] field:
///
///     init((config) {
///       config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events';
///       config.environment = 'production';
///     });
Configuration init([void Function(Configuration config)? configure]) {
  final config = configuration();
  configure?.call(config);
  _warnIfEnvironmentDisabled(config);
  _reporter = Reporter(config);
  _performanceFlusher = PerformanceFlusher(config);
  _spanQueue = null;
  _changeQueue = null;
  _metricBuffer = null;
  _infrastructureMetricBuffer = null;
  return config;
}

// A DSN with an environment that isn't enabled sends nothing, which would otherwise be silent: say
// so once, through config.logger when one is set, else on stderr. No DSN, no warning, since that's
// a deliberate "off".
void _warnIfEnvironmentDisabled(Configuration config) {
  final warning = config.disabledEnvironmentWarning;
  if (warning == null || _disabledEnvironmentWarned) return;
  _disabledEnvironmentWarned = true;
  final logger = config.logger;
  try {
    if (logger != null) {
      logger(warning);
    } else {
      stderr.writeln(warning);
    }
  } catch (_) {
    // A broken logger or a closed stderr is never a reason for init to throw.
  }
}

/// Reports an error you've already caught. Call it right at the point you'd otherwise just log
/// it:
///
///     try {
///       chargeCard(order);
///     } catch (error, stackTrace) {
///       captureException(error, stackTrace, context: {'order_id': order.id});
///     }
///
/// `user` defaults to whatever `setUser`/`runWithUser` last established for this call chain, if
/// anything; pass one explicitly to override that for this one report.
///
/// Inside a [trace]/[traceAsync] (including across `await`s), the event also carries that trace's
/// `trace_id` (see [currentTraceId]), which links it to an error the backend reported for a request
/// sent with [httpSpan]/[httpSpanAsync]. So does an error that escaped a trace's body and is captured
/// afterward (by [runGuarded], say): the trace it escaped is remembered on the error itself. Outside
/// a trace the event is exactly what it was before.
void captureException(Object error,
    [StackTrace? stackTrace, Map<String, Object?>? context, Map<String, Object?>? user]) {
  _sharedReporter().report(
    error,
    stackTrace ?? StackTrace.current,
    context: context,
    user: user ?? _currentUser(),
    breadcrumbs: _currentBreadcrumbTrail(),
    traceId: _escapedTraceId(error) ?? currentTraceId(),
  );
}

/// Manually attaches an affected user to every subsequently reported error in this isolate (an
/// explicit [captureException] call with no `user` argument, or anything [runGuarded] catches),
/// until changed or cleared. `id`/`email`/`username` are all independently optional; call with
/// `null` (or an empty map) to clear whatever was set.
///
/// A plain, single global value: correct for a Flutter or CLI app, which is effectively
/// single-user the same way `sdks/swift`/`sdks/android`'s own plain static property is (there's
/// no concurrent, unrelated request to leak into), but shared across every concurrently in-flight
/// call if this isolate is also handling more than one request at once (a Dart server): use
/// [runWithUser] there instead, the same "an ambient value needs to be scoped to one call chain,
/// not shared process-wide" reasoning `sdks/node`'s own `runWithUser` documents for Node's
/// `AsyncLocalStorage`. [runWithUser] always wins over this global when both are in play.
void setUser(Map<String, Object?>? user) {
  _globalCurrentUser = _normalizeUser(user);
}

/// Runs [body] with [user] attached to every error [body] (or anything it calls, including across
/// `await`s and inside a `Timer`/microtask it schedules) reports without an explicit `user`
/// argument: the concurrency-safe alternative to [setUser] for a Dart server handling more than
/// one request at a time on the same isolate, e.g. wrapping a single request's handling:
///
///     runWithUser({'id': currentUser.id}, () => handleRequest(request));
///
/// Scoped via Dart's own [Zone] mechanism (the same continuation-local-storage idea Node's
/// `AsyncLocalStorage` is built on): only code that actually runs inside [body]'s own call chain
/// sees this value, unlike [setUser], which is visible from anywhere in the isolate. Pass `null`
/// to explicitly run [body] with no user, overriding an outer [runWithUser] (or [setUser]) for
/// just that scope.
T runWithUser<T>(Map<String, Object?>? user, T Function() body) {
  return runZoned(body, zoneValues: {_userZoneKey: _UserBox(_normalizeUser(user))});
}

/// Records one breadcrumb: a small, bounded trail of recent events attached to whatever error
/// [captureException] (or anything [runGuarded] catches) next reports, the same idea every other
/// client in this repo's own breadcrumbs feature implements. `category`/`level` default to
/// `"custom"`/`"info"`, matching every other client's own defaults; `data` is any small amount of
/// extra structured detail. Does nothing if [Configuration.trackBreadcrumbs] is `false`, or with
/// [Configuration.strictPrivacy] on: breadcrumbs are free text, never sent then, so not kept either.
///
/// This client has no web server framework of its own to record one from automatically (unlike
/// `sdks/go`'s HTTP middleware): every breadcrumb here is one you record by hand, wherever it's
/// meaningful, e.g. right before a network call or a significant state change:
///
///     addBreadcrumb('charging card', category: 'payment', data: {'order_id': order.id});
void addBreadcrumb(String message,
    {String category = 'custom', String level = 'info', Map<String, Object?> data = const {}}) {
  if (!configuration().trackBreadcrumbs || configuration().strictPrivacy) return;

  final trail = _currentBreadcrumbTrail();
  trail.add({
    'category': category,
    'message': message,
    'level': level,
    'timestamp': DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
    'data': data,
  });

  final maxBreadcrumbs = configuration().maxBreadcrumbs;
  while (trail.length > maxBreadcrumbs) {
    trail.removeAt(0);
  }
}

/// Empties the current breadcrumb trail (the ambient one [runWithBreadcrumbs] scoped, if called
/// from inside one, otherwise the global trail [addBreadcrumb] falls back to). A Flutter app is
/// expected to call this at the start of each new logical unit of work (e.g. each screen/route)
/// it wants a fresh trail for; there's no navigation hook here to do it automatically, the same
/// kind of deliberate, documented gap `sdks/rust`/`sdks/kotlin` have for the identical reason: no
/// middleware exists in this client to call it for you.
void clearBreadcrumbs() {
  _currentBreadcrumbTrail().clear();
}

/// Runs [body] with its own fresh, isolated breadcrumb trail: the concurrency-safe alternative to
/// the global trail [addBreadcrumb] otherwise falls back to, for a Dart server handling more than
/// one request at a time on the same isolate, the same reasoning [runWithUser] documents for
/// itself. Wrap a single request's handling in this the same way, typically together with
/// [runWithUser]:
///
///     runWithBreadcrumbs(() => runWithUser({'id': currentUser.id}, () => handleRequest(request)));
T runWithBreadcrumbs<T>(T Function() body) {
  return runZoned(body, zoneValues: {_breadcrumbZoneKey: _BreadcrumbBox(<Map<String, Object?>>[])});
}

/// Records one timed call's duration, in milliseconds, under [transactionName]: tallied in-process
/// (count, total, max) and flushed periodically as one small aggregate report, for the Performance
/// page's per-transaction table, not one network call per call. A no-op when
/// [Configuration.trackPerformance] is `false` or reporting isn't enabled for this environment.
///
/// This client has no web framework integration of its own (unlike `sdks/go`'s net/http and Gin
/// middleware), so nothing is timed automatically: wrap whatever you want on the Performance page
/// yourself, e.g. a request handler, with [timeTransaction]/[timeTransactionAsync], or call this
/// directly with a duration you measured. Keep [transactionName] low-cardinality
/// (`'GET /users/:id'`, not `'GET /users/42'`): every distinct name is its own row.
void recordPerformance(String transactionName, double durationMs) {
  _sharedPerformanceFlusher().record(transactionName, durationMs);
}

/// Runs [body], records how long it took under [transactionName] (see [recordPerformance]), and
/// returns whatever [body] returned. Recorded even if [body] throws: the duration up to the throw is
/// still a real duration, and a handler that fails is exactly one worth seeing on the Performance
/// page. For an `async` [body], use [timeTransactionAsync] instead: this one would only time
/// however long it took to *start* the future.
///
///     final user = timeTransaction('load-user', () => loadUserSync(id));
T timeTransaction<T>(String transactionName, T Function() body) {
  final stopwatch = Stopwatch()..start();
  try {
    return body();
  } finally {
    recordPerformance(transactionName, stopwatch.elapsedMicroseconds / 1000);
  }
}

/// The `async` form of [timeTransaction]: times until the future [body] returns completes, whether
/// it completes with a value or an error.
///
///     final user = await timeTransactionAsync('GET /users/:id', () => handleRequest(request));
Future<T> timeTransactionAsync<T>(String transactionName, Future<T> Function() body) async {
  final stopwatch = Stopwatch()..start();
  try {
    return await body();
  } finally {
    recordPerformance(transactionName, stopwatch.elapsedMicroseconds / 1000);
  }
}

/// Delivers whatever has been tallied so far right now, instead of waiting for the next
/// [Configuration.performanceFlushInterval] window to be noticed. Dart has no background timer to
/// flush on its own (see `PerformanceFlusher`'s own comment on why), so a window with no further
/// [recordPerformance] call after it sits unsent until this is called: call it yourself before a
/// short-lived program exits, or from a Flutter app's `AppLifecycleState.paused` handler.
Future<void> flushPerformance() => _sharedPerformanceFlusher().flush();

/// Records a named business metric (a purchase, a level completed, anything you want to name),
/// buffered and flushed periodically as one batch rather than one network call per capture. [value]
/// defaults to 1 so a bare counter-style call needs no argument; pass one for a real magnitude
/// (`captureMetric('payment', 49.0)`); it may be negative (a refund). A no-op when reporting isn't
/// enabled (no DSN, or this environment isn't in [Configuration.enabledEnvironments]), and a NaN or
/// infinite value is dropped. Nothing here is automatic, so there is no `trackMetrics` flag.
///
/// Dart has no background timer to flush on: a flush starts from a capture once
/// [Configuration.metricFlushInterval] has elapsed since the last one, so a program about to stop (a CLI
/// tool, a Flutter app on `AppLifecycleState.paused`) should `await flushMetrics()`.
void captureMetric(String name, [double value = 1]) {
  final config = configuration();
  if (!config.isEnabled) return;

  _sharedMetricBuffers().$1.record({
    'metric_name': name,
    'value': value,
    'environment': config.environment,
    'release': config.release,
  });
}

/// Records one infrastructure reading (CPU, memory, disk, anything else a program of yours reads) from
/// one of your own hosts. [hostname] defaults to [Configuration.serverName], so a script running on the
/// box it reports about needs no argument. Same buffered-batch delivery and no-op-when-disabled contract
/// as [captureMetric].
void captureInfrastructureMetric(String name, double value, {String? hostname}) {
  final config = configuration();
  if (!config.isEnabled) return;

  _sharedMetricBuffers().$2.record({
    'metric_name': name,
    'value': value,
    'hostname': hostname ?? config.serverName ?? '',
  });
}

/// Delivers every buffered metric and infrastructure reading right now, instead of waiting for the next
/// capture to notice the interval has elapsed.
Future<void> flushMetrics() async {
  final custom = _metricBuffer;
  final infrastructure = _infrastructureMetricBuffer;
  if (custom == null || infrastructure == null) return;
  await Future.wait([custom.flush(), infrastructure.flush()]);
}

/// The kinds of change ForgeOps accepts; [recordChange] sends anything else as `other`, since the
/// server rejects an unknown kind outright.
const Set<String> changeKinds = {'feature_flag', 'config', 'migration', 'dependency', 'infrastructure', 'other'};

// The server's own limit on a change's title; a longer one is cut here rather than rejected there.
const int _maxChangeTitleLength = 200;

/// Records one change you made (a feature flag flipped, a config value changed, a migration run),
/// so ForgeOps can show it next to the errors and slowdowns that followed it. [kind] is one of
/// [changeKinds] (anything else is sent as `other`); [title] is a short human summary, cut to 200
/// characters. Everything else is optional: [details] is a small map of extra structure,
/// [environment] defaults to [Configuration.environment], [url] links to more (a pull request, a
/// flag's settings page), and [id] is your own idempotency key so a retried call records the change
/// once. [occurredAt] defaults to now.
///
///     recordChange('feature_flag', 'Enabled new checkout',
///         details: {'flag': 'new_checkout', 'from': false, 'to': true}, actor: 'luke');
///
/// Queued and delivered on the event loop like an error report, so it never blocks the caller, and
/// it never throws: a failed delivery (including a 403 from a plan without change tracking) is
/// dropped quietly. A no-op when reporting isn't enabled or [title] is blank. A short-lived program
/// should `await flushChanges()` before it exits.
void recordChange(String kind, String title,
    {Map<String, Object?>? details,
    String? environment,
    String? service,
    String? actor,
    String? url,
    String? id,
    DateTime? occurredAt}) {
  try {
    final config = configuration();
    if (!config.isEnabled) return;
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;

    _sharedChangeQueue().push({
      'kind': changeKinds.contains(kind) ? kind : 'other',
      'title': trimmed.length > _maxChangeTitleLength ? trimmed.substring(0, _maxChangeTitleLength) : trimmed,
      'environment': environment ?? config.environment,
      'occurred_at': (occurredAt ?? DateTime.now()).toUtc().toIso8601String(),
      if (details != null && details.isNotEmpty) 'details': details,
      if (service != null) 'service': service,
      if (actor != null) 'actor': actor,
      if (url != null) 'url': url,
      if (id != null) 'id': id,
    });
  } catch (e) {
    configuration().log('recordChange failed: ${e.runtimeType}: $e');
  }
}

/// Delivers every change [recordChange] has queued. Dart delivers on the event loop, not a thread,
/// so a short-lived program (a CLI tool, a migration script) should await this before it exits.
Future<void> flushChanges() => _changeQueue?.flush() ?? Future<void>.value();

// The Zone keys `trace`/`span` store their values under: the open [SpanBuffer] (one per trace), and
// the id of the span currently open in this call chain. A [Zone] value, not a mutable stack, so
// parallel `Future`s each see their own idea of "the parent span" while sharing one buffer.
final Object _traceZoneKey = #forgeOpsTrackerTrace;
final Object _spanZoneKey = #forgeOpsTrackerSpan;

// A trace starts whenever reporting is enabled, even with trackTracing off: its id still goes on
// errors and outgoing headers, and _sendTrace just never sends its spans.
SpanBuffer? _startTrace(String? traceparent) {
  final config = configuration();
  if (!config.isEnabled) return null;
  final incoming = TraceParent.parse(traceparent);
  return SpanBuffer(config, traceId: incoming?.traceId, remoteParentSpanId: incoming?.parentSpanId);
}

void _sendTrace(SpanBuffer buffer, String name, DateTime startedAt, Stopwatch stopwatch) {
  final payload = buffer.finish(name, startedAt, stopwatch.elapsedMicroseconds / 1000);
  if (payload == null || !configuration().trackTracing) return;
  // Strict privacy: `http` spans named by method and host only, data kept to the masked statement
  // and database system (see strict_privacy.dart).
  _sharedSpanQueue().push(configuration().strictPrivacy ? strict_privacy.strictTrace(payload) : payload);
}

// The trace an error escaped from, remembered on the error itself (the way the Ruby SDK snapshots
// request state onto an exception), so capturing it after the trace's zone is gone, from runGuarded
// or an outer catch, still links it. The innermost trace wins. An Expando can't be attached to a
// string, number, boolean, or record, so an error of one of those types simply isn't remembered.
final Expando<String> _errorTraceIds = Expando<String>('forgeOpsTrackerTraceId');

void _rememberTrace(Object error, SpanBuffer buffer) {
  try {
    _errorTraceIds[error] ??= buffer.traceId;
  } catch (_) {
    // Not attachable: see _errorTraceIds.
  }
}

String? _escapedTraceId(Object error) {
  try {
    return _errorTraceIds[error];
  } catch (_) {
    return null;
  }
}

/// The id of the trace open in this call chain (32 lowercase hex characters, the W3C trace id), or
/// null outside a [trace]/[traceAsync] or when reporting isn't enabled.
String? currentTraceId() {
  final buffer = Zone.current[_traceZoneKey];
  return buffer is SpanBuffer ? buffer.traceId : null;
}

/// Runs [body] as a trace named [rootName] (for example `'GET /checkout'` or `'job:reindex'`): every
/// [span], [spanAsync] and [recordSpan] inside it, including across `await`s, nests beneath this
/// root. When [body] took at least [Configuration.traceCaptureThreshold] (one second by default) the
/// whole trace is sent, so fast calls cost nothing on the wire. Sent even if [body] throws, which
/// propagates unchanged. Called inside an already-open trace it just records a span instead.
///
/// This client has no web framework integration, so nothing starts a trace automatically: wrap
/// whatever you want traced, typically a request handler or a background job. For an `async` [body]
/// use [traceAsync]: this one would only time however long it took to *start* the future.
///
///     final response = trace('GET /checkout', () => handle(request));
///
/// To continue a trace another service started, pass its W3C `traceparent` header value, typically
/// the incoming request's own header: the trace keeps the caller's trace id, and its root span records
/// the caller's span as its parent, so it nests under that span on ForgeOps. Null, blank, or malformed
/// starts a fresh trace. Ignored inside an already-open trace.
///
///     trace('POST /orders', () => handle(request), traceparent: request.headers.value('traceparent'));
///
/// Errors captured inside carry the trace's id, and [httpSpan]/[httpSpanAsync] carry the trace on to
/// the services this one calls.
T trace<T>(String rootName, T Function() body, {String? traceparent}) {
  if (Zone.current[_traceZoneKey] != null) return span(rootName, body);
  final buffer = _startTrace(traceparent);
  if (buffer == null) return body();

  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  try {
    return runZoned(body, zoneValues: {_traceZoneKey: buffer, _spanZoneKey: buffer.rootSpanId});
  } catch (error) {
    _rememberTrace(error, buffer);
    rethrow;
  } finally {
    _sendTrace(buffer, rootName, startedAt, stopwatch);
  }
}

/// The `async` form of [trace]: the trace ends when the future [body] returns completes, whether it
/// completes with a value or an error.
///
///     final response = await traceAsync('GET /checkout', () => handle(request));
Future<T> traceAsync<T>(String rootName, Future<T> Function() body, {String? traceparent}) async {
  if (Zone.current[_traceZoneKey] != null) return spanAsync(rootName, body);
  final buffer = _startTrace(traceparent);
  if (buffer == null) return body();

  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  try {
    return await runZoned(body, zoneValues: {_traceZoneKey: buffer, _spanZoneKey: buffer.rootSpanId});
  } catch (error) {
    _rememberTrace(error, buffer);
    rethrow;
  } finally {
    _sendTrace(buffer, rootName, startedAt, stopwatch);
  }
}

/// Times [body] as a child span of whatever span is open in this call chain (or of the trace's
/// root), returning its result. Outside a [trace] it just runs [body]. Recorded even if [body]
/// throws, which propagates unchanged. [kind] is one of `controller`, `service`, `database`,
/// `redis`, `http`, `job`, `other` (anything else is sent as `other`). For an `async` [body] use
/// [spanAsync].
///
///     final order = span('load order', () => repo.find(id), kind: 'database', data: {'order_id': id});
///
/// For a `database` span, [statement] is the SQL it ran (a local SQLite query, say) and [dbSystem]
/// which database it was (`'sqlite'`, `'postgresql'`): sent in the span's data as `db.statement`,
/// with every string and number literal replaced by `?` first so values never leave the process,
/// cut at 4000 characters, and `db.system`, lowercased. Both are ignored on any other kind.
///
///     final rows = span('Load orders', () => db.select(sql), kind: 'database', statement: sql, dbSystem: 'sqlite');
T span<T>(String name, T Function() body,
    {String kind = 'service', Map<String, Object?>? data, String? statement, String? dbSystem}) {
  final buffer = Zone.current[_traceZoneKey];
  if (buffer is! SpanBuffer) return body();

  final spanId = SpanBuffer.newSpanId();
  final parent = Zone.current[_spanZoneKey] as String;
  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  try {
    return runZoned(body, zoneValues: {_spanZoneKey: spanId});
  } finally {
    buffer.record(
      spanId: spanId,
      parentSpanId: parent,
      name: name,
      kind: kind,
      startedAt: startedAt,
      durationMs: stopwatch.elapsedMicroseconds / 1000,
      data: data,
      statement: statement,
      dbSystem: dbSystem,
    );
  }
}

/// The `async` form of [span]: times until the future [body] returns completes, whether it
/// completes with a value or an error. Futures started inside [body] in parallel each see this span
/// as their parent.
///
///     final feed = await spanAsync('fetch feed', () => api.fetchFeed(), kind: 'http');
Future<T> spanAsync<T>(String name, Future<T> Function() body,
    {String kind = 'service', Map<String, Object?>? data, String? statement, String? dbSystem}) async {
  final buffer = Zone.current[_traceZoneKey];
  if (buffer is! SpanBuffer) return body();

  final spanId = SpanBuffer.newSpanId();
  final parent = Zone.current[_spanZoneKey] as String;
  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  try {
    return await runZoned(body, zoneValues: {_spanZoneKey: spanId});
  } finally {
    buffer.record(
      spanId: spanId,
      parentSpanId: parent,
      name: name,
      kind: kind,
      startedAt: startedAt,
      durationMs: stopwatch.elapsedMicroseconds / 1000,
      data: data,
      statement: statement,
      dbSystem: dbSystem,
    );
  }
}

/// Times an outgoing HTTP call as an `http` span named `"<METHOD> <host>"` (never the path or query,
/// which can carry ids or tokens) and hands [body] the headers to add to that request: a W3C
/// `traceparent` whose parent id is this span's own id, so the called service's root span nests
/// under it when it continues the trace (and an error it reports links to one reported here). Add
/// them however your HTTP client does, unless the request already carries its own `traceparent`:
///
///     final response = httpSpan('GET', uri, (headers) => fetchSync(uri, headers: headers));
///
/// The map is empty outside a [trace], when [Configuration.propagateTraces] is off, or when the host
/// isn't in [Configuration.tracePropagationTargets]; outside a trace no span is recorded either.
/// Recorded even if [body] throws, which propagates unchanged. For an `async` [body] use
/// [httpSpanAsync].
T httpSpan<T>(String method, Uri url, T Function(Map<String, String> headers) body, {Map<String, Object?>? data}) {
  final buffer = Zone.current[_traceZoneKey];
  if (buffer is! SpanBuffer) return body(const {});

  final spanId = SpanBuffer.newSpanId();
  final parent = Zone.current[_spanZoneKey] as String;
  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  try {
    return runZoned(() => body(_traceHeaders(buffer, spanId, url)), zoneValues: {_spanZoneKey: spanId});
  } finally {
    _recordHttpSpan(buffer, spanId, parent, method, url, startedAt, stopwatch, data);
  }
}

/// The `async` form of [httpSpan], for `dart:io`'s `HttpClient` or `package:http`: times until the
/// future [body] returns completes, whether it completes with a value or an error.
///
///     final response = await httpSpanAsync('POST', uri, (headers) async {
///       final request = await client.postUrl(uri);
///       headers.forEach(request.headers.set);
///       request.write(body);
///       return request.close();
///     });
Future<T> httpSpanAsync<T>(String method, Uri url, Future<T> Function(Map<String, String> headers) body,
    {Map<String, Object?>? data}) async {
  final buffer = Zone.current[_traceZoneKey];
  if (buffer is! SpanBuffer) return body(const {});

  final spanId = SpanBuffer.newSpanId();
  final parent = Zone.current[_spanZoneKey] as String;
  final startedAt = DateTime.now();
  final stopwatch = Stopwatch()..start();
  try {
    return await runZoned(() => body(_traceHeaders(buffer, spanId, url)), zoneValues: {_spanZoneKey: spanId});
  } finally {
    _recordHttpSpan(buffer, spanId, parent, method, url, startedAt, stopwatch, data);
  }
}

// The span id is generated before the call is made, so the header can name the span the call is
// later recorded as.
Map<String, String> _traceHeaders(SpanBuffer buffer, String spanId, Uri url) {
  if (!configuration().shouldPropagateTrace(url.host)) return const {};
  return {TraceParent.header: TraceParent.build(buffer.traceId, spanId)};
}

void _recordHttpSpan(SpanBuffer buffer, String spanId, String parent, String method, Uri url, DateTime startedAt,
    Stopwatch stopwatch, Map<String, Object?>? data) {
  buffer.record(
    spanId: spanId,
    parentSpanId: parent,
    name: '${method.toUpperCase()} ${url.host.isEmpty ? 'unknown' : url.host}',
    kind: 'http',
    startedAt: startedAt,
    durationMs: stopwatch.elapsedMicroseconds / 1000,
    data: data,
  );
}

/// Records a span you timed yourself under the current one; a no-op outside a [trace].
void recordSpan(String name,
    {String kind = 'service',
    required DateTime startedAt,
    required double durationMs,
    Map<String, Object?>? data,
    String? statement,
    String? dbSystem}) {
  final buffer = Zone.current[_traceZoneKey];
  if (buffer is! SpanBuffer) return;

  buffer.record(
    spanId: SpanBuffer.newSpanId(),
    parentSpanId: Zone.current[_spanZoneKey] as String,
    name: name,
    kind: kind,
    startedAt: startedAt,
    durationMs: durationMs,
    data: data,
    statement: statement,
    dbSystem: dbSystem,
  );
}

/// Delivers every finished trace that is still queued. Dart delivers on the event loop, not a
/// thread, so a short-lived program (a CLI tool) should await this before it exits, and a Flutter
/// app from its `AppLifecycleState.paused` handler.
Future<void> flushSpans() => _spanQueue?.flush() ?? Future<void>.value();

/// How long [flush] waits by default, and how long [runGuarded] waits before it rethrows.
const Duration _defaultFlushTimeout = Duration(seconds: 2);

/// Delivers everything still queued or buffered (errors, finished traces, recorded changes,
/// metrics, performance samples) and completes with true once it has all gone out, or with false
/// when [timeout] passes first. Never throws.
///
/// Delivery runs on the event loop, so anything reported just before `exit()` is lost unless the
/// program waits for it first:
///
///     captureException(error, stackTrace);
///     await flush();
///     exit(1);
///
/// A program that just returns from `main` needs none of this: the program keeps running until
/// pending deliveries finish.
Future<bool> flush({Duration timeout = _defaultFlushTimeout}) {
  Future<void> safely(Future<void> Function() flushOne) async {
    try {
      await flushOne();
    } catch (e) {
      configuration().log('flush failed: ${e.runtimeType}: $e');
    }
  }

  final reporter = _reporter;
  final spanQueue = _spanQueue;
  final changeQueue = _changeQueue;
  final metricBuffer = _metricBuffer;
  final infrastructureMetricBuffer = _infrastructureMetricBuffer;
  final performanceFlusher = _performanceFlusher;
  final pending = <Future<void>>[
    if (reporter != null) safely(reporter.flush),
    if (spanQueue != null) safely(spanQueue.flush),
    if (changeQueue != null) safely(changeQueue.flush),
    if (metricBuffer != null) safely(metricBuffer.flush),
    if (infrastructureMetricBuffer != null) safely(infrastructureMetricBuffer.flush),
    if (performanceFlusher != null) safely(performanceFlusher.flush),
  ];

  final completer = Completer<bool>();
  // Cancelled as soon as everything is delivered: a timer left running would keep a finished
  // program alive until it fired.
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(false);
  });
  Future.wait(pending).then((_) {
    timer.cancel();
    if (!completer.isCompleted) completer.complete(true);
  });
  return completer.future;
}

/// Runs [body] inside a zone that reports any error that escapes it: a synchronous throw, or an
/// unawaited [Future]'s error, both of which crash the isolate by default in Dart (verified
/// directly: neither is special-cased to merely print and continue): then re-throws it, with its
/// original stack trace, so the same crash still happens as it would without this wrapper. The
/// closest Dart equivalent to Python's `sys.excepthook` or Go's global panic hook: wrap your whole
/// `main()` (or `runApp()`, for Flutter) in this once, for zero-further-wiring coverage of anything
/// that isn't already inside its own `try`/`catch`.
///
///     void main() {
///       runGuarded(() {
///         doWork();
///       });
///     }
///
/// The rethrow waits for the report to be delivered first (see [flush]), at most 2 seconds, so an
/// unreachable ForgeOps can't hold up the crash for long. Delivery runs on the event loop, and a
/// crash ends the isolate before it could ever finish otherwise. Because of that wait, the error
/// is rethrown into the zone [runGuarded] was called from rather than out of the [runGuarded] call
/// itself: a synchronous throw from [body] no longer stops the code that follows [runGuarded], so
/// put all of `main` inside it, as above. The isolate keeps running during the wait.
void runGuarded(void Function() body) {
  runZonedGuarded(body, (error, stackTrace) {
    captureException(error, stackTrace);
    // Rethrown unchanged, once delivered (or the wait is up), from the zone runGuarded was called
    // in, where an uncaught error crashes the isolate exactly as it would have without this.
    flush().then((_) => Error.throwWithStackTrace(error, stackTrace));
  });
}

/// Not part of the public API: resets module-level state between test cases, the same
/// `resetForTesting`/`_resetForTesting` convention every other client in this repo has.
void resetForTesting() {
  _configuration = null;
  _disabledEnvironmentWarned = false;
  _reporter = null;
  _performanceFlusher = null;
  _spanQueue = null;
  _changeQueue = null;
  _metricBuffer?.discard();
  _infrastructureMetricBuffer?.discard();
  _metricBuffer = null;
  _infrastructureMetricBuffer = null;
  _globalCurrentUser = null;
  _globalBreadcrumbs.clear();
}
