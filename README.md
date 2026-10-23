# forge_ops_tracker (Dart)

Dart error reporting client for [ForgeOps](https://getforgeops.net).
Requires Dart 3.0+. Captures unhandled errors automatically via a guarded entry point (or, for
Flutter apps, the companion `flutter_forge_ops_tracker` package), lets you report caught errors
explicitly, and scrubs likely personal data before anything leaves the process.

> For health or personal data, turn on [strict privacy](#strict-privacy): the SDK then sends only structured facts about each error (its type, stack trace, release and route), never the message, a raw path, breadcrumbs, or context you haven't allowed.

This directory holds two packages:

- **`forge_ops_tracker`** (this directory): the core client. Works in any Dart VM environment:
  server apps, CLI tools, and Flutter apps on mobile/desktop.
- **[`flutter_forge_ops_tracker`](flutter_forge_ops_tracker)**: a separate, small package adding
  Flutter-specific automatic capture (`FlutterError.onError`, `PlatformDispatcher.onError`) on top
  of the core client. Kept separate specifically so a plain Dart (non-Flutter) consumer of the core
  package never has to pull in the Flutter SDK.

## Installation

```yaml
# pubspec.yaml
dependencies:
  forge_ops_tracker: ^0.19.0
  # Flutter apps only:
  flutter_forge_ops_tracker: ^0.2.0
```

Or from the command line: `dart pub add forge_ops_tracker` (add `flutter pub add
flutter_forge_ops_tracker` too for Flutter apps).

### Dependencies

The core package has zero runtime dependencies: `dart:io`'s `HttpClient` and `dart:convert`'s
`jsonEncode` cover HTTP delivery and JSON encoding directly from the standard library.

**One real platform limitation this implies: `dart:io` is not available on Flutter Web.** This
client covers server/CLI Dart and Flutter on mobile/desktop, not Flutter Web. Extending it to Web
would mean swapping `dart:io`'s `HttpClient` for `package:http` (or `dart:html`'s fetch-equivalent)
behind a conditional import: a real, known gap, not silently ignored, just out of scope for this
round.

## Configuration

Set a DSN (from a project's settings page in ForgeOps), either via the `FORGE_OPS_DSN` environment
variable or explicitly:

```dart
import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;

forge_ops_tracker.init((config) {
  config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events'; // or leave unset to read FORGE_OPS_DSN
  config.release = '...';
});
```

Call `init` once at startup.

### Environments

Errors are only sent from the environments in `enabledEnvironments` (default `production` and
`staging`). The current environment is `FORGE_OPS_ENVIRONMENT`, or `'production'` when it isn't set,
so a DSN on its own is enough to start sending. Set `config.environment` to set it explicitly.

When a DSN is set but the environment isn't enabled, `init` prints one warning saying so (to
`config.logger` when you've set one, otherwise stderr), and nothing is sent. To send from that
environment too, add it: `config.enabledEnvironments.add('development');`.

## What gets reported automatically, and what doesn't

**Plain Dart (server apps, CLI tools):** wrap your entry point in `runGuarded`. A complete
`bin/main.dart`:

```dart
import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;

void main() {
  forge_ops_tracker.init((config) {
    config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events'; // or leave unset to read FORGE_OPS_DSN
  });
  forge_ops_tracker.runGuarded(() {
    // your app
  });
}
```

This reports any error that escapes `body`: a synchronous throw, or an unawaited `Future`'s
error: then re-throws it, with its original stack trace, so the same crash still happens as it
would without this wrapper. Verified directly (not assumed): both a synchronous throw and an
unawaited `Future`'s uncaught error crash a plain Dart program by default, with no zone at all.

The re-throw waits until the report has been delivered, at most 2 seconds, since a crash would
otherwise end the program before the delivery could finish. Because of that wait, the error is
re-thrown into the zone `runGuarded` was called from, not out of the `runGuarded` call itself: a
synchronous throw no longer skips the code after `runGuarded`, so put all of `main` inside it, as
above. The program keeps running during the wait.

### Before `exit()`

Delivery runs on the event loop, so an error reported just before `exit()` (in a CLI tool, say) is
lost unless the program waits for it. `flush()` sends everything still queued or buffered (errors,
traces, recorded changes, metrics, performance samples) and completes with `true` once it has all
gone out, or `false` when the timeout (2 seconds unless you pass one) passed first. It never throws.

```dart
} catch (error, stackTrace) {
  forge_ops_tracker.captureException(error, stackTrace);
  await forge_ops_tracker.flush(); // or flush(timeout: const Duration(milliseconds: 500))
  exit(1);
}
```

A program that just returns from `main` doesn't need it: the program keeps running until pending
deliveries finish (and, as with any use of `dart:io`'s `HttpClient`, until its idle connection
closes, up to 15 seconds later).

**Flutter apps:** use the separate `flutter_forge_ops_tracker` package instead, which wires the two
Flutter-specific error paths `runGuarded` doesn't cover on its own:

```dart
import 'package:flutter/material.dart';
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

- `FlutterError.onError`: an error the framework itself catches while building, laying out, or
  painting a widget (what would otherwise render Flutter's own red "error" screen in debug mode).
- `PlatformDispatcher.onError`: anything that escapes the root zone instead: an async callback's
  error, an uncaught `Future` error, anything that never went through a widget build.

Both chain to whatever handler was already installed rather than replacing it, so installing this
package changes nothing observable about how an error is presented besides also reporting it
first.

**An error your own code catches and handles is different** in both cases: report it explicitly,
right at the catch site:

```dart
try {
  chargeCard(order);
} catch (error, stackTrace) {
  forge_ops_tracker.captureException(error, stackTrace, {'order_id': order.id});
}
```

Delivery happens on an async drain loop with a bounded queue and a short per-request HTTP timeout
(`Configuration.timeout`, 2s default): see `DeliveryQueue`'s own comment for why Dart's
single-threaded, cooperative concurrency model makes this safe without any locking. Every failure
mode (network errors, timeouts, a full queue, a malformed DSN) is caught and dropped rather
than thrown, so a broken or unreachable tracker can never take down the host app.

One real limitation worth knowing: delivery is in-memory only, with no durable on-disk queue. A
crash `runGuarded` reports waits up to 2 seconds for its delivery before the program dies of it,
so a crash while ForgeOps is unreachable for longer than that is lost, and a process killed
outright (a signal, `exit()` without `await flush()`) loses whatever is still queued. A
caught-and-handled `captureException` call, made while the program is still healthy, doesn't have
this limitation.

## Identifying users

```dart
forge_ops_tracker.captureException(error, stackTrace, null, {'id': user.id, 'email': user.email});
```

Or `setUser` to attach it to every subsequently reported error (an explicit `captureException`
call, or anything `runGuarded`/the Flutter handlers catch) until changed or cleared, rather than
passing it to every call by hand, e.g. right after sign-in:

```dart
forge_ops_tracker.setUser({'id': user.id, 'email': user.email});
// on sign-out:
forge_ops_tracker.setUser(null);
```

There's no way to automatically detect "the current user" the way a server-side web framework with
its own session/auth middleware can (see `gems/forge_ops_tracker`'s Warden integration for what
that looks like in a language that has one), so this is always manual. `setUser` is a plain,
single global value: correct for a Flutter or CLI app, which is effectively single-user (there's no
concurrent, unrelated request to leak into, the same reasoning `sdks/swift`/`sdks/android` use for
their own plain static property), but **shared across every concurrently in-flight call if this
isolate is also handling more than one request at once**, e.g. a Dart server built on `shelf` or
similar. For that case, use `runWithUser` instead, which scopes the value to one call chain via
Dart's own `Zone` mechanism (the same continuation-local-storage idea Node's `AsyncLocalStorage` is
built on, for the identical reason: an ambient value needs to be scoped to one request, not shared
process-wide):

```dart
Future<Response> handleRequest(Request request) {
  return forge_ops_tracker.runWithUser({'id': currentUser(request).id}, () async {
    // ...request handling; anything captured in here (including across an await, or from a
    // Timer/microtask this scheduled) sees the scoped user, not whatever setUser last set
    // globally or whatever another concurrent request's own runWithUser call set.
  });
}
```

`runWithUser` always wins over `setUser` when both are in play. `id`/`email`/`username` are all
independently optional. Shows up on an issue's own detail page, and as its own affected-users count
alongside the regular event count.

## Breadcrumbs

A small, bounded trail of recent events attached to whatever error gets reported next, so an
issue's detail page can show what led up to it, not just the moment it happened:

```dart
forge_ops_tracker.addBreadcrumb('charging card', category: 'payment', data: {'order_id': order.id});
```

`category` and `level` default to `"custom"`/`"info"`; only the 30 most recent (configurable via
`Configuration.maxBreadcrumbs`) are kept, oldest dropped first. Turn it off entirely with
`Configuration.trackBreadcrumbs = false`.

There's no web server framework built into this client to record one from automatically (unlike
`sdks/go`'s HTTP middleware), so every breadcrumb here is one you record by hand, wherever it's
meaningful in your own app. The same global-vs-scoped choice `setUser`/`runWithUser` make applies
here too, for the identical reason: `addBreadcrumb` accumulates into a single global trail by
default, correct for a Flutter or CLI app, but for a Dart server handling more than one request at
a time on the same isolate, wrap each request in `runWithBreadcrumbs` so it gets its own fresh,
isolated trail:

```dart
Future<Response> handleRequest(Request request) {
  return forge_ops_tracker.runWithBreadcrumbs(() {
    return forge_ops_tracker.runWithUser({'id': currentUser(request).id}, () async {
      // ...request handling; addBreadcrumb calls in here only ever show up on this request's own
      // reports, not another concurrent request's.
    });
  });
}
```

Call `clearBreadcrumbs()` at the start of a new logical unit of work (a Flutter app's own next
screen/route, say) to start that unit with a fresh trail; there's no navigation hook here to do it
automatically.

## Performance monitoring

Times whatever you wrap and reports one small aggregate per transaction (how many times it ran,
total and maximum duration) at most once per `performanceFlushInterval` (60s by default), for the
Performance page's per-transaction table. Not one network call per timed call.

Each aggregate also carries a small latency histogram (a count per fixed latency bucket: 50, 100,
250, 500, 1000, 2500, 5000 and 10000ms, plus an overflow bucket), so ForgeOps can show an
approximate p50/p95/p99 per transaction, not just an average. Percentiles are accurate to the width
of whichever bucket a duration falls into; the SDK never stores the individual durations.

```dart
// Wrap a whole request handler, or any block you want on the Performance page:
final response = await forge_ops_tracker.timeTransactionAsync('GET /users/:id', () => handleRequest(request));
final user = forge_ops_tracker.timeTransaction('load-user', () => loadUserSync(id)); // a synchronous body

// Or record a duration you measured yourself:
forge_ops_tracker.recordPerformance('nightly-export', stopwatch.elapsedMilliseconds.toDouble());
```

This client has no web framework integration (unlike `sdks/go`'s net/http and Gin middleware), so
**nothing is timed automatically**: you choose what to wrap. Keep transaction names low-cardinality
(`'GET /users/:id'`, not `'GET /users/42'`): every distinct name is its own row. Both wrappers record
even if the body throws. Turn it off with `Configuration.trackPerformance = false`; it also does
nothing when reporting isn't enabled for the current environment.

**There is no background timer, and that has a consequence you should know about.** Every other
client in this repo flushes from a daemon thread that never keeps its process alive. Dart has no
equivalent: a pending `Timer` keeps the isolate's event loop running, so a timer here would stop a
plain Dart CLI program from ever exiting on its own. Instead, `recordPerformance` starts a flush
itself once a full `performanceFlushInterval` has passed since the last one. A long-lived server
never notices. But a window with no further `recordPerformance` call after it sits unsent, so call
`await forge_ops_tracker.flushPerformance()` yourself before a short-lived program exits, or from a
Flutter app's `AppLifecycleState.paused` handler.

A delivery that fails for now (a network error, a timeout, a 5xx, a 408 or a 429) keeps every
tally, so the next flush's window just grows; after 5 flushes in a row have failed, the batch is
dropped and the tallies start clean. A batch the server rejects (any other 4xx) is dropped at once
and never sent again. What a flush delivered
is *subtracted* from the tallies afterward, never the whole map cleared: a `recordPerformance` call
that lands while a delivery is awaiting the network would otherwise be silently discarded (a real
bug `sdks/go` had and fixed; `gems/forge_ops_tracker`'s reference implementation still has it). A
deterministic test pins this.

## Distributed tracing

A slow call's own breakdown: which database calls, HTTP calls, or pieces of your code the time went
to, shown as a span tree on ForgeOps. Wrap the unit of work in `trace`/`traceAsync`, and anything
inside it, including across `await`s, can add spans; the trace is sent only when the whole thing took
at least `traceCaptureThreshold` (one second by default), so fast calls cost nothing on the wire.
A trace can continue one another service started and carry itself on to the services this one calls,
so an error here links to the error it caused (or was caused by) there: see "Connecting errors across
services" below.

```dart
final response = await traceAsync('GET /checkout', () async {
  final order = await spanAsync('load order', () => repo.find(id), kind: 'database', data: {'order_id': id});
  await spanAsync('charge card', () => gateway.charge(order));
  return render(order);
});

// Synchronous work: trace(...) and span(...). Something you timed yourself (kind is one of
// controller/service/database/redis/http/job/other):
recordSpan('SELECT orders', kind: 'database', startedAt: startedAt, durationMs: elapsedMs);
```

This client has no web framework integration, so **nothing starts a trace or records a span
automatically**: you wrap what you want traced. Like `runWithUser`/`runWithBreadcrumbs`, the trace is
scoped with Dart's `Zone` mechanism, so a Dart server handling several requests at once keeps each
trace apart, and the parent of a new span is a zone value too: futures started in parallel inside one
span each parent under it, and a span opened after another closed goes back to the outer parent.
`span` records even when the body throws (the error propagates unchanged) and just runs the body
outside a trace; a `trace` inside another `trace` records a span instead. `kind` outside that list is
sent as `other`, since the server rejects a whole trace over one unknown kind. A trace holds at most
500 spans.

Delivery runs on the event loop through a bounded queue (like error reports), not a thread, so a
short-lived program, or a Flutter app about to be paused, should `await flushSpans()` before it
exits. Turn the feature off with `Configuration.trackTracing = false`.

### Database spans with their SQL

A `database` span can carry the SQL it ran (a query against a Flutter app's local SQLite database,
or a server's own query) and which database it was. Every string and number literal is replaced by
`?` before it leaves your process (so `WHERE email = 'a@b.co'` is sent as `WHERE email = ?`), the
statement is cut at 4000 characters, and ForgeOps masks it again on arrival. It is sent in the
span's data as `db.statement` and `db.system`, and ForgeOps shows it on the span. Both are ignored on
any other kind. This client doesn't instrument a database driver itself, so pass the statement where
you run the query:

```dart
const sql = "SELECT * FROM messages WHERE thread_id = 42 AND read = 0";
final messages = await spanAsync('Load messages', () => db.rawQuery(sql),
    kind: 'database', statement: sql, dbSystem: 'sqlite');
// Sent as db.statement "SELECT * FROM messages WHERE thread_id = ? AND read = ?", db.system "sqlite".
```

`span` and `recordSpan` take the same `statement` and `dbSystem` arguments.

Masking covers strings with `''` or backslash-escaped quotes (`'o\'brien'`), prefixed strings
(`E'...'`, `X'DEADBEEF'`, `N'...'`, `B'...'`, `U&'...'`), `$tag$` dollar-quoted bodies, and hex,
binary, exponent and leading-dot numbers (`0x1F`, `0b101`, `1.5E-3`, `.5`), but never the digits in
a name like `orders2` or a `$1` placeholder. With `dbSystem` set to `'mysql'` or `'mariadb'`,
`"double quoted"` values are masked too; for any other database they're names, and are left as
written.

### Connecting errors across services

Trace and span ids use the [W3C Trace Context](https://www.w3.org/TR/trace-context/) format (a 32
character lowercase hex trace id, 16 character span ids). Make an outgoing request inside a trace
with `httpSpan`/`httpSpanAsync` and it is recorded as an `http` span named after its method and host,
and your code is handed the `traceparent` header (`00-<trace id>-<span id>-01`) to send with it; the
header's parent id is that span's own id, so the called service's spans nest under it. An error
captured inside the trace carries its `trace_id`, which is what links it to the backend error from
the same request. A Flutter checkout flow with `dart:io`'s `HttpClient`:

```dart
import 'dart:io';

import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;

Future<void> placeOrder(String orderJson) => forge_ops_tracker.traceAsync('checkout', () async {
      final uri = Uri.parse('https://api.example.com/orders');
      final client = HttpClient();
      try {
        final response = await forge_ops_tracker.httpSpanAsync('POST', uri, (headers) async {
          final request = await client.postUrl(uri);
          headers.forEach(request.headers.set); // the traceparent header, when one applies
          request.write(orderJson);
          return request.close();
        });
        if (response.statusCode != 201) throw HttpException('order rejected: ${response.statusCode}', uri: uri);
      } catch (error, stackTrace) {
        forge_ops_tracker.captureException(error, stackTrace); // carries this trace's trace_id
      } finally {
        client.close();
      }
    });
```

A Dart server continues a trace a caller started by passing the incoming header to `trace`/`traceAsync`:
the trace keeps the caller's trace id and its root span nests under the caller's span. A missing or
malformed header (strictly parsed: lowercase hex only, no all-zero ids, no version `ff`) just starts a
fresh trace.

```dart
await forge_ops_tracker.traceAsync('POST /orders', () => handle(request),
    traceparent: request.headers.value('traceparent'));
```

The public API:

```dart
T trace<T>(String rootName, T Function() body, {String? traceparent});
Future<T> traceAsync<T>(String rootName, Future<T> Function() body, {String? traceparent});
T httpSpan<T>(String method, Uri url, T Function(Map<String, String> headers) body, {Map<String, Object?>? data});
Future<T> httpSpanAsync<T>(String method, Uri url, Future<T> Function(Map<String, String> headers) body,
    {Map<String, Object?>? data});
String? currentTraceId();          // the open trace's id, or null outside one
class TraceParent { parse, build, generateTraceId, generateSpanId }
```

Because the trace lives in a `Zone`, `captureException` anywhere inside it, across `await`s, carries
its `trace_id` without passing anything, and an error that escapes a trace keeps that id when it is
captured afterward (by `runGuarded`, say). An error captured outside any trace is exactly what it was
before. The trace id exists even with `trackTracing = false` (only the spans stop being sent), since it
is what links errors across services. The headers map is empty outside a trace and records no span
there; don't add the header to a request that already carries its own `traceparent`. Nothing
instruments `HttpClient` or `package:http` automatically: only calls made through `httpSpan` get the
header.

Two options control the header:

```dart
forge_ops_tracker.init((config) {
  config.propagateTraces = true;           // default; false stops the header (the http span is still recorded)
  config.tracePropagationTargets = null;   // default: every host
  // or only your own backends: a string matches that host exactly or as a subdomain on a dot boundary
  // ('example.com' matches 'api.example.com', not 'badexample.com'); a RegExp is searched for in the
  // lowercased host
  config.tracePropagationTargets = ['example.com', RegExp(r'\.internal$')];
});
```

Narrow the targets when the app also calls third-party APIs that reject unknown headers or shouldn't
see your trace ids. To see errors from both sides of a request together, the other service must also
report to ForgeOps (the Ruby SDK continues the trace from the header automatically as of 0.12.0) and
the two projects must be linked in ForgeOps.

## Custom metrics and infrastructure monitoring

Two explicit calls (nothing is automatic, so there is no `trackMetrics` flag): a business event you
name yourself, and a reading from one of your own hosts.

```dart
captureMetric('signup');                     // value defaults to 1: a bare counter
captureMetric('payment', 49.0);              // a real magnitude; it may be negative (a refund)

captureInfrastructureMetric('cpu', 0.42);                       // hostname defaults to serverName
captureInfrastructureMetric('disk', 0.81, hostname: 'db-1');
await flushMetrics();                                           // send right now
```

Each capture is buffered and flushed as one batch every `metricFlushInterval` /
`infrastructureMetricFlushInterval` (60 seconds by default). **Dart has no background timer to flush
on** (a pending `Timer` would stop a CLI program from exiting on its own), so a flush starts from a
capture once the interval has elapsed since the last one, and a program about to stop (a CLI tool, or a
Flutter app on `AppLifecycleState.paused`) should `await flushMetrics()`. Every entry is stored as it was
captured (a signup is a row, not a running total), so a count or sum you compute later is exact. Both
are a no-op when reporting isn't enabled for the environment.

A delivery that fails for now (a network error, a timeout, a 5xx, a 408 or a 429) keeps every entry
for the next flush, and an entry captured while a delivery is in flight is kept too (the Ruby gem's own
buffer loses it; a test pins this with a gated delivery: a flush awaits the network, so captures really
do interleave with it). After 5 flushes in a row have failed, the batch is dropped and the buffer starts
clean. A batch the server rejects (any other 4xx, such as the 403 a plan without the feature answers) is
dropped at once and never sent again. Each buffer holds at most 1000 entries and drops further ones
until a flush empties it. A NaN or infinite value is dropped at capture:
`jsonEncode` throws on one. Requires a ForgeOps plan that includes custom metrics / infrastructure
monitoring.

## Recording changes

Tell ForgeOps when something about the app changed outside a release (a feature flag flipped, a remote
config value changed, a local database migrated) so it shows up next to the errors and slowdowns that
followed:

```dart
import 'package:forge_ops_tracker/forge_ops_tracker.dart' as forge_ops_tracker;

Future<void> main() async {
  forge_ops_tracker.init((config) {
    config.dsn = 'https://<api_key>@getforgeops.net/api/v1/events';
    config.environment = 'production';
  });

  forge_ops_tracker.recordChange(
    'feature_flag',
    'Enabled new checkout',
    details: {'flag': 'new_checkout', 'from': false, 'to': true},
    actor: 'luke',
    url: 'https://example.com/flags/new_checkout',
  );

  await forge_ops_tracker.flushChanges(); // only needed before a short-lived program exits
}
```

`kind` is one of `feature_flag`, `config`, `migration`, `dependency`, `infrastructure` or `other`;
anything else is sent as `other`. The title is cut to 200 characters. `environment` defaults to
`config.environment` and `occurredAt` to now; `service`, `actor`, `url` and `id` (your own idempotency
key, so a retried call records the change once) are optional. The call is queued on the event loop like
an error report, so it never blocks and never throws: a failed delivery is dropped quietly, including
the 403 a plan without change tracking returns. It is a no-op when reporting isn't enabled for the
environment. This client runs in apps and CLI tools, not only on servers, so it sends no automatic
startup snapshot; every change is one you record.

## `in_app` backtrace frames

A Dart `StackTrace` has no structured frame API at all: the only thing available is
`StackTrace.toString()`, a multi-line format like:

```
#0      ChargeService.chargeCard (package:my_app/charge_service.dart:42:7)
#1      main (package:my_app/main.dart:10:3)
```

so this client parses that format with a regex (verified directly against real
caught-and-rethrown stack traces before relying on this shape). Set `Configuration.packageName`
(e.g. `"my_app"`, matching your `pubspec.yaml`'s own `name:`) to mark a frame `in_app` when its
location is `"package:<packageName>/..."`; unset by default, meaning every frame reports as
not-in-app until you set it, the safe default. A `dart:...` location (the Dart SDK itself) and any
other `package:...` location (a third-party pub dependency) are never `in_app`, regardless of
configuration.

## Source context

By default, each in-app backtrace frame (never a third-party pub dependency or the Dart SDK
itself) is captured along with the 5 lines of source on either side of the culprit line, read
straight off disk at capture time, so an issue's detail page can show the actual code that broke,
not just a file:line:method reference. A `package:` frame location has no filesystem path of its
own, so this client resolves it against the running isolate's own package configuration first
(`Isolate.resolvePackageUriSync`) before reading; this works out of the box in a normal `dart run`/
Flutter debug session, and fails silently, the same as an unreadable file, wherever that
resolution isn't available (an AOT-compiled build with no bundled package config, for instance).
This never applies to a frame outside your own app's code, and it fails silently (no context, not
an exception) for any file that can't be read for whatever reason.

This is a real, deliberate exception to "off by default is safer": literal source code is being
transmitted, not just a reference to it, and the real protection here isn't this field. Every
project on ForgeOps has its own setting (on by default, off durably and immediately once an org
owner turns it off, regardless of what any individual app's own local `Configuration` is still set
to) that governs whether the server will ever actually store what a client sends. Set
`captureSourceContext` to `false` if you'd rather this client never even attempt the disk read in
the first place:

```dart
forge_ops_tracker.init((config) => config.captureSourceContext = false);
```

## PII scrubbing

The message, backtrace, and any context you attach are scanned for likely personal data (email
addresses, formatted SSNs/credit cards, known API key/token formats, and anything under a
suspiciously-named key like `password`, `api_key`, or `ssn`) and redacted before the
payload ever leaves this process. ForgeOps itself scrubs again on arrival regardless, so this is a
second, earlier layer, not the only one. The user attached via `captureException`'s `user`
argument, `setUser`, or `runWithUser` above is a deliberate exception: it's never scrubbed, since
redacting it would defeat the whole point of identifying users in the first place.

To disable it:

```dart
forge_ops_tracker.init((config) => config.scrubPii = false);
```

## Strict privacy

For apps that can't let personal or health data (PII, PHI) leave their own process. With strict
privacy on, this client sends only structured facts about an error, never free text that could
carry a name, an email or a diagnosis:

```dart
forge_ops_tracker.init((config) {
  config.dsn = '...';
  config.strictPrivacy = true;
  config.privacyAllowedFields = ['error_code', 'feature'];
});
```

- An error event goes out without its message. It carries a `message_fingerprint` instead: a
  one-way hash of the message (as it would have been sent, so after PII scrubbing) with its
  numbers, ids, emails and quoted values taken out, computed in this process, so errors still group the same way.
- No breadcrumbs (`addBreadcrumb` records nothing), no SQL statement (even with
  `captureSqlStatement` on; the table and view names are still sent), and no source context.
- The user is sent as its `id` only, never `email` or `username`.
- Context and tags keep only the top-level keys listed in `privacyAllowedFields`, and only when the
  value is a string, number or bool. With none listed, neither is sent.
- Traces: an `http` span is named by its method and host (`GET api.example.com`), a span named
  after a path follows the path rule below, and span data keeps only `db.statement` (already
  masked) and `db.system`.
- A performance sample's transaction name that's a path follows the path rule below; any other name
  is kept.
- Paths: a route template (`/patients/:id/notes`, `/patients/{id}`, `/files/*path`) is kept as it
  is. A raw path keeps only its first segment, the rest becomes `:path`
  (`/patients/jane-doe/12` is `/patients/:path`), and a first segment holding a digit becomes `:id`.

The exception type, backtrace frames (file, line, function), release, environment, server and trace
id are unchanged, as are performance aggregates, metrics and recorded changes. The same applies to
errors `flutter_forge_ops_tracker` reports, since it reports through this client.

Both options can also come from the environment: `FORGE_OPS_STRICT_PRIVACY=true` and
`FORGE_OPS_PRIVACY_ALLOWED_FIELDS=error_code,feature` (comma separated). A value set in `init` wins
over the environment.

ForgeOps applies the same rules again on arrival when the project's own Strict privacy setting is
on, so an app running an older client, or one configured without this, still can't get text stored
for that project.

## Database errors

When an error carries the SQL behind a failed local database call, the event includes the names of the tables and views (and any stored procedure) that SQL touched, so the issue tells you where to start looking. This is on by default and sends identifiers only, never values. The statement is read from `package:sqlite3`'s `SqliteException.causingStatement`, or from the error text sqflite and SQLite produce (`sql '...' args [...]`, `Causing statement: ...`, `while compiling: ...`), including through a wrapping exception's `cause`.

To also send the SQL statement itself, opt in. Every string and number is replaced by `?` before it
leaves your process (`WHERE email = 'a@b.co' AND id = 42` is sent as `WHERE email = ? AND id = ?`),
and ForgeOps masks it again on arrival:

```dart
forge_ops_tracker.init((config) {
  config.captureSqlStatement = true; // default false
  // config.captureSqlObjects = false; // default true; false stops even the names
});
```

Each ForgeOps project also has its own "Capture the SQL behind database errors" setting. Turn it off
there and the statement is never stored for that project, whatever this flag says; the names are
still kept. A view and a table are written the same way in SQL, so both show as tables/views; the
database's own error message usually settles which it was.

## Running the tests

```bash
cd sdks/dart
dart pub get
dart test
dart analyze

cd flutter_forge_ops_tracker
flutter pub get
flutter test
flutter analyze
```
