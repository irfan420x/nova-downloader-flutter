import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/api/models.dart';
import 'package:nova_downloader/download/download_manager.dart';

/// A fake HLS origin: master + variant playlists, MPEG-TS segments,
/// an fMP4 stream, a live playlist and an encrypted playlist.
class FakeHlsServer {
  final HttpServer _server;
  final Duration segmentDelay;

  FakeHlsServer._(this._server, {this.segmentDelay = Duration.zero});

  static Future<FakeHlsServer> start({
    Duration segmentDelay = Duration.zero,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeHlsServer._(server, segmentDelay: segmentDelay);
    server.listen(fake._handle);
    return fake;
  }

  int get port => _server.port;
  String url(String path) => 'http://127.0.0.1:$port$path';

  static Uint8List segBytes(String name) {
    final unit = '$name-'.codeUnits;
    final out = <int>[];
    for (var i = 0; i < 64; i++) {
      out.addAll(unit);
    }
    return Uint8List.fromList(out);
  }

  Future<void> _handle(HttpRequest request) async {
    final path = request.uri.path;
    final response = request.response;
    if (request.method == 'HEAD') {
      response.headers.set(HttpHeaders.contentLengthHeader, 0);
      await response.close();
      return;
    }
    String? body;
    Uint8List? bytes;
    var contentType = 'application/vnd.apple.mpegurl';
    switch (path) {
      case '/master.m3u8':
        body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
/v360.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
/v720.m3u8
''';
      case '/v720.m3u8':
        body = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
/seg0.ts
#EXTINF:4.0,
/seg1.ts
#EXTINF:4.0,
/seg2.ts
#EXT-X-ENDLIST
''';
      case '/v360.m3u8':
        body = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
/seg0.ts
#EXTINF:4.0,
/seg1.ts
#EXT-X-ENDLIST
''';
      case '/fmp4.m3u8':
        body = '''
#EXTM3U
#EXT-X-MAP:URI="/init.mp4"
#EXTINF:4.0,
/s0.m4s
#EXTINF:4.0,
/s1.m4s
#EXT-X-ENDLIST
''';
      case '/live.m3u8':
        body = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
/seg0.ts
#EXTINF:4.0,
/seg1.ts
''';
      case '/enc.m3u8':
        body = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="/key.bin"
#EXTINF:4.0,
/seg0.ts
#EXT-X-ENDLIST
''';
      case '/seg0.ts':
      case '/seg1.ts':
      case '/seg2.ts':
        bytes = segBytes(path.substring(1));
        contentType = 'video/mp2t';
      case '/init.mp4':
        bytes = segBytes('init.mp4');
        contentType = 'video/mp4';
      case '/s0.m4s':
      case '/s1.m4s':
        bytes = segBytes(path.substring(1));
        contentType = 'video/iso.segment';
      default:
        response.statusCode = HttpStatus.notFound;
        await response.close();
        return;
    }
    if (bytes != null) {
      // Stream slowly when a delay is set, so a pause can land mid-stream.
      response.headers.set(HttpHeaders.contentLengthHeader, bytes.length);
      response.headers.set(HttpHeaders.contentTypeHeader, contentType);
      const chunkSize = 64;
      for (var i = 0; i < bytes.length; i += chunkSize) {
        final chunk = bytes.sublist(
          i,
          (i + chunkSize).clamp(0, bytes.length),
        );
        response.add(chunk);
        await response.flush();
        if (segmentDelay > Duration.zero) {
          await Future.delayed(segmentDelay);
        }
      }
      await response.close();
      return;
    }
    final encoded = body!.codeUnits;
    response.headers.set(HttpHeaders.contentLengthHeader, encoded.length);
    response.headers.set(HttpHeaders.contentTypeHeader, contentType);
    response.add(encoded);
    await response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nova-hls-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Quality hlsQuality(String url) => Quality(
        id: 'q',
        label: '720p',
        ext: 'm3u8',
        url: url,
      );

  Future<String?> fakeSaver(String tempPath, String name, String mime) async {
    final dest = File('${tmp.path}/$name');
    await File(tempPath).copy(dest.path);
    return dest.path;
  }

  Future<void> waitForDone(DownloadTask task,
      {Duration timeout = const Duration(seconds: 20)}) async {
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued;
    }).timeout(timeout);
  }

  test('HLS master playlist downloads segments as one playable .ts file',
      () async {
    final server = await FakeHlsServer.start();
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'HLS test stream',
      sourceUrl: server.url('/master.m3u8'),
      quality: hlsQuality(server.url('/master.m3u8')),
      platform: 'hls',
    );

    await waitForDone(task);

    expect(task.status, DownloadStatus.completed);
    // The saved file is the concatenated segments, NOT the playlist —
    // and its extension is the real container, not .m3u8.
    expect(task.fileName.endsWith('.ts'), isTrue);
    final saved = File('${tmp.path}/${task.fileName}');
    expect(await saved.exists(), isTrue);
    final expected = <int>[
      ...FakeHlsServer.segBytes('seg0.ts'),
      ...FakeHlsServer.segBytes('seg1.ts'),
      ...FakeHlsServer.segBytes('seg2.ts'),
    ];
    expect(await saved.readAsBytes(), expected);
    expect(task.hlsSegmentsDone, 3);
    expect(task.downloadedBytes, expected.length);
  });

  test('fMP4 HLS stream writes the init segment first, saved as .mp4',
      () async {
    final server = await FakeHlsServer.start();
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'fMP4 stream',
      sourceUrl: server.url('/fmp4.m3u8'),
      quality: hlsQuality(server.url('/fmp4.m3u8')),
      platform: 'hls',
    );

    await waitForDone(task);

    expect(task.status, DownloadStatus.completed);
    expect(task.fileName.endsWith('.mp4'), isTrue);
    final saved = File('${tmp.path}/${task.fileName}');
    final expected = <int>[
      ...FakeHlsServer.segBytes('init.mp4'),
      ...FakeHlsServer.segBytes('s0.m4s'),
      ...FakeHlsServer.segBytes('s1.m4s'),
    ];
    expect(await saved.readAsBytes(), expected);
  });

  test('encrypted HLS stream fails honestly instead of saving junk',
      () async {
    final server = await FakeHlsServer.start();
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Encrypted stream',
      sourceUrl: server.url('/enc.m3u8'),
      quality: hlsQuality(server.url('/enc.m3u8')),
      platform: 'hls',
    );

    await waitForDone(task);

    expect(task.status, DownloadStatus.failed);
    expect(task.logLines.any((l) => l.contains('encrypted')), isTrue);
    expect(File('${tmp.path}/${task.fileName}').existsSync(), isFalse);
  });

  test('live HLS stream (no ENDLIST) fails honestly', () async {
    final server = await FakeHlsServer.start();
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Live stream',
      sourceUrl: server.url('/live.m3u8'),
      quality: hlsQuality(server.url('/live.m3u8')),
      platform: 'hls',
    );

    await waitForDone(task);

    expect(task.status, DownloadStatus.failed);
    expect(task.logLines.any((l) => l.contains('live')), isTrue);
  });

  test('pause mid-HLS then resume finishes with the right bytes',
      () async {
    final server = await FakeHlsServer.start(
      segmentDelay: const Duration(milliseconds: 60),
    );
    addTearDown(server.stop);

    final manager = DownloadManager(
      fileSaver: fakeSaver,
      tempDirOverride: () => tmp,
    );
    final task = manager.addDownload(
      title: 'Slow HLS',
      sourceUrl: server.url('/master.m3u8'),
      quality: hlsQuality(server.url('/master.m3u8')),
      platform: 'hls',
    );

    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.hlsSegmentsDone == 0 &&
          task.status == DownloadStatus.downloading;
    }).timeout(const Duration(seconds: 10));
    await Future.delayed(const Duration(milliseconds: 150));
    manager.pause(task.id);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(task.status, DownloadStatus.paused);
    expect(task.hlsSegmentsDone, greaterThan(0));
    expect(task.hlsSegmentsDone, lessThan(3));

    manager.resume(task.id);
    await waitForDone(task, timeout: const Duration(seconds: 20));

    expect(task.status, DownloadStatus.completed);
    final saved = File('${tmp.path}/${task.fileName}');
    final expected = <int>[
      ...FakeHlsServer.segBytes('seg0.ts'),
      ...FakeHlsServer.segBytes('seg1.ts'),
      ...FakeHlsServer.segBytes('seg2.ts'),
    ];
    expect(await saved.readAsBytes(), expected);
  });
}
