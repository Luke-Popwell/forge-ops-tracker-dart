import 'package:forge_ops_tracker/forge_ops_tracker.dart';
import 'package:test/test.dart';

void main() {
  group('scrubString', () {
    test('scrubs an email address', () {
      expect(scrubString('contact user@example.com for help'), 'contact [EMAIL FILTERED] for help');
    });

    test('scrubs a formatted credit card', () {
      expect(scrubString('charged card 4242-4242-4242-4242 successfully'), isNot('charged card 4242-4242-4242-4242 successfully'));
    });

    test('leaves an ordinary long numeric id alone', () {
      const text = 'order id 1234567890123456';
      expect(scrubString(text), text);
    });

    test('scrubs a formatted ssn', () {
      expect(scrubString('ssn on file: 123-45-6789'), 'ssn on file: [SSN FILTERED]');
    });

    test('scrubs known api key and token formats', () {
      const cases = [
        'Authorization: Bearer abc123DEF.456-xyz',
        'aws key AKIAABCDEFGHIJKLMNOP in use',
        'stripe key sk_live_abcdefghijklmnop',
        'github token ghp_abcdefghijklmnopqrstuvwxyz0123456789',
        'jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dQw4w9WgXcQ',
      ];
      for (final text in cases) {
        expect(scrubString(text), isNot(text), reason: 'expected $text to be redacted');
      }
    });
  });

  group('scrub', () {
    test('redacts the whole value under a sensitive key regardless of type or casing', () {
      expect(scrub(12345, key: 'apiKey'), redacted);
      expect(scrub('hunter2', key: 'X-Api-Key'), redacted);
    });

    test('recurses into maps and lists', () {
      final input = {
        'password': 'hunter2',
        'note': 'email me at user@example.com',
        'items': [
          {'token': 'abc'},
          'visit user@example.com',
        ],
      };

      final scrubbed = scrub(input) as Map;

      expect(scrubbed['password'], redacted);
      expect(scrubbed['note'], 'email me at [EMAIL FILTERED]');
      final items = scrubbed['items'] as List;
      expect((items[0] as Map)['token'], redacted);
      expect(items[1], 'visit [EMAIL FILTERED]');
    });

    test('sensitive key check ignores case and punctuation', () {
      for (final key in ['API_KEY', 'Api-Key', 'apiKey', 'X-Api-Key']) {
        expect(scrub('value', key: key), redacted, reason: 'expected $key to be treated as sensitive');
      }
      expect(scrub('bob', key: 'username'), 'bob');
    });
  });
}
