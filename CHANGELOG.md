# Changelog

## 0.19.0 (2026-10-23)

- PII scrubbing catches card numbers however they're grouped (bare, 4-4-4-4, Amex's 4-6-5, or next to a
  security code) when the digits have a card network's prefix and pass the Luhn check, so long ids stay
  readable; IBANs, compact or in groups of four, by their own check digits; and fields named `iban`,
  `account_number`, `routing_number` or `bank_account`. The rules are in sdks/PII_SCRUBBING.md, the same in
  every SDK.

## 0.18.0 (2026-10-22)

- Strict privacy: the message fingerprint now also replaces email addresses with `<email>` and quoted
  values (`"..."`, and `'...'` when the quotes aren't part of a word) with `<str>`, before the existing
  steps. `KeyError: 'Jane Doe'` and `KeyError: 'Bob Smith'` now group together, and no guessable value sits
  behind the hash. Errors whose messages contain quotes or emails get new fingerprints once, so they open
  new issues after upgrading.

## 0.17.1 (2026-10-22)

- The README says what strict privacy does in its opening lines.
- The source is public at https://github.com/Luke-Popwell/forge-ops-tracker-dart, and the package links to it.

## 0.17.0 (2026-10-20)

- Strict privacy's path rule changed. A route template (`/patients/:id/notes`, `/patients/{id}`, `/files/*path`) is now kept exactly as it is, and a raw path keeps only its first segment, with the rest sent as `:path` (`/patients/jane-doe/12` is now `/patients/:path`; before, only segments holding a digit were replaced, so `jane-doe` went out). This applies to span names and performance transaction names. Nothing changes with strict privacy off.

## 0.16.0 (2026-10-20)

- Strict privacy, for apps that can't let personal or health data leave their own process: `config.strictPrivacy = true` in `init` (or `FORGE_OPS_STRICT_PRIVACY=true`). Error events then go out without their message (a `message_fingerprint` instead, so errors still group), breadcrumbs, SQL statement, source context, or the user's email and username, and with only the context and tag keys you list in `config.privacyAllowedFields` (or `FORGE_OPS_PRIVACY_ALLOWED_FIELDS`, comma separated). `addBreadcrumb` records nothing. `http` spans are named by method and host only, a span named after a raw path has the ids taken out, and span data keeps only `db.statement` and `db.system`. A performance sample's transaction name that is a raw path has its ids taken out too. Off by default; nothing changes unless you turn it on. No new dependencies: the SHA-256 behind the fingerprint is part of this package. Applies to `flutter_forge_ops_tracker` too, since it reports through this client.

## 0.15.0 (2026-10-13)

- A batch the server will never accept is no longer sent again and again. Before, any response other than a 2xx kept the batch (metrics, infrastructure readings, performance samples) and re-sent it at every flush with more added, for as long as the program ran; a plan without custom metrics answered 403 on every flush, and once the buffer was full, new metrics were dropped too. Now a 4xx other than 408 and 429 drops the batch at once.
- A delivery that fails for now (a network error, a timeout, a 5xx, a 408 or a 429) still keeps the batch for the next flush, but only for 5 flushes in a row: the fifth failure drops the batch and starts clean, so an endpoint that stays down can no longer grow one batch without end. A delivery that goes through resets the count. The 1000 entry cap on each metric buffer is unchanged.
- After a performance flush fails, `recordPerformance` now waits a full `performanceFlushInterval` before starting the next one. Before, every `recordPerformance` call after a failure started another flush, so a busy program sent a request per call while ForgeOps was unreachable.
- When a batch is dropped, `config.logger` is told once what was dropped and why.
- New `Client.sendPerformanceSamples`, `Client.sendMetrics` and `Client.sendInfrastructureMetrics` complete with the new `DeliveryStatus` (`delivered`, `rejected` or `failed`). The `deliver` methods still complete with a `bool`, `true` only for a 2xx, as before.

## 0.14.0 (2026-10-02)

- **Changed default:** with `FORGE_OPS_ENVIRONMENT` unset, the environment is now `'production'` instead of `'development'`. Before, an app that only set a DSN reported as `'development'`, which isn't an enabled environment, so nothing was ever sent and nothing said so. A blank `FORGE_OPS_ENVIRONMENT` now counts as unset too. To keep the old behavior, set `FORGE_OPS_ENVIRONMENT=development` where you don't want to send, or set `config.environment = 'development'` in `init`.
- `init` now prints one warning (once per process, to `config.logger` when one is set, otherwise stderr) when a DSN is set but the environment isn't one of `enabledEnvironments`, naming the environment and how to send from it. Nothing is printed when no DSN is set.
- New `Configuration.resolveEnvironment(Map<String, String>)`, how a new `Configuration` picks its environment, and `Configuration.disabledEnvironmentWarning`, the warning's text (or `null`).
- The README's setup examples now include every `import` they need.

## 0.13.0 (2026-10-01)

- A crash `runGuarded` reports is now delivered before the program dies of it. Delivery runs on the event loop, and the crash ended the program before it could finish, so the report was lost. `runGuarded` now waits for the delivery, at most 2 seconds, then re-throws the error unchanged, with its original stack trace, so the program still crashes as it would without it. Because of that wait, the error is re-thrown into the zone `runGuarded` was called from rather than out of the `runGuarded` call itself, so a synchronous throw no longer skips code written after `runGuarded`; wrap all of `main` in it, as the README shows.
- New `flush({timeout})` (default 2 seconds) delivers everything still queued or buffered (errors, traces, recorded changes, metrics, performance samples) and completes with `true` once it has all gone out, or `false` when the timeout passed first. Call `await flush()` before `exit()`, which otherwise loses anything reported just before it. It never throws. `Reporter.flush()` waits for one reporter's own queue.

## 0.12.0 (2026-09-29)

- SQL masking (database spans' `db.statement`, and the opt-in statement on errors) now also catches strings with backslash-escaped quotes (`'o\'brien'`, `E'o\'brien'`), prefixed strings (`X'DEADBEEF'`, `N'...'`, `B'...'`, `U&'...'`, masked with their prefix), and hex, binary, exponent and leading-dot numbers (`0x1F`, `0b101`, `3e10`, `1.5E-3`, `.5`). On a database span whose `dbSystem` is `'mysql'` or `'mariadb'`, `"double quoted"` strings are masked too; elsewhere they're identifiers and are left alone. This matches what ForgeOps itself masks on arrival.
- A string cut off right after a backslash (`'secret\`, as a truncated statement can end) is now masked to the end like any other cut-off string, instead of being left as written.

## 0.11.0 (2026-09-25)

- A `database` span can now carry the SQL it ran, such as a local SQLite query: `span`, `spanAsync` and `recordSpan` take optional `statement` and `dbSystem` (such as `'sqlite'`) arguments. The statement is masked before it leaves the process (every string and number literal becomes `?`), cut at 4000 characters, and sent in the span's data as `db.statement`, with `db.system` lowercased. A `db.statement` put in `data` directly is masked the same way. Both are ignored on spans of any other kind.

## 0.10.0 (2026-09-25)

- Change tracking: `recordChange(kind, title, {details, environment, service, actor, url, id, occurredAt})` records one change you made (a feature flag flipped, a config value changed, a migration run) so ForgeOps can show it next to the errors and slowdowns that followed. `kind` is one of `feature_flag`, `config`, `migration`, `dependency`, `infrastructure` or `other` (exported as `changeKinds`); anything else is sent as `other`. The title is cut to 200 characters, `environment` defaults to the configured one, and `occurredAt` to now. Queued on the event loop like an error report, so it never blocks and never throws; a failed delivery, including a 403 on a plan without change tracking, is dropped quietly. `await flushChanges()` before a short-lived program exits. This client sends no startup snapshot of its own.

## 0.9.0

- Trace context: an error captured inside a `trace`/`traceAsync` (across `await`s) now carries the trace's `trace_id`, and so does an error that escaped a trace and is captured afterward, which links it to errors other services reported for the same request (the two projects must be linked in ForgeOps). New `httpSpan`/`httpSpanAsync(method, url, (headers) => ...)` record an outgoing call as an `http` span and hand your code a W3C `traceparent` header naming that span, so the service being called continues the trace. `trace`/`traceAsync` take an optional `traceparent` to continue a trace another service started (strictly parsed; a bad value starts a fresh trace), and `currentTraceId()` returns the open trace's id. Trace and span ids are W3C ids, never all zeros; `TraceParent` is exported. Two new options: `propagateTraces` (default true; false stops the header but still records the span) and `tracePropagationTargets` (default null, every host; otherwise host strings matched exactly or as a subdomain on a dot boundary, and `RegExp`s matched against the host). With `trackTracing` off a trace still has an id for errors and headers; only its spans stop being sent. Nothing instruments `HttpClient` automatically, and errors captured outside a trace are unchanged.

## 0.8.0

- Database errors now say where to look. When an error carries the SQL behind a failed local database call (`package:sqlite3`'s `SqliteException.causingStatement`, or sqflite's and SQLite's error text), the event carries the names of the tables and views (and any stored procedure) that SQL touched. On by default (`captureSqlObjects`); names are identifiers, never values. New opt-in `captureSqlStatement` (default false) also sends the statement itself, with every string and number replaced by `?`. Each project has its own server-side setting that can stop the statement being stored regardless of this flag; the names are still kept.

## 0.7.1

- Documentation only: the README and package description now describe ForgeOps as a hosted service, link to getforgeops.net, and show the real host in the connection string example instead of a placeholder. No code changes.

## 0.7.0

- Performance percentiles: every performance sample now carries a small latency histogram alongside its
  count/sum/max (fixed buckets of 50, 100, 250, 500, 1000, 2500, 5000 and 10000ms, plus an overflow
  bucket), so ForgeOps can show an approximate p50/p95/p99 per transaction instead of only an average. No
  new config; this rides the existing performance tracking flag and flush interval.

## 0.6.0

- Custom metrics and infrastructure monitoring: `captureMetric(name, [value = 1])` records a named
  business event (a purchase, a level completed) and `captureInfrastructureMetric(name, value,
  {hostname})` a CPU/memory/disk reading from one of your own hosts. Buffered and flushed as one batch
  once `metricFlushInterval`/`infrastructureMetricFlushInterval` has elapsed at a capture (no background
  timer, for the same reason performance monitoring has none); `await flushMetrics()` before a
  short-lived program exits. Nothing is automatic, so there is no `trackMetrics` flag.

## 0.5.0

- Distributed tracing: `trace`/`traceAsync` wrap a unit of work, `span`/`spanAsync` add child spans
  (nested via `Zone`, so parallel futures each parent under their own span), and `recordSpan` adds one
  you timed yourself. A trace is sent to the new `/spans` endpoint only when it took at least
  `Configuration.traceCaptureThreshold` (one second), and is sent even if the body throws. Nothing is
  traced automatically (no web framework integration in this client). Delivery is the same bounded
  event-loop queue as error reports; `await flushSpans()` before a short-lived program exits. Turn it
  off with `Configuration.trackTracing = false`.

## 0.4.0

- Performance monitoring: `recordPerformance` tallies how long named work took (count, total, max)
  and flushes one small aggregate per transaction, for the Performance page's per-transaction
  table. `timeTransaction`/`timeTransactionAsync` wrap a block and record even if it throws. Nothing
  is timed automatically (no web framework integration in this client). There is deliberately no
  background timer, since a pending `Timer` would stop a Dart CLI program from exiting on its own:
  a flush starts from a `recordPerformance` call once `performanceFlushInterval` has elapsed, or
  from an explicit `flushPerformance()`, which a short-lived program or a Flutter app's
  `AppLifecycleState.paused` handler should call. Turn it off with
  `Configuration.trackPerformance = false`.

## 0.3.0

- Breadcrumbs: `addBreadcrumb` records a small, bounded trail of recent events (30 by default,
  configurable via `Configuration.maxBreadcrumbs`) attached to whatever error gets reported next.
  `addBreadcrumb` is a plain global by default (the same single-flow reasoning `setUser` already
  documents); `runWithBreadcrumbs` scopes a fresh, isolated trail to one call chain via `Zone`
  instead, for a Dart server handling more than one request at a time on the same isolate. Never
  recorded automatically (no web framework built into this client to record one from); turn it off
  entirely with `Configuration.trackBreadcrumbs = false`.

## 0.2.0

- Identify the affected user on a reported error: pass `user` to `captureException`, or call
  `setUser`/`runWithUser` to attach one to every subsequently reported error until changed or
  cleared. `setUser` is a plain global (correct for a single-user Flutter/CLI app); `runWithUser`
  scopes the value to one call chain via Dart's `Zone` mechanism instead, for a Dart server
  handling more than one request at a time on the same isolate. Never scrubbed by PII scrubbing.

## 0.1.0

- Initial release: works in any Dart VM environment (server apps, CLI tools, Flutter
  mobile/desktop) via `dart:io`/`dart:convert`, zero runtime dependencies. PII scrubbing (email
  addresses, formatted SSNs/credit cards, known API key/token formats, and any field whose name
  suggests a secret) runs before a payload ever leaves the host app's process. Delivery runs on
  an async drain loop with a bounded queue and short HTTP timeouts; every failure mode is caught
  and dropped rather than thrown, so a broken or unreachable tracker can never take down the host
  app. See the separate `flutter_forge_ops_tracker` package for Flutter-specific automatic
  capture (`FlutterError.onError`/`PlatformDispatcher.onError`) on top of this one.
