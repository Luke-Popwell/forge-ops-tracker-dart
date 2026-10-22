import 'package:forge_ops_tracker/src/histogram_bucketer.dart';
import 'package:test/test.dart';

void main() {
  group('bucketFor', () {
    test('returns the smallest boundary a duration fits under, as a string',
        () {
      expect(bucketFor(10), '50');
      expect(bucketFor(50), '50');
      expect(bucketFor(50.5), '100');
      expect(bucketFor(4999), '5000');
    });

    test('returns inf for anything larger than the largest boundary', () {
      expect(bucketFor(10001), 'inf');
      expect(bucketFor(1000000), 'inf');
    });

    test(
        "puts a duration exactly on a boundary into that boundary's own bucket",
        () {
      for (final boundary in histogramBoundariesMs) {
        expect(bucketFor(boundary.toDouble()), boundary.toString());
      }
    });

    test("boundaries match the server's HistogramPercentile", () {
      // app/services/histogram_percentile.rb and every other SDK must agree on this exact list.
      expect(
          histogramBoundariesMs, [50, 100, 250, 500, 1000, 2500, 5000, 10000]);
    });
  });
}
