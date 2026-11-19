// Download manager: queue, pause/resume via HTTP Range, progress,
// cancel, retry, per-file log.
//
// Downloads bytes directly from the CDN (the API never proxies bytes).
// Per-quality headers returned by the API (Cookie, Referer, User-Agent)
// are sent on BOTH the probe and the download, per quality. Candidate
// URLs are tried in order: primary url, then alternates.
// Logs never contain full stream URLs or cookie values — host + header
// names only.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';

/// Moves a finished temp file into the public Downloads folder and returns
/// a URI/path the app can open/share later. On Android this goes through
/// a platform channel (MediaStore); on other platforms it is a plain copy.
/// Injected so tests can substitute a fake.
typedef FileSaver = Future<String?> Function(
  String tempPath,
  String displayName,
  String mimeType,
);

enum DownloadStatus {
  queued,
  downloading,
  paused,
  completed,
  failed,
  cancelled,
}

class DownloadTask extends ChangeNotifier {
  final String id;
  final String title;
  final String sourceUrl;
  final Quality quality;
  final String platform;

  DownloadStatus status = DownloadStatus.queued;
  double progress = 0;
  int downloadedBytes = 0;
  int? totalBytes;
  String? error;
  String? savedLocation; // content:// URI (Android) or file path.
  String fileName;
  final List<String> logLines = [];

  DownloadTask({
    required this.id,
    required this.title,
    required this.sourceUrl,
    required this.quality,
    required this.platform,
    required this.fileName,
  });

  void log(String message) {
    final stamp = DateTime.now().toIso8601String().substring(11, 19);
    logLines.add('[$stamp] $message');
    notifyListeners();
  }

  void update({
    DownloadStatus? status,
    double? progress,
    int? downloadedBytes,
    int? totalBytes,
    String? error,
    String? savedLocation,
  }) {
    if (status != null) this.status = status;
    if (progress != null) this.progress = progress;
    if (downloadedBytes != null) this.downloadedBytes = downloadedBytes;
    if (totalBytes != null) this.totalBytes = totalBytes;
    if (error != null) this.error = error;
    if (savedLocation != null) this.savedLocation = savedLocation;
    notifyListeners();
  }
}

/// Sanitise a title into a safe file name (no path separators, no
/// control characters, capped length).
String sanitizeFileName(String title, String label, String ext) {
  var base = title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
  base = base.replaceAll(RegExp(r'\s+'), ' ');
  if (base.isEmpty) base = 'download';
  if (base.length > 80) base = base.substring(0, 80).trim();
  final cleanLabel = label.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  final suffix = ext.isNotEmpty ? '.$ext' : '';
  return '$base [$cleanLabel]$suffix';
}

String mimeTypeForExt(String ext) {
  switch (ext.toLowerCase()) {
    case 'mp4':
      return 'video/mp4';
    case 'webm':
      return 'video/webm';
    case 'mkv':
      return 'video/x-matroska';
    case 'mov':
      return 'video/quicktime';
    case 'mp3':
      return 'audio/mpeg';
    case 'm4a':
      return 'audio/mp4';
    case 'aac':
      return 'audio/aac';
    case 'opus':
      return 'audio/opus';
    case 'wav':
      return 'audio/wav';
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'pdf':
      return 'application/pdf';
    default:
      return 'application/octet-stream';
  }
}

/// Host only, for logs — never log a full stream URL.
String hostOf(String url) {
  try {
    return Uri.parse(url).host;
  } catch (_) {
    return '(invalid url)';
  }
}

class DownloadManager extends ChangeNotifier {
  final FileSaver? fileSaver;
  final HttpClient Function()? httpClientFactory;
  final Directory Function()? tempDirOverride;

  final List<DownloadTask> tasks = [];
  final Map<String, HttpClientRequest> _activeRequests = {};
  final Map<String, bool> _cancelFlags = {};
  bool _running = false;
  int _idCounter = 0;

  DownloadManager({
    this.fileSaver,
    this.httpClientFactory,
    this.tempDirOverride,
  });

  DownloadTask addDownload({
    required String title,
    required String sourceUrl,
    required Quality quality,
    required String platform,
  }) {
    final fileName = sanitizeFileName(title, quality.label, quality.ext);
    final task = DownloadTask(
      id: 'dl-${DateTime.now().millisecondsSinceEpoch}-${_idCounter++}',
      title: title,
      sourceUrl: sourceUrl,
      quality: quality,
      platform: platform,
      fileName: fileName,
    );
    task.log('Queued: ${quality.label} (${quality.kindLabel})');
    tasks.insert(0, task);
    task.addListener(notifyListeners);
    notifyListeners();
    _pump();
    return task;
  }

  void pause(String id) {
    final task = _find(id);
    if (task == null) return;
    _cancelFlags[id] = true;
    _activeRequests[id]?.abort();
    task.log('Paused at ${task.downloadedBytes} bytes — resume keeps progress.');
    task.update(status: DownloadStatus.paused);
    _pump();
  }

  void resume(String id) {
    final task = _find(id);
    if (task == null) return;
    if (task.status != DownloadStatus.paused &&
        task.status != DownloadStatus.failed) {
      return;
    }
    task.log('Resuming…');
    task.update(status: DownloadStatus.queued, error: null);
    _pump();
  }

  void cancel(String id) {
    final task = _find(id);
    if (task == null) return;
    _cancelFlags[id] = true;
    _activeRequests[id]?.abort();
    task.log('Cancelled by user.');
    task.update(status: DownloadStatus.cancelled);
    _pump();
  }

  void retry(String id) {
    final task = _find(id);
    if (task == null) return;
    if (task.status != DownloadStatus.failed &&
        task.status != DownloadStatus.cancelled) {
      return;
    }
    task.downloadedBytes = 0;
    task.progress = 0;
    task.totalBytes = null;
    task.log('Retrying from the start…');
    task.update(status: DownloadStatus.queued, error: null);
    _pump();
  }

  void remove(String id) {
    final task = _find(id);
    if (task == null) return;
    if (task.status == DownloadStatus.downloading) cancel(id);
    tasks.remove(task);
    notifyListeners();
  }

  DownloadTask? _find(String id) {
    for (final t in tasks) {
      if (t.id == id) return t;
    }
    return null;
  }

  void _pump() {
    if (_running) return;
    final next = tasks.where((t) => t.status == DownloadStatus.queued);
    if (next.isEmpty) return;
    _running = true;
    _run(next.first).whenComplete(() {
      _running = false;
      _pump();
    });
  }

  Future<void> _run(DownloadTask task) async {
    _cancelFlags[task.id] = false;
    task.update(status: DownloadStatus.downloading);
    task.log('Starting download (${hostOf(task.quality.url)})');
    try {
      final tempDir = tempDirOverride != null
          ? tempDirOverride!()
          : await getTemporaryDirectory();
      final tempFile = File('${tempDir.path}/${task.id}.part');
      // A fresh (re)tried download starts from byte 0 — drop any stale part.
      if (task.downloadedBytes == 0 && await tempFile.exists()) {
        await tempFile.delete();
      }
      final downloaded = await _downloadToFile(task, tempFile);
      if (downloaded == null) return; // paused / cancelled handled inside.
      final saver = fileSaver;
      String? location;
      if (saver != null) {
        location = await saver(
          tempFile.path,
          task.fileName,
          mimeTypeForExt(task.quality.ext),
        );
      } else {
        // Fallback: keep the file in the temp dir (used on desktop/tests).
        location = tempFile.path;
      }
      if (location == null) {
        throw Exception('Could not save the file to Downloads.');
      }
      task.log('Saved to Downloads as ${task.fileName}');
      task.update(
        status: DownloadStatus.completed,
        progress: 1,
        savedLocation: location,
      );
    } on Exception catch (e) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        return;
      }
      task.log('Failed: $e');
      task.update(status: DownloadStatus.failed, error: e.toString());
    }
  }

  /// Downloads task.quality (trying url + alternates) into [file],
  /// resuming from [file]'s current length. Returns the file on success,
  /// null when paused/cancelled.
  Future<File?> _downloadToFile(DownloadTask task, File file) async {
    final client =
        httpClientFactory != null ? httpClientFactory!() : HttpClient();
    try {
      for (final candidate in task.quality.candidateUrls) {
        if (_cancelFlags[task.id] == true) return null;
        final host = hostOf(candidate);
        task.log('Trying $host…');
        final ok = await _tryDownload(client, task, candidate, file);
        if (ok) return file;
        if (_cancelFlags[task.id] == true) return null;
        task.log('Failed on $host, trying next source…');
      }
      throw Exception(
        'All sources failed for this quality. Try another quality or retry later.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// One attempt against one candidate URL. Returns true on success.
  Future<bool> _tryDownload(
    HttpClient client,
    DownloadTask task,
    String url,
    File file,
  ) async {
    final headers = task.quality.headers;
    final already = await file.exists() ? await file.length() : 0;
    // Probe: HEAD with the quality headers; fall back to a ranged GET.
    try {
      final probe = await client
          .headUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      for (final e in headers.entries) {
        probe.headers.set(e.key, e.value);
      }
      final probeResponse = await probe.close().timeout(
            const Duration(seconds: 30),
          );
      await probeResponse.drain<void>();
      if (probeResponse.statusCode >= 400) {
        task.log(
          'Probe on ${hostOf(url)} returned HTTP ${probeResponse.statusCode}.',
        );
        return false;
      }
      final lengthHeader =
          probeResponse.headers.value(HttpHeaders.contentLengthHeader);
      if (lengthHeader != null) {
        final total = int.tryParse(lengthHeader);
        if (total != null) {
          // HEAD reports the full file size.
          task.totalBytes = total;
        }
      }
    } catch (e) {
      task.log('Probe failed (${hostOf(url)}): $e — trying ranged GET.');
    }
    if (_cancelFlags[task.id] == true) return false;

    final request = await client.getUrl(Uri.parse(url));
    for (final e in headers.entries) {
      request.headers.set(e.key, e.value);
    }
    if (already > 0) {
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=$already-');
    }
    _activeRequests[task.id] = request;
    HttpClientResponse response;
    try {
      response = await request.close().timeout(
            const Duration(seconds: 60),
          );
    } on TimeoutException {
      task.log('Download request timed out on ${hostOf(url)}.');
      return false;
    } finally {
      _activeRequests.remove(task.id);
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      task.log(
        'Download on ${hostOf(url)} returned HTTP ${response.statusCode}.',
      );
      await response.drain<void>();
      return false;
    }
    if (response.statusCode == 200 && already > 0) {
      // Server ignored Range — restart from scratch.
      task.log('Server ignored resume; restarting download.');
      await file.writeAsBytes([]);
      task.downloadedBytes = 0;
    }
    final contentLength =
        response.headers.value(HttpHeaders.contentLengthHeader);
    if (contentLength != null) {
      final remaining = int.tryParse(contentLength);
      if (remaining != null) {
        task.totalBytes =
            remaining + (response.statusCode == 206 ? task.downloadedBytes : 0);
      }
    }
    final sink = file.openWrite(mode: FileMode.append);
    try {
      await for (final chunk in response) {
        if (_cancelFlags[task.id] == true) {
          await sink.close();
          return false;
        }
        sink.add(chunk);
        task.downloadedBytes += chunk.length;
        if (task.totalBytes != null && task.totalBytes! > 0) {
          task.progress = (task.downloadedBytes / task.totalBytes!)
              .clamp(0.0, 1.0);
        }
        task.update(
          downloadedBytes: task.downloadedBytes,
          progress: task.progress,
          totalBytes: task.totalBytes,
        );
      }
    } finally {
      await sink.close();
    }
    if (task.totalBytes != null && task.downloadedBytes < task.totalBytes!) {
      task.log(
        'Stream ended early (${task.downloadedBytes}/${task.totalBytes} bytes).',
      );
      return false;
    }
    task.progress = 1;
    return true;
  }
}
