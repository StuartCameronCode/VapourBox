// The test harness's downloads, with a bounded retry for transient network
// errors (task #117).
//
// The heavy tests install add-ons with the app's own ManifestAddonInstaller,
// which fetches through an AddonManager. The app's downloader uses rhttp,
// whose native library does not load under the headless `flutter test` VM, so
// the harness supplies its own over dart:io: [HarnessDownloader].
//
// A nightly lost four sweep variants to one DNS blip ("Failed host lookup:
// 'github.com'", 2026-11-22; the same downloads worked 25 s later), and a
// download that stopped sending bytes would have hung until its test's
// timeout. So a fetch is retried, a few times with backoff, on a transient
// network error only: DNS failure, refused or reset connections, a stall, a
// closed connection, HTTP 429 and 5xx. Never on any other HTTP status, and
// never on a size or hash mismatch, which is checked after the retries exactly
// as before. This retries a request, not a test.
//
// The nightly normally takes add-on files from a mirror filled before the
// tests (.github/scripts/prefetch-addons.py, VAPOURBOX_ADDON_MIRROR), so these
// downloads are the fallback there, and the path for local runs.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:vapourbox/services/addon_manager.dart';

/// An HTTP status a server answered with: transient for 429 and 5xx only.
class HttpStatusException implements Exception {
  final int statusCode;
  final Uri url;
  const HttpStatusException(this.statusCode, this.url);

  bool get isTransient => statusCode == 429 || statusCode >= 500;

  @override
  String toString() => 'HttpException: HTTP $statusCode for $url';
}

/// Whether [e], raised by a download, is worth retrying.
bool isTransientDownloadError(Object e) {
  if (e is HttpStatusException) return e.isTransient;
  if (e is SocketException) return true; // host lookup, refused, reset
  if (e is TimeoutException) return true; // connect timeout or a stall
  if (e is HandshakeException) return true;
  if (e is TlsException) return false; // a certificate problem stays one
  if (e is HttpException) return true; // "Connection closed while receiving data"
  return false;
}

/// The delays between attempts of [retryTransient].
const defaultRetryDelays = [Duration(seconds: 5), Duration(seconds: 15), Duration(seconds: 45)];

/// Run [attempt], again after each of [delays] while it fails with a
/// transient error ([isTransientDownloadError]); any other error, or the last
/// attempt's, is rethrown. [what] names it in the log line of each retry.
Future<T> retryTransient<T>(
  String what,
  Future<T> Function() attempt, {
  List<Duration> delays = defaultRetryDelays,
  void Function(String line)? log,
}) async {
  for (var i = 0;; i++) {
    try {
      return await attempt();
    } catch (e) {
      if (i >= delays.length || !isTransientDownloadError(e)) rethrow;
      (log ?? stderr.writeln)('[harness] retrying $what in ${delays[i].inSeconds} s after $e '
          '(attempt ${i + 2} of ${delays.length + 1})');
      await Future<void>.delayed(delays[i]);
    }
  }
}

/// GET [url] into [sink], following redirects by hand so [headersFor] can
/// set each hop's headers (a token only for github.com, say). A body that
/// sends nothing for [stallTimeout] fails with a [TimeoutException].
Future<void> _get(
  HttpClient client,
  String url,
  Future<void> Function(HttpClientResponse response) sink, {
  required Duration stallTimeout,
  void Function(HttpClientRequest request, Uri current)? headersFor,
}) async {
  var current = Uri.parse(url);
  for (var redirects = 0;; redirects++) {
    if (redirects > 6) throw StateError('too many redirects for $url');
    final request = await client.getUrl(current);
    request.followRedirects = false;
    headersFor?.call(request, current);
    final response = await request.close().timeout(stallTimeout);
    if (response.isRedirect) {
      final loc = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>();
      if (loc == null) throw StateError('redirect without Location ($current)');
      current = current.resolve(loc);
      continue;
    }
    if (response.statusCode != 200) {
      await response.drain<void>();
      throw HttpStatusException(response.statusCode, current);
    }
    await sink(response);
    return;
  }
}

Stream<List<int>> _stalling(HttpClientResponse response, Duration stallTimeout, Uri url) =>
    response.timeout(stallTimeout,
        onTimeout: (sink) => sink.addError(
            TimeoutException('no data for ${stallTimeout.inSeconds} s from $url', stallTimeout)));

/// [AddonManager] over dart:io, for [WorkerHarness.ensureAddon]: streams to
/// the file (models run to hundreds of MB), retries transient errors, and
/// checks size and hash as the app's does.
class HarnessDownloader extends AddonManager {
  final Duration stallTimeout;
  final Duration connectionTimeout;
  final List<Duration> retryDelays;
  final void Function(String line)? log;

  HarnessDownloader({
    this.stallTimeout = const Duration(seconds: 120),
    this.connectionTimeout = const Duration(seconds: 30),
    this.retryDelays = defaultRetryDelays,
    this.log,
  });

  @override
  Future<void> downloadFile(String url, File destination,
      {int? expectedSize, String? expectedSha256, Map<String, String>? extraHeaders}) async {
    final partial = File('${destination.path}.partial');
    try {
      await retryTransient(url, () async {
        final client = HttpClient()..connectionTimeout = connectionTimeout;
        try {
          await _get(
              client,
              url,
              (response) async {
                await _stalling(response, stallTimeout, Uri.parse(url)).pipe(partial.openWrite());
              },
              stallTimeout: stallTimeout,
              headersFor: (request, _) {
                extraHeaders?.forEach(request.headers.set);
              });
        } finally {
          client.close(force: true);
        }
      }, delays: retryDelays, log: log);
      if (expectedSize != null && await partial.length() != expectedSize) {
        throw StateError('$url: got ${await partial.length()} bytes, expected $expectedSize');
      }
      if (expectedSha256 != null) {
        final digest = (await sha256.bind(partial.openRead()).first).toString();
        if (digest != expectedSha256) {
          throw StateError('$url: SHA256 mismatch, expected $expectedSha256, got $digest');
        }
      }
      if (await destination.exists()) await destination.delete();
      await partial.rename(destination.path);
    } finally {
      if (await partial.exists()) await partial.delete();
    }
  }
}

/// GET [url] into memory, following redirects by hand so a GitHub auth token
/// ([token]) is only sent to github.com hosts (and stripped on the redirect to
/// the CDN), with the same transient retry as [HarnessDownloader].
Future<Uint8List> harnessGetBytes(
  String url, {
  String? token,
  Duration stallTimeout = const Duration(seconds: 120),
  List<Duration> retryDelays = defaultRetryDelays,
  void Function(String line)? log,
}) =>
    retryTransient(url, () async {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
      try {
        final builder = BytesBuilder(copy: false);
        await _get(
            client,
            url,
            (response) async {
              await for (final chunk in _stalling(response, stallTimeout, Uri.parse(url))) {
                builder.add(chunk);
              }
            },
            stallTimeout: stallTimeout,
            headersFor: (request, current) {
              if (token != null && current.host.endsWith('github.com')) {
                request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
              }
              request.headers.set(HttpHeaders.acceptHeader, 'application/octet-stream');
            });
        return builder.takeBytes();
      } finally {
        client.close(force: true);
      }
    }, delays: retryDelays, log: log);
