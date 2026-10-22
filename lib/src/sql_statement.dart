/// Finds the SQL behind a database error and reduces it to something safe to send: the names of
/// the stored procedures, tables and views it touched, and (only if
/// [Configuration.captureSqlStatement] is on) the statement itself with every string and number
/// replaced by `?`. Ported from `sdks/node`'s `sqlStatement.js`, which is itself ported from the
/// server's own `SqlStatementMasker`/`SqlObjectExtractor`: same rules everywhere, and the server
/// applies them again on arrival, so a difference here can only ever mean less is masked
/// client-side, never that something unmasked gets stored.
///
/// Deliberately a single pass over a few patterns, not a SQL parser. What it recognizes:
///   * 'single quoted' strings, with `''` or a backslash as the escape (`'it''s'`, `'o\'brien'`),
///     including one cut off by truncation, even right after a backslash (masked to the end,
///     never left half-visible)
///   * a string's type prefix along with it (`E''`, `X''`, `N''`, `B''`, `U&''`), so
///     `X'DEADBEEF'` is one `?`
///   * `$tag$` dollar-quoted strings (PostgreSQL function bodies and DO blocks)
///   * numbers: integers, decimals, exponents (`3e10`, `1.5E-3`), hex (`0x1F`) and binary
///     (`0b101`), but never the digits inside an identifier (`orders2`, `$1` placeholders, `sp_v2`)
///   * "double quoted" strings, but only for MySQL and MariaDB, where that's a string rather than
///     a name; everywhere else a column named "user id" is left alone
///
/// No regex lookbehind: the same reasoning `sdks/node` documents for its own port, since Dart
/// also compiles to JavaScript for Flutter web. The server only takes a prefix, and only counts a
/// number, when the character before it isn't part of a word, so [maskSql] checks that character
/// itself and, when it is, does what a failed lookbehind does: no match there, and the search
/// goes on one character later.
///
/// On Dart the SQL comes from a local SQLite database, so the sources are a property on the error
/// (`package:sqlite3`'s `SqliteException.causingStatement`, read dynamically so this client never
/// depends on that package) and the error's own text (sqflite's `sql '...' args [...]`,
/// sqlite3's `Causing statement: ...`, SQLite's `while compiling: ...`). Best-effort by nature:
/// an error with none of these simply has no statement to find.
library;

const String _mask = '?';
const int maxSqlLength = 4000;
const int _maxNames = 10;
const int _maxNameLength = 200;
const int _maxCauseDepth = 5;

const String _string = r"(?:[EeXxNnBb]|[Uu]&)?'(?:[^'\\]|\\(?:[\s\S]|$)|'')*(?:'|$)";
const String _doubleQuotedString = r'"(?:[^"\\]|\\(?:[\s\S]|$)|"")*(?:"|$)';
const String _dollarQuoted = r'(\$[A-Za-z_]*\$)[\s\S]*?(?:\1|$)';
const String _number =
    r'(0[xX][0-9a-fA-F]+|0[bB][01]+|(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)(?!\w)';
// Group 1: dollar-quote tag. 2: a number. A match with neither is a string literal.
final RegExp _literal = RegExp('$_string|$_dollarQuoted|$_number');
final RegExp _literalWithDoubleQuotes =
    RegExp('$_string|$_doubleQuotedString|$_dollarQuoted|$_number');
// db.system values where "double quotes" are a string, not a name.
const Set<String> _doubleQuotedStringSystems = {'mysql', 'mariadb'};
final RegExp _partOfWord = RegExp(r'[\w$]');
final RegExp _partOfNumberOrWord = RegExp(r'[\w$.]');
final RegExp _stringPrefix = RegExp(r"^(?:[EeXxNnBb]|[Uu]&)'");

const String _part = r'(?:[\w$#@]+|"[^"]+"|\[[^\]]+\]|`[^`]+`)';
const String _name = '$_part(?:\\.$_part)*';
const Set<String> _operations = {
  'SELECT',
  'INSERT',
  'UPDATE',
  'DELETE',
  'MERGE',
  'WITH',
  'CALL',
  'EXEC',
  'EXECUTE',
  'CREATE',
  'ALTER',
  'DROP',
  'TRUNCATE',
};
final RegExp _procedureCall = RegExp(
  '\\b(?:CALL|EXEC(?:UTE)?|PERFORM)\\s+(?!IMMEDIATE\\b|FUNCTION\\b|PROCEDURE\\b)($_name)',
  caseSensitive: false,
);
final RegExp _relation = RegExp(
    '\\b(FROM|JOIN|INTO|UPDATE|TABLE)\\s+($_name)(\\s*\\()?',
    caseSensitive: false);
final RegExp _selectFunction =
    RegExp('^\\s*SELECT\\s+($_name)\\s*\\(', caseSensitive: false);
const Set<String> _builtins = {
  'count',
  'sum',
  'min',
  'max',
  'avg',
  'now',
  'coalesce',
  'nullif',
  'lower',
  'upper',
  'length',
  'concat',
  'cast',
  'date_trunc',
  'current_timestamp',
  'current_date',
  'row_number',
  'rank',
  'json_build_object',
  'json_agg',
  'array_agg',
};
final RegExp _fromInsideFunction = RegExp(
    r'\b(?:EXTRACT|SUBSTRING|TRIM|OVERLAY)\s*\([^()]*\)',
    caseSensitive: false);
const Set<String> _keywordsNotNames = {
  'select',
  'set',
  'values',
  'where',
  'lateral',
  'only',
  'unnest',
  'generate_series'
};
final RegExp _fullName = RegExp('^$_name\$');
final RegExp _fromWord = RegExp(r'\bFROM\b', caseSensitive: false);
final RegExp _firstWord = RegExp(r'^\s*(\w+)');

// sqflite's exception text ends `sql 'SELECT ...' args [...]`; sqlite3's has a `Causing statement:`
// line, optionally followed by `, parameters:` (the values, deliberately never read); SQLite's own
// text ends `while compiling: SELECT ...`.
final List<RegExp> _textPatterns = [
  RegExp(r"sql '(.*)' args \[", dotAll: true),
  RegExp(r'Causing statement:\s*(.*?)(?:, parameters:|$)', dotAll: true),
  RegExp(r'while compiling:\s*(.+?)\s*$', dotAll: true),
];

/// Property names database wrappers put the failing statement on, tried dynamically.
const List<String> _statementProperties = [
  'causingStatement',
  'sql',
  'statement'
];

/// The raw statement off the error itself or, for an app that wraps a database error in its own,
/// off whatever it was raised from (a `cause`/`inner` property).
String? findSqlIn(Object? error) {
  Object? current = error;
  for (var depth = 0; current != null && depth < _maxCauseDepth; depth++) {
    final fromProperty = _statementProperty(current);
    if (fromProperty != null) return fromProperty;

    final fromText = findSqlInText(current.toString());
    if (fromText != null) return fromText;

    current = _causeOf(current);
  }
  return null;
}

String? findSqlInText(String text) {
  for (final pattern in _textPatterns) {
    final statement = pattern.firstMatch(text)?.group(1);
    if (statement != null && statement.trim().isNotEmpty) return statement;
  }
  return null;
}

String? _statementProperty(Object error) {
  for (final property in _statementProperties) {
    try {
      final dynamic value = switch (property) {
        'causingStatement' => (error as dynamic).causingStatement,
        'sql' => (error as dynamic).sql,
        _ => (error as dynamic).statement,
      };
      if (value is String && value.trim().isNotEmpty) return value;
    } catch (_) {
      // Not a readable property on this type: not a source of SQL, keep looking.
    }
  }
  return null;
}

Object? _causeOf(Object error) {
  for (final read in <Object? Function()>[
    () => (error as dynamic).cause,
    () => (error as dynamic).inner,
    () => (error as dynamic).innerError,
  ]) {
    try {
      final cause = read();
      if (cause != null && !identical(cause, error)) return cause;
    } catch (_) {
      // No such property: try the next name.
    }
  }
  return null;
}

/// [system] is the statement's `db.system`, when known: for `mysql` or `mariadb`, "double quoted"
/// text is masked too.
String? maskSql(String? statement, {String? system}) {
  if (statement == null || statement.trim().isEmpty) return null;
  final pattern =
      _doubleQuotedStringSystems.contains((system ?? '').toLowerCase())
          ? _literalWithDoubleQuotes
          : _literal;
  final buffer = StringBuffer();
  var copied = 0;
  var start = 0;
  while (true) {
    final match = pattern.allMatches(statement, start).firstOrNull;
    if (match == null) break;
    final before = match.start > 0 ? statement[match.start - 1] : '';
    final lookbehindFails = match.group(2) != null
        ? _partOfNumberOrWord.hasMatch(before)
        : _stringPrefix.hasMatch(match[0]!) && _partOfWord.hasMatch(before);
    if (lookbehindFails) {
      // What a failed lookbehind does: nothing matches here, so try again one character on
      // (LIKE'%x%' then matches at the quote, and 1e+5 inside a word still masks the 5).
      start = match.start + 1;
      continue;
    }
    buffer
      ..write(statement.substring(copied, match.start))
      ..write(_mask);
    copied = start = match.end;
  }
  buffer.write(statement.substring(copied));
  final masked = buffer.toString();
  return masked.length > maxSqlLength
      ? '${masked.substring(0, maxSqlLength)}...'
      : masked;
}

/// Takes an already-masked statement (so a keyword inside a string value can't be mistaken for
/// SQL). Returns `null` when nothing recognizable was found.
Map<String, Object?>? sqlObjects(String? masked) {
  if (masked == null || masked.trim().isEmpty) return null;

  final sql = masked.replaceAll(_fromInsideFunction, ' ');
  final procedures =
      _procedureCall.allMatches(sql).map((m) => m.group(1)!).toList();
  final relations = <String>[];

  for (final match in _relation.allMatches(sql)) {
    final name = match.group(2)!;
    if (_keywordsNotNames.contains(name.toLowerCase())) continue;
    final keyword = match.group(1)!.toUpperCase();
    final functionCall = (match.group(3) ?? '').isNotEmpty &&
        (keyword == 'FROM' || keyword == 'JOIN');
    (functionCall ? procedures : relations).add(name);
  }

  final function = _selectFunction.firstMatch(sql)?.group(1);
  if (function != null &&
      !_builtins.contains(function.toLowerCase()) &&
      !_fromWord.hasMatch(sql)) {
    procedures.add(function);
  }

  final operation = (_firstWord.firstMatch(sql)?.group(1) ?? '').toUpperCase();
  final cleanProcedures = _clean(procedures);
  final cleanRelations = _clean(relations);
  if (cleanProcedures.isEmpty &&
      cleanRelations.isEmpty &&
      !_operations.contains(operation)) return null;
  return {
    if (_operations.contains(operation)) 'operation': operation,
    'procedures': cleanProcedures,
    'relations': cleanRelations,
  };
}

List<String> _clean(List<String> names) {
  final cleaned = <String>[];
  for (final raw in names) {
    var name = raw.trim();
    if (name.length > _maxNameLength) name = name.substring(0, _maxNameLength);
    if (_fullName.hasMatch(name) && !cleaned.contains(name)) cleaned.add(name);
  }
  return cleaned.take(_maxNames).toList();
}
