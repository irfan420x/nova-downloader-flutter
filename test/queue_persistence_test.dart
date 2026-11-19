import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/api/models.dart';
import 'package:nova_downloader/download/download_manager.dart';
import 'package:nova_downloader/download/queue_store.dart';

/// Minimal file server for the persistence tests: serves [bytes] with
/// HEAD + Range, streaming slowly so a pause can land mid-download.
class SlowFileServer {
  final HttpServer _server;
  final Uint8List bytes;

  SlowFileServer._(this._server, this.bytes);

  static Future<SlowFileServer> start(Uint8List bytes) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = SlowFileServer._(server, bytes);
    server.listen(fake._handle);
    return fake;
  }

  int get port => _server.port;
  String url(String path) => 'http://127.0.0.1:$port$path';

  Future<void> _handle(HttpRequest request) async {
    if (request.method == 'HEAD') {
      request.response.headers
          .set(HttpHeaders.contentLengthHeader, bytes.length);
      await request.response.close();
      return;
    }
    final range = request.headers.value(HttpHeaders.rangeHeader);
    var start = 0;
    if (range != null) {
      final m = RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (m != null) start = int.parse(m.group(1)!);
    }
    final slice = bytes.sublist(start);
    request.response.statusCode =
        start > 0 ? HttpStatus.partialContent : HttpStatus.ok;
    request.response.headers
        .set(HttpHeaders.contentLengthHeader, slice.length);
    if (start > 0) {
      request.response.headers.set(
        HttpHeaders.contentRangeHeader,
        'bytes $start-${bytes.length - 1}/${bytes.length}',
      );
    }
    const chunkSize = 4096;
    for (var i = 0; i < slice.length; i += chunkSize) {
      request.response.add(
        slice.sublist(i, (i + chunkSize).clamp(0, slice.length)),
      );
      await request.response.flush();
      await Future.delayed(const Duration(milliseconds: 15));
    }
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('nova-queue-test-');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Quality quality(String url) => Quality(
        id: 'q',
        label: '720p',
        ext: 'mp4',
        url: url,
      );

  Future<String?> fakeSaver(String tempPath, String name, String mime) async {
    final dest = File('${tmp.path}/$name');
    await File(tempPath).copy(dest.path);
    return dest.path;
  }

  DownloadManager managerFor() => DownloadManager(
        fileSaver: fakeSaver,
        tempDirOverride: () => tmp,
        queueStore: QueueStore(dirOverride: tmp),
      );

  test('task snapshots round-trip through toJson/tryFromJson', () {
    final task = DownloadTask(
      id: 'dl-1',
      title: 'Round trip',
      sourceUrl: 'https://example.com/v/1',
      quality: quality('https://cdn.example.com/v.mp4'),
      platform: 'direct',
      fileName: 'Round trip [720p].mp4',
    );
    task.downloadedBytes = 1234;
    task.totalBytes = 9999;
    task.hlsSegmentsDone = 2;
    task.hlsTotalSegments = 5;
    task.hlsInitDone = true;

    final restored = DownloadTask.tryFromJson(task.toJson());
    expect(restored, isNotNull);
    expect(restored!.id, task.id);
    expect(restored.title, 'Round trip');
    expect(restored.quality.url, 'https://cdn.example.com/v.mp4');
    expect(restored.quality.label, '720p');
    expect(restored.downloadedBytes, 1234);
    expect(restored.totalBytes, 9999);
    expect(restored.hlsSegmentsDone, 2);
    expect(restored.hlsTotalSegments, 5);
    expect(restored.hlsInitDone, isTrue);

    // A snapshot without a URL cannot run — it is skipped, not crashed on.
    expect(DownloadTask.tryFromJson({'id': 'x', 'title': 't'}), isNull);
    expect(
      DownloadTask.tryFromJson({
        'id': 'x',
        'title': 't',
        'sourceUrl': 'https://example.com',
        'quality': {'url': ''},
      }),
      isNull,
    );
  });

  test('QueueStore round-trips snapshots and tolerates a corrupt file',
      () async {
    final store = QueueStore(dirOverride: tmp);
    expect(await store.load(), isEmpty);
    await store.save([
      {'id': 'a', 'title': 'One'},
      {'id': 'b', 'title': 'Two'},
    ]);
    final loaded = await store.load();
    expect(loaded.length, 2);
    expect(loaded.first['id'], 'a');

    await File('${tmp.path}/download_queue.json')
        .writeAsString('this is not json');
    expect(await store.load(), isEmpty);

    await store.clear();
    expect(
      await File('${tmp.path}/download_queue.json').exists(),
      isFalse,
    );
  });

  test('paused download survives a restart and resumes to completion',
      () async {
    final data = Uint8List.fromList(List.generate(200000, (i) => i % 256));
    final server = await SlowFileServer.start(data);
    addTearDown(server.stop);

    // Session 1: start a download, pause it mid-way.
    final first = managerFor();
    await first.restore();
    final task = first.addDownload(
      title: 'Interrupted video',
      sourceUrl: 'https://example.com/v/1',
      quality: quality(server.url('/slow.mp4')),
      platform: 'direct',
    );
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return task.downloadedBytes == 0 &&
          task.status == DownloadStatus.downloading;
    }).timeout(const Duration(seconds: 10));
    await Future.delayed(const Duration(milliseconds: 150));
    first.pause(task.id);
    await Future.delayed(const Duration(milliseconds: 200));
    expect(task.status, DownloadStatus.paused);
    final partial = task.downloadedBytes;
    expect(partial, greaterThan(0));
    expect(partial, lessThan(data.length));
    // Let the queue save land.
    await Future.delayed(const Duration(milliseconds: 100));

    // Session 2 (a fresh manager, as after an app kill): restore.
    final second = managerFor();
    await second.restore();
    expect(second.tasks.length, 1);
    final restored = second.tasks.first;
    expect(restored.id, task.id);
    expect(restored.status, DownloadStatus.paused);
    // The .part file's real length is the resume point.
    expect(restored.downloadedBytes, partial);

    second.resume(restored.id);
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 50));
      return restored.status == DownloadStatus.downloading ||
          restored.status == DownloadStatus.queued;
    }).timeout(const Duration(seconds: 20));

    expect(restored.status, DownloadStatus.completed);
    expect(restored.downloadedBytes, data.length);
    final saved = File('${tmp.path}/${restored.fileName}');
    expect(await saved.readAsBytes(), data);
  });

  test('restore with a missing .part file restarts from zero', () async {
    // A snapshot that claims 5000 bytes, but no .part file on disk.
    final store = QueueStore(dirOverride: tmp);
    final snapshot = DownloadTask(
      id: 'dl-lost',
      title: 'Lost part',
      sourceUrl: 'https://example.com/v/1',
      quality: quality('https://cdn.example.com/v.mp4'),
      platform: 'direct',
      fileName: 'Lost part [720p].mp4',
    ).toJson()
      ..['status'] = 'downloading'
      ..['downloadedBytes'] = 5000;
    await store.save([snapshot]);

    final manager = managerFor();
    await manager.restore();
    expect(manager.tasks.length, 1);
    expect(manager.tasks.first.status, DownloadStatus.paused);
    expect(manager.tasks.first.downloadedBytes, 0);
    expect(
      manager.tasks.first.logLines.any((l) => l.contains('restart')),
      isTrue,
    );
  });

  test('restored downloading task comes back paused, never auto-running',
      () async {
    final store = QueueStore(dirOverride: tmp);
    await store.save([
      DownloadTask(
        id: 'dl-1',
        title: 'Was downloading',
        sourceUrl: 'https://example.com/v/1',
        quality: quality('https://cdn.example.com/v.mp4'),
        platform: 'direct',
        fileName: 'Was downloading [720p].mp4',
      ).toJson()
        ..['status'] = 'downloading'
        ..['downloadedBytes'] = 100,
    ]);

    final manager = managerFor();
    await manager.restore();
    expect(manager.tasks.length, 1);
    expect(manager.tasks.first.status, DownloadStatus.paused);
    // No .part file exists, so progress resets to zero.
    expect(manager.tasks.first.downloadedBytes, 0);
    // The task was interrupted mid-download, so it carries the note.
    expect(
      manager.tasks.first.logLines.any((l) => l.contains('Restored')),
      isTrue,
    );
  });
}
