import 'dart:convert';
import 'dart:io';

import 'configuration.dart';

/// What became of one delivery. The three are told apart because the caller owes each a different
/// answer: [delivered] (any 2xx) is done; [rejected] (a 4xx other than 408 and 429) is a payload the
/// server will never take, so sending it again only repeats the refusal; [failed] (a network error,
/// a timeout, a 5xx, a 408 or a 429) may well go through later.
enum DeliveryStatus { delivered, rejected, failed }

/// How many flushes in a row may fail before a flusher or buffer gives up on the batch it is
/// holding and starts clean, so an endpoint that stays down can't keep one batch growing for good.
const int maxFailedFlushes = 5;

/// Delivers one payload over HTTP via `dart:io`'s [HttpClient]: no HTTP package dependency
/// needed, same reasoning as `net/http` in the Ruby gem and `java.net.http.HttpClient` in the
/// Java/Kotlin clients. Every failure mode (DNS, connection, timeout, TLS, a non-2xx response)
/// is caught here and turned into a `false` return (or, from the `send` methods, a
/// [DeliveryStatus]) rather than a thrown exception, since a broken or unreachable tracker must
/// never be able to break the host app.
///
/// `dart:io` isn't available on Flutter Web: see README.md's "Dependencies" section for what
/// that means for this client's own platform coverage.
class Client {
  Client(this._configuration, {HttpClient? httpClient}) : _httpClient = httpClient ?? HttpClient();

  final Configuration _configuration;
  final HttpClient _httpClient;

  Future<bool> deliver(Map<String, Object?> payload) => _delivered(_post(_configuration.ingestionUri, payload));

  /// Same delivery contract as [deliver], against the DSN's performance_samples endpoint (see
  /// `Configuration.performanceSamplesUri`). [samples] is wrapped as `{"samples": [...]}`, the
  /// shape `Api::V1::PerformanceSamplesController` expects.
  Future<bool> deliverPerformanceSamples(List<Map<String, Object?>> samples) =>
      _delivered(sendPerformanceSamples(samples));

  /// [deliverPerformanceSamples], answering with which of the three outcomes it was instead of
  /// only whether it was delivered: what `PerformanceFlusher` needs to tell a batch worth keeping
  /// from one the server will never take.
  Future<DeliveryStatus> sendPerformanceSamples(List<Map<String, Object?>> samples) =>
      _post(_configuration.performanceSamplesUri, {'samples': samples});

  /// Same delivery contract again, against the DSN's custom metrics and infrastructure metrics
  /// endpoints. [entries] is wrapped as `{"metrics": [...]}`.
  Future<bool> deliverMetrics(List<Map<String, Object?>> entries) => _delivered(sendMetrics(entries));

  Future<bool> deliverInfrastructureMetrics(List<Map<String, Object?>> entries) =>
      _delivered(sendInfrastructureMetrics(entries));

  /// [deliverMetrics] and [deliverInfrastructureMetrics], answering with a [DeliveryStatus] the
  /// same way [sendPerformanceSamples] does.
  Future<DeliveryStatus> sendMetrics(List<Map<String, Object?>> entries) =>
      _post(_configuration.customMetricsUri, {'metrics': entries});

  Future<DeliveryStatus> sendInfrastructureMetrics(List<Map<String, Object?>> entries) =>
      _post(_configuration.infrastructureMetricsUri, {'metrics': entries});

  /// Same delivery contract again, against the DSN's spans endpoint (see `Configuration.spansUri`).
  /// [trace] is sent as-is: `{"trace_id": ..., "spans": [...]}`, the shape `Api::V1::SpansController`
  /// expects.
  Future<bool> deliverSpans(Map<String, Object?> trace) => _delivered(_post(_configuration.spansUri, trace));

  /// Same delivery contract again, against the DSN's changes endpoint (see `Configuration.changesUri`).
  /// [change] is sent as-is, the one change `recordChange` built. A 403 (a plan without change
  /// tracking) is an ordinary non-2xx here: a quiet `false`, never an exception.
  Future<bool> deliverChange(Map<String, Object?> change) =>
      _delivered(_post(_configuration.changesUri, change));

  static Future<bool> _delivered(Future<DeliveryStatus> status) async => await status == DeliveryStatus.delivered;

  static DeliveryStatus _statusFor(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) return DeliveryStatus.delivered;
    if (statusCode >= 400 && statusCode < 500 && statusCode != 408 && statusCode != 429) {
      return DeliveryStatus.rejected;
    }
    return DeliveryStatus.failed;
  }

  Future<DeliveryStatus> _post(Uri? uri, Map<String, Object?> payload) async {
    final apiKey = _configuration.apiKey;
    if (uri == null || apiKey == null) return DeliveryStatus.failed;

    try {
      final request = await _httpClient.postUrl(uri).timeout(_configuration.timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      request.headers.contentType = ContentType('application', 'json', charset: 'utf-8');
      request.write(jsonEncode(payload));

      final response = await request.close().timeout(_configuration.timeout);
      await response.drain<void>();
      return _statusFor(response.statusCode);
    } catch (e) {
      _configuration.log('delivery failed: ${e.runtimeType}: $e');
      return DeliveryStatus.failed;
    }
  }
}
