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
  'iban', 'accountnumber', 'routingnumber', 'bankaccount',
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

// Card numbers in any other shape, and IBANs: see sdks/PII_SCRUBBING.md, which every SDK follows,
// and sdks/pii_scrubbing_vectors.json (a copy is in test/fixtures), which pins the results.
final RegExp _digitRun = RegExp(r'(?<![A-Za-z0-9_])[0-9](?:[ -]?[0-9])*(?![A-Za-z0-9_])');
final RegExp _cardPrefixes = RegExp(
  r'^(?:4|5[1-5]|2(?:22[1-9]|2[3-9][0-9]|[3-6][0-9][0-9]|7[01][0-9]|720)|3[47]|6011|64[4-9]|65'
  r'|35(?:2[89]|[3-8][0-9])|36|30[0-5]|62)',
);
final RegExp _iban = RegExp(r'\b[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)\b');

/// Runs every pattern above over a single string, independent of any key: used both directly (a
/// message, a stack frame's file/method) and as the leaf case of [scrub] below. IBANs go first (a
/// spaced IBAN's middle groups look like a formatted card number), card numbers in any other
/// shape last.
String scrubString(String text) {
  var result = text.replaceAllMapped(_iban, (match) => _isIban(match[0]!) ? '[IBAN FILTERED]' : match[0]!);
  for (final (label, pattern) in _patterns) {
    result = result.replaceAll(pattern, '[$label FILTERED]');
  }
  return result.replaceAllMapped(_digitRun, (match) => _scrubCardNumbersIn(match[0]!));
}

/// From each group of the run on, the longest stretch of whole groups that is a card number is
/// replaced, so a card followed by its CVV, two cards in a row, and Amex's 4-6-5 are all found.
String _scrubCardNumbersIn(String run) {
  final digits = run.split(RegExp('[ -]'));
  final separators = [for (final match in RegExp('[ -]').allMatches(run)) match[0]!];
  final out = StringBuffer();
  var i = 0;
  while (i < digits.length) {
    var j = digits.length - 1;
    while (j >= i && !_isCardNumber(digits.sublist(i, j + 1).join())) {
      j -= 1;
    }
    if (j >= i) {
      out
        ..write('[CREDIT CARD FILTERED]')
        ..write(j < separators.length ? separators[j] : '');
      i = j + 1;
    } else {
      out
        ..write(digits[i])
        ..write(i < separators.length ? separators[i] : '');
      i += 1;
    }
  }
  return out.toString();
}

bool _isCardNumber(String digits) =>
    digits.length >= 13 && digits.length <= 19 && _cardPrefixes.hasMatch(digits) && _luhn(digits);

bool _luhn(String digits) {
  var sum = 0;
  for (var index = 0; index < digits.length; index++) {
    var value = digits.codeUnitAt(digits.length - 1 - index) - 0x30;
    if (index.isOdd) {
      value *= 2;
      if (value > 9) value -= 9;
    }
    sum += value;
  }
  return sum % 10 == 0;
}

/// The IBAN check, a digit at a time: the first four characters moved to the end, letters as two
/// digits (A is 10), and the remainder by 97 is 1.
bool _isIban(String candidate) {
  final compact = candidate.replaceAll(' ', '');
  if (compact.length < 15 || compact.length > 34) return false;
  var remainder = 0;
  for (final unit in (compact.substring(4) + compact.substring(0, 4)).codeUnits) {
    final asDigits = unit >= 0x41 && unit <= 0x5A ? '${unit - 55}' : String.fromCharCode(unit);
    for (final digit in asDigits.codeUnits) {
      remainder = (remainder * 10 + digit - 0x30) % 97;
    }
  }
  return remainder == 1;
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
