/// Redacts likely-sensitive content out of a payload before it ever leaves this process: the
/// same patterns ForgeOps itself applies again on arrival (defense in depth: this layer keeps the
/// data off the wire and out of any request logging in between; the server-side layer is what
/// actually protects the database, and doesn't depend on every reporting app running an
/// up-to-date version of this client). Ported from
/// `gems/forge_ops_tracker/lib/forge_ops_tracker/pii_scrubber.rb`: same key list, same 8 regex
/// patterns, same `"[LABEL FILTERED]"` replacement format.
///
/// Can be turned off via `Configuration.scrubPii = false` for a host app that already scrubs its
/// own data before it ever reaches error context, or that has its own reasons to want the raw
/// payload. Off by default is not an option: the safe default has to be "on."
library;

const String redacted = '[FILTERED]';

const Set<String> _sensitiveKeys = {
  'password', 'passwd', 'pwd', //
  'secret', 'apisecret', 'clientsecret', 'secretkey',
  'token', 'accesstoken', 'refreshtoken', 'apikey', 'apitoken', 'authorization', 'authtoken',
  'bearer', 'sessiontoken', 'csrftoken',
  'creditcard', 'cardnumber', 'cardnum', 'cvv', 'cvv2', 'cvc',
  'ssn', 'socialsecuritynumber', 'socialsecurity',
  'privatekey',
};

final List<(String, RegExp)> _patterns = [
  ('EMAIL', RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}')),
  ('SSN', RegExp(r'\b\d{3}-\d{2}-\d{4}\b')),
  ('CREDIT CARD', RegExp(r'\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,4}\b')),
  ('BEARER TOKEN', RegExp(r'\bBearer\s+[A-Za-z0-9\-._~+/]+=*', caseSensitive: false)),
  ('JWT', RegExp(r'\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b')),
  ('AWS KEY', RegExp(r'\bAKIA[0-9A-Z]{16}\b')),
  ('STRIPE KEY', RegExp(r'\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}\b')),
  ('GITHUB TOKEN', RegExp(r'\bgh[pousr]_[A-Za-z0-9]{20,}\b')),
];

/// Runs every pattern above over a single string, independent of any key: used both directly (a
/// message, a stack frame's file/method) and as the leaf case of [scrub] below.
String scrubString(String text) {
  var result = text;
  for (final (label, pattern) in _patterns) {
    result = result.replaceAll(pattern, '[$label FILTERED]');
  }
  return result;
}

/// Redacts [value] based on [key] (an entire value redacted wholesale if key looks sensitive,
/// regardless of type) and recurses into maps/lists, matching every other client's behavior in
/// this repo. [value] may be a `String`, `Map`, `List`, or anything else (passed through
/// unchanged). [key] is the enclosing map key `value` was found under (null for a bare top-level
/// value or a list element), and is what the key-name check runs against.
Object? scrub(Object? value, {String? key}) {
  if (value != null && _isSensitiveKey(key)) {
    return redacted;
  }

  if (value is Map) {
    return {for (final entry in value.entries) entry.key.toString(): scrub(entry.value, key: entry.key.toString())};
  }
  if (value is List) {
    return [for (final item in value) scrub(item, key: key)];
  }
  if (value is String) {
    return scrubString(value);
  }
  return value;
}

bool _isSensitiveKey(String? key) {
  if (key == null || key.isEmpty) return false;
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return _sensitiveKeys.any(normalized.contains);
}
