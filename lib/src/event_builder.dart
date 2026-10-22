import 'dart:io';
import 'dart:isolate';

import 'configuration.dart';
import 'pii_scrubber.dart' as pii_scrubber;
import 'sql_statement.dart';
import 'strict_privacy.dart' as strict_privacy;

/// Turns a caught error/[StackTrace] pair into the payload shape the ingestion API expects.
///
/// A Dart [StackTrace] has no structured frame API at all: unlike Python's `traceback`, Java's
/// `Throwable.getStackTrace()`, or Go's `runtime.Callers`, the only thing available is
/// [StackTrace.toString], a multi-line format like:
///
///     #0      ChargeService.chargeCard (package:my_app/charge_service.dart:42:7)
///     #1      main (package:my_app/main.dart:10:3)
///
/// so this parses that format with a regex, the same situation the Ruby/PHP/Node clients are in
/// for their own languages. Verified directly against real caught-and-rethrown stack traces
/// before relying on this shape, not assumed from Dart's own (informal, undocumented) format
/// alone: see `EventBuilderTest` for the exact input this was checked against.
class EventBuilder {
  EventBuilder(this._configuration);

  final Configuration _configuration;

  static const int _maxFrames = 500;

  /// How many lines of source to grab on either side of an in-app frame's culprit line (see
  /// [_attachSourceContext]), and the longest a single captured line is allowed to be before
  /// getting truncated: guards against a single pathological minified/generated line ballooning
  /// the payload. ForgeOps itself re-truncates on arrival too, the same "don't just trust the
  /// client" posture `_maxFrames` already gets on the server side.
  static const int _contextLines = 5;
  static const int _maxContextLineLength = 500;

  /// Identifies this client to the server's auto language-detection on the project the event
  /// lands in (see `Project#note_sdk_platform` server-side); matches this repo's own sdks/dart
  /// directory name, the same convention every other language's client follows.
  static const String _sdkName = 'dart';

  static final RegExp _frameLine = RegExp(r'^\s*#\d+\s+(\S.*?)\s+\((.+)\)\s*$');
  static final RegExp _fileAndLine = RegExp(r'^(.+):(\d+):(\d+)$');

  Map<String, Object?> build(
    Object error,
    StackTrace? stackTrace, {
    Map<String, Object?>? context,
    Map<String, Object?>? user,
    List<Map<String, Object?>>? breadcrumbs,
    String? traceId,
  }) {
    final payload = <String, Object?>{
      'exception_class': error.runtimeType.toString(),
      'message': error.toString(),
      'backtrace': _backtrace(stackTrace),
      'occurred_at': DateTime.now().toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z'),
      'environment': _configuration.environment,
      'release': _configuration.release,
      'server_name': _configuration.serverName,
      'context': context ?? const {},
      'tags': const {},
      'sdk_name': _sdkName,
      // Omitted entirely (never sent as an empty list) when there's nothing to report, matching
      // every other client's own wire format: `breadcrumbs` scrubs the same general way as
      // everything else in this payload (see this class's own scrub call just below), unlike
      // `sdks/go`/`sdks/elixir`, which exempt category/level/timestamp from scrubbing by hand.
      // This client's own `pii_scrubber.scrub` has no such per-field exemption anywhere already
      // (`environment`/`sdk_name`/etc. all go through the same blanket call), so keeping
      // breadcrumbs consistent with that existing, generic design is the idiomatic choice here,
      // not importing a different client's own more surgical approach; the patterns themselves
      // are targeted enough (email/SSN/card/token shapes) that a plain value like "controller" or
      // "info" never matches any of them in practice.
      if (breadcrumbs != null && breadcrumbs.isNotEmpty) 'breadcrumbs': breadcrumbs,
    };

    _attachSql(payload, error);

    final scrubbed = _configuration.scrubPii ? pii_scrubber.scrub(payload) as Map<String, Object?> : payload;

    // Merged in after scrubbing, never before: `pii_scrubber.scrub` recurses over an entire
    // payload by value-pattern alone with no key-name exemption list, so a "user" entry present
    // before that call would have its own email value redacted by the EMAIL pattern just like any
    // other string. Merging it in afterward is what keeps it exempt, matching every other client
    // in this repo's "the user field is deliberately never redacted" precedent.
    // The trace id likewise: the W3C id of the trace this error happened in (see TraceParent), which
    // is what links it to errors other projects reported for the same request. A structured id this
    // client generated or continued, not free text, so it must arrive intact. Omitted outside a trace.
    final built = {
      ...scrubbed,
      if (user != null && user.isNotEmpty) 'user': user,
      if (traceId != null) 'trace_id': traceId,
    };
    if (!_configuration.strictPrivacy) return built;

    // Fingerprinted from the message as it would otherwise have been sent (scrubbed, when scrubPii
    // is on), so it matches what the server fingerprints from a client without strict privacy, and
    // a message holding an email still groups as one.
    final fingerprint = strict_privacy.messageFingerprint(scrubbed['message'] as String?);
    return strict_privacy.strictEvent(built, fingerprint, _configuration.privacyAllowedFields);
  }

  // See sql_statement.dart for what's read off the error and how it's masked. The statement itself
  // only goes out when captureSqlStatement is on; the extracted names go out on their own
  // (captureSqlObjects) so an issue can still name the table or view involved. Scrubbed with
  // everything else in the payload, like every other field.
  void _attachSql(Map<String, Object?> payload, Object error) {
    if (!_configuration.captureSqlObjects && !_configuration.captureSqlStatement) return;

    final masked = maskSql(findSqlIn(error));
    if (masked == null) return;

    final objects = sqlObjects(masked);
    if (objects != null && _configuration.captureSqlObjects) payload['sql_objects'] = objects;
    if (_configuration.captureSqlStatement && !_configuration.strictPrivacy) payload['sql_statement'] = masked;
  }

  List<Map<String, Object?>> _backtrace(StackTrace? stackTrace) {
    if (stackTrace == null) return const [];

    final frames = <Map<String, Object?>>[];
    for (final line in stackTrace.toString().split('\n')) {
      if (frames.length >= _maxFrames) break;

      final match = _frameLine.firstMatch(line);
      if (match == null) continue; // an unparseable line is skipped, not an error: see PHP's own client for the same philosophy

      final method = match.group(1)!;
      final location = match.group(2)!;
      final (file, lineNumber) = _splitFileAndLine(location);

      frames.add(_attachSourceContext({
        'file': file,
        'line': lineNumber,
        'method': method,
        'in_app': _isInApp(file),
      }));
    }
    return frames;
  }

  (String, int?) _splitFileAndLine(String location) {
    final match = _fileAndLine.firstMatch(location);
    if (match == null) return (location, null);
    return (match.group(1)!, int.tryParse(match.group(2)!));
  }

  /// A `dart:...` location is always core (the Dart SDK itself); a `package:<name>/...` location
  /// is `in_app` only if `<name>` matches [Configuration.packageName]: every other package
  /// (including a third-party pub dependency) is never `in_app`, regardless of configuration.
  bool _isInApp(String file) {
    final packageName = _configuration.packageName;
    if (packageName == null || packageName.isEmpty) return false;
    return file.startsWith('package:$packageName/');
  }

  /// Reads a few lines of source straight off disk around the culprit line, at capture time, in
  /// the same running process the error came from. Gated on two things: the frame has to be
  /// in-app (never a third-party dependency or the Dart SDK itself: there'd be nothing
  /// meaningful of the host app's own to show), and [Configuration.captureSourceContext] has to
  /// be `true` (see `Configuration` for why it defaults to `true` and why ForgeOps' own
  /// per-project setting, not this field, is the durable, server-enforced way to turn it off).
  /// Best-effort: any location that can't be resolved to a real file, or a file that can't be
  /// read (moved, deleted, permission denied, an AOT build with no package-resolution or source
  /// available at all), just leaves the frame exactly as it was, never an exception of the
  /// reporting path itself.
  Map<String, Object?> _attachSourceContext(Map<String, Object?> frame) {
    if (!_configuration.captureSourceContext || _configuration.strictPrivacy || frame['in_app'] != true) return frame;

    final lineNumber = frame['line'] as int?;
    if (lineNumber == null) return frame;

    try {
      final path = _resolveFilePath(frame['file'] as String);
      if (path == null) return frame;

      final lines = File(path).readAsLinesSync();
      final index = lineNumber - 1;
      if (index < 0 || index >= lines.length) return frame;

      final from = index - _contextLines < 0 ? 0 : index - _contextLines;
      final to = index + _contextLines >= lines.length ? lines.length - 1 : index + _contextLines;

      return {
        ...frame,
        'context_line': _truncateLine(lines[index]),
        'pre_context': lines.sublist(from, index).map(_truncateLine).toList(),
        'post_context': lines.sublist(index + 1, to + 1).map(_truncateLine).toList(),
      };
    } catch (_) {
      // Covers a missing/unreadable file (FileSystemException) as well as a `package:` location
      // that can't be resolved at all in this environment (Isolate.resolvePackageUriSync throws
      // rather than returning null on some AOT-compiled builds): either way, this one frame
      // just doesn't get source context, nothing here is allowed to take down error reporting
      // itself.
      return frame;
    }
  }

  /// Resolves a backtrace frame's `file` (a `package:<name>/...` or `file://...` location, per
  /// Dart's own [StackTrace] format: see this class's own doc comment) to a real filesystem
  /// path, or `null` if it can't be resolved. A `package:` location has no filesystem path of its
  /// own; it only means something once resolved against the running isolate's own package
  /// configuration.
  String? _resolveFilePath(String file) {
    final uri = Uri.parse(file);
    if (uri.scheme == 'package') return Isolate.resolvePackageUriSync(uri)?.toFilePath();
    if (uri.scheme == 'file') return uri.toFilePath();
    return file; // already a bare filesystem path
  }

  String _truncateLine(String line) {
    if (line.length <= _maxContextLineLength) return line;
    return '${line.substring(0, _maxContextLineLength)}...';
  }
}
