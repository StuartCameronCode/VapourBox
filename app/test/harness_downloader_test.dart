// The harness downloader's transient retry (task #117), against a local
// server: a dropped connection, a 503 and a stall are retried; a 404 and a
// hash mismatch are not. No network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness_downloader.dart';

const _body = 'the pinned add-on file';
final _sha = sha256.convert(utf8.encode(_body)).toString();

/// A server whose answer to the Nth request is `script[N]` (the last repeats).
class _Server {
  final HttpServer server;
  int requests = 0;
  _Server._(this.server);

  static Future<_Server> start(List<Future<void> Function(HttpRequest r)> script) async {
    final s = _Server._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    s.server.listen((r) async {
      final step = script[s.requests < script.length ? s.requests : script.length - 1];
      s.requests++;
      await step(r);
    });
    return s;
  }

  String get url => 'http://127.0.0.1:${server.port}/file.bin';
  Future<void> close() => server.close(force: true);
}

Future<void> _ok(HttpRequest r) async {
  r.response.contentLength = _body.length;
  r.response.write(_body);
  await r.response.close();
}

Future<void> _status(HttpRequest r, int code) async {
  r.response.statusCode = code;
  await r.response.close();
}

Future<void> _drop(HttpRequest r) async {
  // Promise the whole body, send part of it, and hang up.
  final socket = await r.response.detachSocket(writeHeaders: false);
  socket.write('HTTP/1.1 200 OK\r\nContent-Length: ${_body.length}\r\n\r\n${_body.substring(0, 5)}');
  await socket.flush();
  socket.destroy();
}

Future<void> _stall(HttpRequest r) async {
  r.response.contentLength = _body.length;
  r.response.write(_body.substring(0, 5));
  await r.response.flush();
  // ...and nothing more, until the server is closed.
}

HarnessDownloader _downloader(List<String> log) => HarnessDownloader(
      stallTimeout: const Duration(milliseconds: 500),
      retryDelays: const [Duration(milliseconds: 10), Duration(milliseconds: 10), Duration(milliseconds: 10)],
      log: log.add,
    );

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('harness_downloader_test'));
  tearDown(() async => dir.delete(recursive: true));

  test('a dropped connection and a 503 are retried, then the file is kept', () async {
    final server = await _Server.start([_drop, (r) => _status(r, 503), _ok]);
    addTearDown(server.close);
    final log = <String>[];
    final dest = File('${dir.path}/file.bin');
    await _downloader(log).downloadFile(server.url, dest,
        expectedSize: _body.length, expectedSha256: _sha);
    expect(await dest.readAsString(), _body);
    expect(server.requests, 3);
    expect(log, hasLength(2));
    expect(log.first, contains('retrying'));
    expect(File('${dest.path}.partial').existsSync(), isFalse);
  });

  test('a stalled body is abandoned and retried', () async {
    final server = await _Server.start([_stall, _ok]);
    addTearDown(server.close);
    final log = <String>[];
    final dest = File('${dir.path}/file.bin');
    await _downloader(log).downloadFile(server.url, dest,
        expectedSize: _body.length, expectedSha256: _sha);
    expect(await dest.readAsString(), _body);
    expect(server.requests, 2);
    expect(log.single, contains('TimeoutException'));
  });

  test('a 404 fails at once', () async {
    final server = await _Server.start([(r) => _status(r, 404)]);
    addTearDown(server.close);
    final log = <String>[];
    await expectLater(
        _downloader(log).downloadFile(server.url, File('${dir.path}/file.bin')),
        throwsA(isA<HttpStatusException>().having((e) => e.statusCode, 'statusCode', 404)));
    expect(server.requests, 1);
    expect(log, isEmpty);
  });

  test('a body that does not match its hash fails after one fetch, and nothing is kept', () async {
    final server = await _Server.start([_ok]);
    addTearDown(server.close);
    final log = <String>[];
    final dest = File('${dir.path}/file.bin');
    await expectLater(
        _downloader(log).downloadFile(server.url, dest,
            expectedSize: _body.length, expectedSha256: '0' * 64),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('SHA256 mismatch'))));
    expect(server.requests, 1);
    expect(dest.existsSync(), isFalse);
    expect(File('${dest.path}.partial').existsSync(), isFalse);
  });

  test('retries give up after the last delay and rethrow the transient error', () async {
    final server = await _Server.start([(r) => _status(r, 502)]);
    addTearDown(server.close);
    final log = <String>[];
    await expectLater(
        _downloader(log).downloadFile(server.url, File('${dir.path}/file.bin')),
        throwsA(isA<HttpStatusException>().having((e) => e.statusCode, 'statusCode', 502)));
    expect(server.requests, 4);
    expect(log, hasLength(3));
  });

  test('harnessGetBytes retries the same way', () async {
    final server = await _Server.start([(r) => _status(r, 429), _ok]);
    addTearDown(server.close);
    final bytes = await harnessGetBytes(server.url,
        retryDelays: const [Duration(milliseconds: 10)], log: (_) {});
    expect(utf8.decode(bytes), _body);
    expect(server.requests, 2);
  });

  test('which errors count as transient', () {
    expect(isTransientDownloadError(const SocketException("Failed host lookup: 'github.com'")), isTrue);
    expect(isTransientDownloadError(const HttpException('Connection closed while receiving data')), isTrue);
    expect(isTransientDownloadError(TimeoutException('stall')), isTrue);
    expect(isTransientDownloadError(HttpStatusException(500, Uri())), isTrue);
    expect(isTransientDownloadError(HttpStatusException(429, Uri())), isTrue);
    expect(isTransientDownloadError(HttpStatusException(403, Uri())), isFalse);
    expect(isTransientDownloadError(HttpStatusException(404, Uri())), isFalse);
    expect(isTransientDownloadError(StateError('SHA256 mismatch')), isFalse);
  });
}
