import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:forge_ops_tracker/src/sql_statement.dart';
import 'package:test/test.dart';

/// Stands in for package:sqlite3's SqliteException, which exposes causingStatement.
class _FakeSqliteException implements Exception {
  _FakeSqliteException(this.causingStatement);
  final String causingStatement;
  @override
  String toString() => 'SqliteException(1): no such table: t';
}

/// Stands in for an app wrapper carrying the database error as .cause.
class _Wrapper implements Exception {
  _Wrapper(this.cause);
  final Object cause;
  @override
  String toString() => 'refund failed';
}

Configuration _config({bool objects = true, bool statement = false}) =>
    Configuration()
      ..environment = 'production'
      ..captureSqlObjects = objects
      ..captureSqlStatement = statement;

void main() {
  group('findSqlIn', () {
    test('reads causingStatement off the error and follows .cause', () {
      expect(findSqlIn(_FakeSqliteException('SELECT 1')), 'SELECT 1');
      expect(
          findSqlIn(_Wrapper(_FakeSqliteException('CALL x(1)'))), 'CALL x(1)');
    });

    test("reads sqflite's, sqlite3's and SQLite's own error text", () {
      expect(
        findSqlInText(
            "DatabaseException(no such table: t) sql 'SELECT * FROM t' args []"),
        'SELECT * FROM t',
      );
      expect(
        findSqlInText(
            'SqliteException(1): no such table\n  Causing statement: SELECT * FROM t, parameters: 1, 2'),
        'SELECT * FROM t',
      );
      expect(
        findSqlInText(
            'no such table: notes (code 1 SQLITE_ERROR): , while compiling: SELECT * FROM notes WHERE id = 42'),
        'SELECT * FROM notes WHERE id = 42',
      );
      expect(findSqlInText('just a plain error'), isNull);
    });

    test('returns null without SQL', () {
      expect(findSqlIn(StateError('nope')), isNull);
      expect(findSqlIn(null), isNull);
    });
  });

  group('maskSql', () {
    test('replaces strings and numbers, leaving identifiers and placeholders',
        () {
      expect(
        maskSql(
            r"SELECT * FROM orders2 WHERE email = 'a@b.co' AND id = 42 AND x = $1"),
        r'SELECT * FROM orders2 WHERE email = ? AND id = ? AND x = $1',
      );
      expect(maskSql('SELECT price * 1.5 FROM t WHERE a IN (1,2,3)'),
          'SELECT price * ? FROM t WHERE a IN (?,?,?)');
    });

    test('handles an escaped quote, a cut-off string and a dollar-quoted body',
        () {
      expect(maskSql("EXEC sp_x @t = 'it''s'"), 'EXEC sp_x @t = ?');
      expect(maskSql("SELECT 1 WHERE n = 'oops"), 'SELECT ? WHERE n = ?');
      expect(maskSql(r'DO $b$ BEGIN PERFORM 1; END $b$'), 'DO ?');
    });

    test('is idempotent, truncates, and returns null for blank input', () {
      final once = maskSql("SELECT * FROM t WHERE a = 'x' AND b = 9");
      expect(maskSql(once), once);
      expect(maskSql('SELECT ${'a, ' * 3000} b')!.length, maxSqlLength + 3);
      expect(maskSql('  '), isNull);
      expect(maskSql(null), isNull);
    });

    // The corpus every SDK's masker is checked against, embedded since this package is published
    // on its own: (statement, db.system, what the server's SqlStatementMasker produces).
    const corpus = <(String, String?, String)>[
      ("SELECT * FROM orders WHERE email = 'a@b.co' AND id = 42 LIMIT 10", null, 'SELECT * FROM orders WHERE email = ? AND id = ? LIMIT ?'),
      ("EXEC sp_note @text = 'it''s broken'", null, 'EXEC sp_note @text = ?'),
      ("SELECT 1 WHERE name = 'unterminated", null, 'SELECT ? WHERE name = ?'),
      (r'DO $body$ BEGIN PERFORM 1; END $body$', null, 'DO ?'),
      (r'SELECT "user id" FROM orders2 WHERE id = $1 AND v = sp_v2(?)', null, r'SELECT "user id" FROM orders2 WHERE id = $1 AND v = sp_v2(?)'),
      ('SELECT price * 1.5 FROM t', null, 'SELECT price * ? FROM t'),
      (r"SELECT * FROM users WHERE name = E'o\'brien' AND id = 1", null, 'SELECT * FROM users WHERE name = ? AND id = ?'),
      (r"SELECT * FROM users WHERE name = 'o\'brien' AND id = 1", null, 'SELECT * FROM users WHERE name = ? AND id = ?'),
      (r"SELECT * FROM t WHERE b = X'DEADBEEF' AND s = N'uni' AND u = U&'d\0061t' AND e = e'x'", null, 'SELECT * FROM t WHERE b = ? AND s = ? AND u = ? AND e = ?'),
      ("SELECT * FROM t WHERE a LIKE'%secret%'", null, 'SELECT * FROM t WHERE a LIKE?'),
      ('SELECT * FROM t WHERE f = 0x1F AND b = 0b101 AND n = 3e10 AND m = 1.5E-3 AND k = .5', null, 'SELECT * FROM t WHERE f = ? AND b = ? AND n = ? AND m = ? AND k = ?'),
      ('SELECT e, t.col, 1e5e FROM t', null, 'SELECT e, t.col, 1e5e FROM t'),
      ('SELECT "user id" FROM t WHERE token = "abc123secret"', 'mysql', 'SELECT ? FROM t WHERE token = ?'),
      ('SELECT "user id" FROM t WHERE token = "abc123secret"', 'MariaDB', 'SELECT ? FROM t WHERE token = ?'),
      ('SELECT "user id" FROM t WHERE token = "abc123secret"', 'postgresql', 'SELECT "user id" FROM t WHERE token = "abc123secret"'),
      ('SELECT "user id" FROM t WHERE token = "abc123secret"', null, 'SELECT "user id" FROM t WHERE token = "abc123secret"'),
      ("SELECT * FROM t WHERE a = 'x' AND b = 9", null, 'SELECT * FROM t WHERE a = ? AND b = ?'),
      ('SELECT * FROM t WHERE a = ? AND b = ?', null, 'SELECT * FROM t WHERE a = ? AND b = ?'),
      (r"SELECT * FROM t WHERE path = 'C:\\dir\\' AND n = 5", null, 'SELECT * FROM t WHERE path = ? AND n = ?'),
      ('INSERT INTO t (a, b) VALUES (-5, +3.25e+2)', null, 'INSERT INTO t (a, b) VALUES (-?, +?)'),
      (r"SELECT * FROM t WHERE a = 'secret\", null, 'SELECT * FROM t WHERE a = ?'),
      (r'SELECT * FROM t WHERE a = "secret\', 'mysql', 'SELECT * FROM t WHERE a = ?'),
    ];

    for (final (input, system, expected) in corpus) {
      test('masks $input (system $system) exactly like the server', () {
        expect(maskSql(input, system: system), expected);
        expect(maskSql(expected, system: system), expected);
      });
    }
  });

  group('sqlObjects', () {
    test('finds a stored procedure with its schema', () {
      expect(sqlObjects('EXEC dbo.sp_refund_order @id = ?'), {
        'operation': 'EXEC',
        'procedures': ['dbo.sp_refund_order'],
        'relations': <String>[],
      });
      expect(sqlObjects('CALL refund_order(?, ?)')!['procedures'],
          ['refund_order']);
      expect(sqlObjects('SELECT refund_order(?, ?)')!['procedures'],
          ['refund_order']);
    });

    test('finds views, joined tables and table functions', () {
      expect(
          sqlObjects(
                  'SELECT * FROM v_totals t JOIN public.customers c ON c.id = t.id')![
              'relations'],
          [
            'v_totals',
            'public.customers',
          ]);
      expect(sqlObjects('SELECT * FROM get_open_orders(?) o')!['procedures'],
          ['get_open_orders']);
    });

    test(
        'does not misread column lists or builtins, and returns null for garbage',
        () {
      expect(sqlObjects('INSERT INTO audit_log (a) VALUES (?)')!['procedures'],
          <String>[]);
      expect(
          sqlObjects('SELECT count(*) FROM orders')!['procedures'], <String>[]);
      expect(sqlObjects('garbage'), isNull);
    });
  });

  group('EventBuilder', () {
    final error = _FakeSqliteException(
        "SELECT * FROM notes WHERE title = 'a@b.co' AND id = 8814");

    test('sends the table name by default but not the statement', () {
      final payload = EventBuilder(_config()).build(error, StackTrace.current);
      expect((payload['sql_objects'] as Map)['relations'], ['notes']);
      expect(payload.containsKey('sql_statement'), isFalse);
    });

    test(
        'sends the masked statement when opted in, and nothing when both are off',
        () {
      expect(
        EventBuilder(_config(statement: true))
            .build(error, StackTrace.current)['sql_statement'],
        'SELECT * FROM notes WHERE title = ? AND id = ?',
      );
      final off = EventBuilder(_config(objects: false))
          .build(error, StackTrace.current);
      expect(off.containsKey('sql_objects'), isFalse);
      expect(off.containsKey('sql_statement'), isFalse);
      expect(
          EventBuilder(_config())
              .build(StateError('nope'), StackTrace.current)
              .containsKey('sql_objects'),
          isFalse);
    });
  });
}
