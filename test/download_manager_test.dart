import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/api/models.dart';
import 'package:nova_downloader/download/download_manager.dart';

/// A tiny file server that honours HEAD, Range and slow chunked delivery,
/// and records the headers it saw (names + values checked only in-test).
class FakeFileServer {
  final HttpServer _server;
  final Uint8List bytes;
  final bool Function(HttpRequest request)? onRequest;
  final Duration chunkDelay;
  int headCount = 0;
  final List<Map<String, String>> seenHeaders = [];

  /// When true, GET responses omit Content-Length (chunked transfer).
  final bool chunkedGet;

  /// When set, GET streams at most this many bytes (fewer than HEAD claims).
  final int? getLimit;

  FakeFileServer._(this._server, this.bytes,
      {this.onRequest,
      this.chunkDelay = Duration.zero,
      this.chunkedGet = false,
      this.getLimit});

  static Future<FakeFileServer> start(
    Uint8List bytes, {
    bool Function(HttpRequest request)? onRequest,
    Duration chunkDelay = Duration.zero,
    bool chunkedGet = false,
    int? getLimit,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeFileServer._(server, bytes,
        onRequest: onRequest,
        chunkDelay: chunkDelay,
        chunkedGet: chunkedGet,
        getLimit: getLimit);
    server.listen(fake._handle);
    return fake;
  }

  int get port => _server.port;

  String url(String path) => 'http://127.0.0.1:$port$path';

  Future<void> _handle(HttpRequest request) async {
    seenHeaders.add({
      for (final name in [
        HttpHeaders.cookieHeader,
        HttpHeaders.refererHeader,
        HttpHeaders.userAgentHeader,
        HttpHeaders.rangeHeader,
      ])
        if (request.headers.value(name) != null)
          name: request.headers.value(name)!,
    });
    if (onRequest != null && !onRequest!(request)) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    if (request.method == 'HEAD') {
      headCount++;
      request.response.headers
          .set(HttpHeaders.contentLengthHeader, bytes.length);
      request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
      await request.response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    var end = bytes.length - 1;
    var partial = false;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
      if (m != null) {
        start = int.parse(m.group(1)!);
        if (m.group(2)!.isNotEmpty) end = int.parse(m.group(2)!);
        partial = true;
      }
    }
    final slice = bytes.sublist(start, end + 1);
    final limited =
        getLimit != null && getLimit! < slice.length
            ? slice.sublist(0, getLimit)
            : slice;
    request.response.statusCode =
        partial ? HttpStatus.partialContent : HttpStatus.ok;
    if (!chunkedGet) {
      request.response.headers
          .set(HttpHeaders.contentLengthHeader, limited.length);
    }
    request.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    if (partial) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-$end/${bytes.length}',
      );
    }
    // Stream slowly so a pause can land mid-download.
    const chunkSize = 4096;
    for (var i = 0; i < limited.length; i += chunkSize) {
      final chunk = limited.sublist(
        i,
        (i + chunkSize).clamp(0, limited.length),
      );
      request.response.add(chunk);
      await request.response.flush();
      if (chunkDelay > Duration.zero) await Future.delayed(chunkDelay);
    }
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nova-dl-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Quality quality(String url, {List<String> alternates = const []}) {
    return Quality(
      id: 'q',
      label: '720p',
      ext: 'mp4',
      url: url,
      alternates: alternates,
      headers: {
        'User-Agent': 'TestAgent/1.0',
        'Referer': 'https://www.tiktok.com/',
        'Cookie': 'sid=test123',
      },
    );
  }

  Future<String?> fakeSaver(String tempPath, String name, String mime) async {
    final dest = File('${tmp.path}/$name');
    await File(tempPath).copy(dest.path);
    return dest.path;
  }

  test('downloads a file end to end, sending the quality headers',
      () async {
    final data = Uint8List.fromList(List.generate(20000, (i) => i % 256));
    final server = await FakeFileServer.start(data);
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Test video',
      sourceUrl: 'https://www.tiktok.com/@a/video/1',
      quality: quality(server.url('/v.mp4')),
      platform: 'tiktok',
    );

    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued;
    }).timeout(const Duration(seconds: 15));

    expect(task.status, DownloadStatus.completed);
    expect(task.downloadedBytes, data.length);
    final saved = File('${tmp.path}/${task.fileName}');
    expect(await saved.exists(), isTrue);
    expect(await saved.readAsBytes(), data);
    // The probe and the download both carried the headers.
    expect(server.seenHeaders, isNotEmpty);
    expect(
      server.seenHeaders
          .every((h) => h[HttpHeaders.userAgentHeader] == 'TestAgent/1.0'),
      isTrue,
    );
    expect(
      server.seenHeaders
          .every((h) => h[HttpHeaders.cookieHeader] == 'sid=test123'),
      isTrue,
    );
    expect(
      server.seenHeaders
          .every((h) => h[HttpHeaders.refererHeader] == 'https://www.tiktok.com/'),
      isTrue,
    );
    expect(server.headCount, greaterThanOrEqualTo(1));
  });

  test('falls through to an alternate when the primary fails', () async {
    final data = Uint8List.fromList(List.generate(5000, (i) => i % 251));
    final server = await FakeFileServer.start(
      data,
      onRequest: (req) => req.uri.path != '/bad.mp4',
    );
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Alt test',
      sourceUrl: 'https://x',
      quality: quality(
        server.url('/bad.mp4'),
        alternates: [server.url('/good.mp4')],
      ),
      platform: 'direct',
    );

    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued;
    }).timeout(const Duration(seconds: 15));

    expect(task.status, DownloadStatus.completed);
    expect(task.downloadedBytes, data.length);
    expect(
      task.logLines.any((l) => l.contains('trying next source')),
      isTrue,
    );
  });

  test('pause mid-download then resume finishes the file', () async {
    final data =
        Uint8List.fromList(List.generate(200000, (i) => i % 256));
    final server = await FakeFileServer.start(
      data,
      chunkDelay: const Duration(milliseconds: 20),
    );
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Slow video',
      sourceUrl: 'https://x',
      quality: quality(server.url('/slow.mp4')),
      platform: 'direct',
    );

    // Wait until some bytes have arrived, then pause.
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.downloadedBytes == 0 &&
          task.status == DownloadStatus.downloading;
    }).timeout(const Duration(seconds: 10));
    await Future.delayed(const Duration(milliseconds: 100));
    manager.pause(task.id);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(task.status, DownloadStatus.paused);
    final partial = task.downloadedBytes;
    expect(partial, greaterThan(0));
    expect(partial, lessThan(data.length));

    manager.resume(task.id);
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued;
    }).timeout(const Duration(seconds: 20));

    expect(task.status, DownloadStatus.completed);
    expect(task.downloadedBytes, data.length);
    final saved = File('${tmp.path}/${task.fileName}');
    expect(await saved.readAsBytes(), data);
  });

  test('all sources failing marks the task failed with a log', () async {
    final server = await FakeFileServer.start(
      Uint8List(0),
      onRequest: (_) => false,
    );
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Broken',
      sourceUrl: 'https://x',
      quality: quality(server.url('/nope.mp4')),
      platform: 'direct',
    );

    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued;
    }).timeout(const Duration(seconds: 15));

    expect(task.status, DownloadStatus.failed);
    expect(task.error, isNotNull);
    expect(task.logLines, isNotEmpty);
  });

  test('chunked GET with no declared length is accepted, not failed (F-6)',
      () async {
    // HEAD claims 10000 bytes, but the GET streams only 6000 bytes with
    // no Content-Length (chunked). The old code failed this at the
    // early-EOF check against the HEAD total; the total is only enforced
    // when the GET response itself declares one.
    final data = Uint8List.fromList(List.generate(10000, (i) => i % 256));
    final server = await FakeFileServer.start(
      data,
      chunkedGet: true,
      getLimit: 6000,
    );
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Chunked',
      sourceUrl: 'https://x',
      quality: quality(server.url('/chunked.mp4')),
      platform: 'direct',
    );

    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued;
    }).timeout(const Duration(seconds: 15));

    expect(task.status, DownloadStatus.completed);
    expect(task.downloadedBytes, 6000);
    final saved = File('${tmp.path}/${task.fileName}');
    expect(await saved.readAsBytes(), data.sublist(0, 6000));
  });

  test('a removed task does not get its file saved', () async {
    final data = Uint8List.fromList(List.generate(200000, (i) => i % 256));
    final server = await FakeFileServer.start(
      data,
      chunkDelay: const Duration(milliseconds: 20),
    );
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Removed mid-flight',
      sourceUrl: 'https://x',
      quality: quality(server.url('/slow.mp4')),
      platform: 'direct',
    );

    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.downloadedBytes == 0 &&
          task.status == DownloadStatus.downloading;
    }).timeout(const Duration(seconds: 10));
    manager.remove(task.id);
    await Future.delayed(const Duration(milliseconds: 300));

    expect(manager.tasks, isEmpty);
    expect(File('${tmp.path}/${task.fileName}').existsSync(), isFalse);
  });
}
