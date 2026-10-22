/// Strict privacy ([Configuration.strictPrivacy]): for apps that can't let personal or health data
/// leave their own process. Only structured facts about an error are sent (its type, its stack
/// frames, release, environment, server, trace id, timings and counts), never free text that could
/// carry a name, an email or a diagnosis: no message, breadcrumbs, SQL statement, source context,
/// or user email/username, and only the context/tag keys listed in
/// [Configuration.privacyAllowedFields]. Ported from the server's own
/// `app/services/strict_privacy.rb`, which applies the same rules again on arrival;
/// `sdks/strict_privacy_vectors.json` pins the results both have to agree on.
///
/// Errors still group without their message: `message_fingerprint` is a one-way hash of the message
/// with its numbers and ids taken out, computed here, in this process. The SHA-256 below is
/// self-contained, since this package has no dependencies (`package:crypto` included).
library;

import 'dart:convert';

const int fingerprintLength = 32;

// ASCII "word" characters only, spelled out rather than \w so no engine's own idea of a word
// changes the result: the same in every SDK and on the server.
final RegExp _hexObjectId = RegExp(r'0x[0-9a-fA-F]{4,}');
final RegExp _uuid = RegExp(
    r'(?<![A-Za-z0-9_])[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?![A-Za-z0-9_])');
final RegExp _number = RegExp(r'(?<![A-Za-z0-9_])[0-9]+(?![A-Za-z0-9_])');
final RegExp _httpMethod = RegExp(r'^(GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS)\s+(\S+)', caseSensitive: false);
final RegExp _scheme = RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false);
final RegExp _port = RegExp(r':[0-9]+$');

/// A route parameter segment: `:id`, `{id}`, `<int:id>`, `[slug]` or `*path` (`[^\n]` rather than
/// `.` so the match is the server's exactly).
final RegExp _routeParameter = RegExp(r'^(?::[^\n]+|\{[^\n]+\}|<[^\n]+>|\[[^\n]+\]|\*[^\n]*)$');

/// Span data that's structure, not content: the masked statement and which database it ran on.
const List<String> _spanDataKeys = ['db.statement', 'db.system'];

/// Free text never sent in an error event; context, tags and user are rebuilt from what's allowed.
const List<String> _droppedEventFields = ['message', 'breadcrumbs', 'sql_statement', 'endpoint', 'context', 'tags', 'user'];
const List<String> _sourceContextFields = ['context_line', 'pre_context', 'post_context'];

/// The message with hex object ids, UUIDs and standalone numbers replaced, in that order.
String normalizeMessage(String? message) =>
    (message ?? '').replaceAll(_hexObjectId, '0x').replaceAll(_uuid, '<uuid>').replaceAll(_number, '<n>');

/// First 32 hex characters of the SHA-256 of the normalized message's UTF-8 bytes.
String messageFingerprint(String? message) =>
    sha256Hex(utf8.encode(normalizeMessage(message))).substring(0, fingerprintLength);

/// An error event's payload, reduced to what strict privacy keeps. [fingerprint] is computed from
/// the message as it would otherwise have been sent (after PII scrubbing, when that's on).
Map<String, Object?> strictEvent(Map<String, Object?> payload, String fingerprint, List<String> allowedFields) {
  final context = _allowed(payload['context'], allowedFields);
  final tags = _allowed(payload['tags'], allowedFields);
  final user = _userId(payload['user']);
  return {
    for (final entry in payload.entries)
      if (!_droppedEventFields.contains(entry.key)) entry.key: entry.value,
    'message_fingerprint': fingerprint,
    'backtrace': [
      for (final frame in (payload['backtrace'] as List?) ?? const [])
        {
          for (final entry in (frame as Map<String, Object?>).entries)
            if (!_sourceContextFields.contains(entry.key)) entry.key: entry.value,
        },
    ],
    if (context != null) 'context': context,
    if (tags != null) 'tags': tags,
    if (user != null) 'user': user,
  };
}

/// A finished trace with every span reduced: an outbound call's name keeps its method and host,
/// never its path or query, and span data keeps only the masked statement and database system.
Map<String, Object?> strictTrace(Map<String, Object?> trace) => {
      ...trace,
      'spans': [for (final span in (trace['spans'] as List?) ?? const []) strictSpan(span as Map<String, Object?>)],
    };

/// One span, reduced as [strictTrace] describes.
Map<String, Object?> strictSpan(Map<String, Object?> span) {
  final data = span['data'];
  return {
    ...span,
    'name': spanName(span['name'] as String? ?? ''),
    'data': <String, Object?>{
      if (data is Map)
        for (final key in _spanDataKeys)
          if (data[key] != null) key: data[key],
    },
  };
}

/// `"GET https://api.example.com/patients/42?x=1"` or `"GET api.example.com/patients/42"` becomes
/// `"GET api.example.com"`; a method and a path (`"GET /patients/42/notes"`) or a bare path
/// (`"/patients/jane-doe"`) goes through [strictPath]: `"GET /patients/:path"`, `"/patients/:path"`,
/// while a route template (`"GET /patients/:id"`) is kept. A name that isn't a call or a path
/// (`"job:reindex"`, `"patients#show"`) is kept. Also how a transaction name is reduced.
String spanName(String name) {
  if (name.startsWith('/')) return strictPath(name);
  final match = _httpMethod.firstMatch(name);
  if (match == null) return name;

  final method = match.group(1)!.toUpperCase();
  final target = match.group(2)!;
  if (target.startsWith('/')) return '$method ${strictPath(target)}';
  return '$method ${_hostOf(target) ?? strictPath(target)}';
}

/// A request or page path under strict privacy, with no query or fragment. A route template
/// (`"/patients/:id/notes"`, `"/patients/{id}"`, `"users/<int:id>/"`, `"/files/*path"`,
/// `"/posts/[slug]"`) is kept as it is: its words are a developer's, and its parameters are already
/// placeholders. A raw path keeps only its first segment, and the rest becomes `:path`:
/// `"/patients/jane-doe/12"` is `"/patients/:path"`, since anything after the first segment could
/// name a person and no rule can tell a name from a word. A first segment that holds a digit or is
/// over 40 characters is `:id`.
String strictPath(String path) {
  final text = path.split(RegExp(r'[?#]')).first;
  if (text.split('/').any(_routeParameter.hasMatch)) return text;
  final leading = text.startsWith('/') ? '/' : '';
  final segments = text.split('/').where((segment) => segment.isNotEmpty).toList();
  if (segments.isEmpty) return '/';
  final head = segments.first;
  final first = head.contains(RegExp(r'[0-9]')) || head.runes.length > 40 ? ':id' : head;
  return '$leading$first${segments.length > 1 ? '/:path' : ''}';
}

/// The host of an outbound call's address, read by hand rather than with [Uri.parse] (one that
/// rejects an odd address must never lead to the whole address being sent): whatever comes before
/// the first `/`, `?` or `#`, without a scheme, port, or credentials (up to the last `@`: a
/// password can hold one, a host never does). It's a host when the address had a scheme or a port,
/// or the name has a dot or is `localhost`; otherwise (a relative path) `null`.
String? _hostOf(String target) {
  final hadScheme = target.startsWith(_scheme);
  final authority = target.replaceFirst(_scheme, '').split(RegExp(r'[/?#]')).first.replaceFirst(RegExp(r'^.*@'), '');
  final hadPort = authority.contains(_port);
  final host = authority.replaceFirst(_port, '');
  if (host.isEmpty) return null;
  return hadScheme || hadPort || host.contains('.') || host.toLowerCase() == 'localhost' ? host : null;
}

Map<String, Object?>? _allowed(Object? fields, List<String> allowedFields) {
  if (fields is! Map || allowedFields.isEmpty) return null;
  final kept = <String, Object?>{
    for (final key in allowedFields)
      if (fields[key] is String || fields[key] is num || fields[key] is bool) key: fields[key],
  };
  return kept.isEmpty ? null : kept;
}

Map<String, Object?>? _userId(Object? user) {
  if (user is! Map) return null;
  final id = user['id'];
  if (id == null || id == false || id.toString().trim().isEmpty) return null;
  return {'id': id.toString()};
}

/// `FORGE_OPS_STRICT_PRIVACY`'s value as a bool: `true`, `1`, `yes` or `on` (any case) turn it on.
bool envFlag(String? value) => const {'true', '1', 'yes', 'on'}.contains((value ?? '').trim().toLowerCase());

/// `FORGE_OPS_PRIVACY_ALLOWED_FIELDS`'s comma separated names, trimmed, blanks dropped.
List<String> envList(String? value) =>
    (value ?? '').split(',').map((name) => name.trim()).where((name) => name.isNotEmpty).toList();

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const int _mask32 = 0xffffffff;

int _rotr(int value, int bits) => ((value >> bits) | (value << (32 - bits))) & _mask32;

/// SHA-256 (FIPS 180-4) of [bytes], as 64 lowercase hex characters.
String sha256Hex(List<int> bytes) {
  final h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  // Padding: a 1 bit, zeros up to 56 bytes mod 64, then the message length in bits, big endian.
  final padded = [...bytes, 0x80];
  while (padded.length % 64 != 56) {
    padded.add(0);
  }
  final bitLength = bytes.length * 8;
  for (var shift = 56; shift >= 0; shift -= 8) {
    padded.add((bitLength >> shift) & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < padded.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final at = chunk + i * 4;
      w[i] = (padded[at] << 24) | (padded[at + 1] << 16) | (padded[at + 2] << 8) | padded[at + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ (~e & _mask32 & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & _mask32;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask32;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask32;
    }
    final next = [a, b, c, d, e, f, g, hh];
    for (var i = 0; i < 8; i++) {
      h[i] = (h[i] + next[i]) & _mask32;
    }
  }
  return h.map((word) => word.toRadixString(16).padLeft(8, '0')).join();
}
