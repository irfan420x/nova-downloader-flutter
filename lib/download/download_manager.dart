// Download manager: queue, pause/resume via HTTP Range, progress,
// cancel, retry, per-file log.
//
// Downloads bytes directly from the CDN (the API never proxies bytes).
// Per-quality headers returned by the API (Cookie, Referer, User-Agent)
// are sent on BOTH the probe and the download, per quality. Candidate
// URLs are tried in order: primary url, then alternates.
// Logs never contain full stream URLs or cookie values — host + header
// names only.
//
// Two behaviours worth knowing:
//   - HLS (.m3u8) qualities are NOT plain-downloaded: the playlist is
//     fetched, the best variant chosen, and every media segment is
//     downloaded and concatenated into one playable file (.ts, or .mp4
//     for fragmented MP4). See hls_downloader.dart (audit F-1).
//   - The queue is persisted (queue_store.dart): killing the app
//     mid-download no longer loses queued/downloading tasks — they come
//     back as Paused with their `.part` progress intact (audit F-3).
//     A foreground service is still missing, so Android may kill a
//     backgrounded download silently; that remainder is documented in
//     the README.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../api/models.dart';
import 'hls_downloader.dart';
import 'queue_store.dart';

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

  /// HLS only: media segments already written to the `.part` file.
  int hlsSegmentsDone = 0;

  /// HLS only: total segments in the playlist (for progress display).
  int? hlsTotalSegments;

  /// HLS only: the file prefix is complete and valid — either the
  /// playlist has no init segment, or its init segment was fully written
  /// AND flushed. The restore step restarts the stream when this is
  /// false but the `.part` file has bytes (a partial init segment).
  bool hlsInitDone = false;

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

  /// Serialise for the persisted queue (see queue_store.dart). Log lines
  /// are session-only and are not persisted.
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'sourceUrl': sourceUrl,
        'platform': platform,
        'fileName': fileName,
        'quality': quality.toJson(),
        'status': status.name,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'savedLocation': savedLocation,
        'error': error,
        'hlsSegmentsDone': hlsSegmentsDone,
        'hlsTotalSegments': hlsTotalSegments,
        'hlsInitDone': hlsInitDone,
      };

  /// Rebuild a task from a queue snapshot. Returns null when the
  /// snapshot is missing the fields a download cannot run without.
  static DownloadTask? tryFromJson(Map<String, dynamic> json) {
    final id = (json['id'] ?? '').toString();
    final title = (json['title'] ?? '').toString();
    final sourceUrl = (json['sourceUrl'] ?? '').toString();
    final qualityJson = json['quality'];
    if (id.isEmpty || title.isEmpty || sourceUrl.isEmpty) return null;
    if (qualityJson is! Map) return null;
    final quality = Quality.fromJson(
      Map<String, dynamic>.from(qualityJson),
    );
    if (quality.url.isEmpty) return null;
    final task = DownloadTask(
      id: id,
      title: title,
      sourceUrl: sourceUrl,
      quality: quality,
      platform: (json['platform'] ?? '').toString(),
      fileName: (json['fileName'] ?? 'download').toString(),
    );
    final statusName = (json['status'] ?? '').toString();
    task.status = DownloadStatus.values
        .where((s) => s.name == statusName)
        .firstOrNull ?? DownloadStatus.paused;
    task.downloadedBytes =
        json['downloadedBytes'] is num
            ? (json['downloadedBytes'] as num).toInt()
            : 0;
    task.totalBytes =
        json['totalBytes'] is num ? (json['totalBytes'] as num).toInt() : null;
    task.savedLocation = json['savedLocation']?.toString();
    task.error = json['error']?.toString();
    task.hlsSegmentsDone =
        json['hlsSegmentsDone'] is num
            ? (json['hlsSegmentsDone'] as num).toInt()
            : 0;
    task.hlsTotalSegments =
        json['hlsTotalSegments'] is num
            ? (json['hlsTotalSegments'] as num).toInt()
            : null;
    task.hlsInitDone = json['hlsInitDone'] == true;
    return task;
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
    case 'ts':
      return 'video/mp2t';
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
  final QueueStore? queueStore;

  final List<DownloadTask> tasks = [];
  final Map<String, HttpClientRequest> _activeRequests = {};
  final Map<String, bool> _cancelFlags = {};
  bool _running = false;
  int _idCounter = 0;

  /// True once restore() has run. Saves are suppressed before that so a
  /// fresh manager never overwrites a saved queue with an empty one.
  bool _restored = false;

  /// Last downloadedBytes value written to the queue file, per task —
  /// progress saves are throttled to 1 MB steps (see _maybeSaveProgress).
  final Map<String, int> _lastSavedBytes = {};

  DownloadManager({
    this.fileSaver,
    this.httpClientFactory,
    this.tempDirOverride,
    this.queueStore,
  });

  Future<Directory> get _tempDir async =>
      tempDirOverride != null ? tempDirOverride!() : await getTemporaryDirectory();

  /// Restore the persisted queue (call once at startup, before the UI
  /// shows the Downloads tab). Tasks that were downloading or queued when
  /// the app died come back as Paused — the user taps Resume to continue;
  /// nothing restarts on its own. `.part` files are reconciled against
  /// the snapshot: a missing part resets progress to zero, an existing
  /// part's real length is the ground truth for resume.
  Future<void> restore() async {
    if (_restored) return;
    _restored = true;
    final store = queueStore;
    if (store == null) return;
    final snapshots = await store.load();
    if (snapshots.isEmpty) return;
    final tempDir = await _tempDir;
    for (final snapshot in snapshots) {
      final task = DownloadTask.tryFromJson(snapshot);
      if (task == null) continue;
      final partFile = File('${tempDir.path}/${task.id}.part');
      final partExists = await partFile.exists();
      if (!partExists) {
        // The OS cleared the temp file: nothing to resume from.
        if (task.downloadedBytes > 0 || task.hlsSegmentsDone > 0) {
          task.log(
            'Partial file was cleared — this download will restart from the beginning.',
          );
        }
        task.downloadedBytes = 0;
        task.hlsSegmentsDone = 0;
        task.hlsInitDone = false;
      } else if (isHlsQuality(task.quality)) {
        // The part file's real length is the ground truth — but only
        // whole segments are valid. If the prefix is incomplete (the
        // init segment was never fully flushed), the part is unusable.
        task.downloadedBytes = await partFile.length();
        if (!task.hlsInitDone && task.downloadedBytes > 0) {
          await partFile.delete();
          task.downloadedBytes = 0;
          task.hlsSegmentsDone = 0;
          task.log(
            'Partial HLS prefix was incomplete — this stream will restart from the beginning.',
          );
        } else if (task.hlsTotalSegments != null &&
            task.hlsSegmentsDone > task.hlsTotalSegments!) {
          task.hlsSegmentsDone = task.hlsTotalSegments!;
        }
      } else {
        // Direct download: the part file's real length is the resume point.
        task.downloadedBytes = await partFile.length();
      }
      if (task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.queued) {
        task.status = DownloadStatus.paused;
        task.log(
          'Restored after an app restart — tap Resume to continue.',
        );
      }
      if (task.totalBytes != null && task.totalBytes! > 0) {
        task.progress =
            (task.downloadedBytes / task.totalBytes!).clamp(0.0, 1.0);
      } else if (task.hlsTotalSegments != null &&
          task.hlsTotalSegments! > 0) {
        task.progress =
            (task.hlsSegmentsDone / task.hlsTotalSegments!).clamp(0.0, 1.0);
      }
      task.addListener(notifyListeners);
      tasks.add(task);
    }
    // Keep the original queue order (oldest first in the file).
    notifyListeners();
  }

  /// Write the current queue to disk. Best-effort; never throws.
  Future<void> _saveQueue() async {
    if (!_restored) return;
    final store = queueStore;
    if (store == null) return;
    if (tasks.isEmpty) {
      await store.clear();
      return;
    }
    await store.save(tasks.map((t) => t.toJson()).toList());
  }

  /// Save the queue once per 1 MB of progress (a save on every chunk
  /// would hammer the disk; a save only on status changes would lose
  /// progress on a kill).
  void _maybeSaveProgress(DownloadTask task) {
    final last = _lastSavedBytes[task.id] ?? 0;
    if (task.downloadedBytes - last >= 1024 * 1024) {
      _lastSavedBytes[task.id] = task.downloadedBytes;
      unawaited(_saveQueue());
    }
  }

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
    unawaited(_saveQueue());
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
    unawaited(_saveQueue());
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
    unawaited(_saveQueue());
    _pump();
  }

  void cancel(String id) {
    final task = _find(id);
    if (task == null) return;
    _cancelFlags[id] = true;
    _activeRequests[id]?.abort();
    task.log('Cancelled by user.');
    task.update(status: DownloadStatus.cancelled);
    unawaited(_saveQueue());
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
    task.hlsSegmentsDone = 0;
    task.hlsTotalSegments = null;
    task.hlsInitDone = false;
    task.log('Retrying from the start…');
    task.update(status: DownloadStatus.queued, error: null);
    unawaited(_saveQueue());
    _pump();
  }

  void remove(String id) {
    final task = _find(id);
    if (task == null) return;
    if (task.status == DownloadStatus.downloading) cancel(id);
    tasks.remove(task);
    unawaited(_deletePartFile(task));
    unawaited(_saveQueue());
    notifyListeners();
  }

  Future<void> _deletePartFile(DownloadTask task) async {
    try {
      final dir = await _tempDir;
      final part = File('${dir.path}/${task.id}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {
      // Best-effort: the OS clears temp files eventually.
    }
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
      final tempDir = await _tempDir;
      final tempFile = File('${tempDir.path}/${task.id}.part');
      // A fresh (re)tried download starts from byte 0 — drop any stale part.
      if (task.downloadedBytes == 0 && await tempFile.exists()) {
        await tempFile.delete();
      }
      final File? downloaded;
      if (isHlsQuality(task.quality)) {
        downloaded = await _downloadHlsToFile(task, tempFile);
      } else {
        downloaded = await _downloadToFile(task, tempFile);
      }
      if (downloaded == null) return; // paused / cancelled handled inside.
      if (!tasks.contains(task)) {
        // The task was removed while downloading — do not save its file.
        return;
      }
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
        throw Exception(
          'Could not save the file to Downloads. On Android 10+ this '
          'needs the MediaStore channel; when the channel is unavailable '
          'the file cannot be moved into the public Downloads folder.',
        );
      }
      task.log('Saved to Downloads as ${task.fileName}');
      task.update(
        status: DownloadStatus.completed,
        progress: 1,
        savedLocation: location,
      );
      unawaited(_saveQueue());
    } on Exception catch (e) {
      if (task.status == DownloadStatus.paused ||
          task.status == DownloadStatus.cancelled) {
        return;
      }
      task.log('Failed: $e');
      task.update(status: DownloadStatus.failed, error: e.toString());
      unawaited(_saveQueue());
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
    // The total is authoritative ONLY when this GET response declares it
    // (Content-Length or Content-Range). A HEAD total is kept for display,
    // but a server that reports different lengths on HEAD vs GET (or a
    // chunked GET with no length at all) must not fail an otherwise good
    // download at the early-EOF check below (audit F-6).
    final contentLength =
        response.headers.value(HttpHeaders.contentLengthHeader);
    final contentRange =
        response.headers.value(HttpHeaders.contentRangeHeader);
    int? declaredTotal;
    if (contentRange != null) {
      final m = RegExp(r'/(\d+)\s*$').firstMatch(contentRange);
      if (m != null) declaredTotal = int.tryParse(m.group(1)!);
    }
    if (declaredTotal == null && contentLength != null) {
      final remaining = int.tryParse(contentLength);
      if (remaining != null) {
        declaredTotal =
            remaining + (response.statusCode == 206 ? task.downloadedBytes : 0);
      }
    }
    if (declaredTotal != null) task.totalBytes = declaredTotal;
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
        _maybeSaveProgress(task);
      }
    } finally {
      await sink.close();
    }
    if (declaredTotal != null && task.downloadedBytes < declaredTotal) {
      task.log(
        'Stream ended early (${task.downloadedBytes}/$declaredTotal bytes).',
      );
      return false;
    }
    task.progress = 1;
    return true;
  }

  /// HLS download: fetch the playlist, pick the best variant, download
  /// every media segment and concatenate them into [file]. Returns the
  /// file on success, null when paused/cancelled.
  Future<File?> _downloadHlsToFile(DownloadTask task, File file) async {
    final client =
        httpClientFactory != null ? httpClientFactory!() : HttpClient();
    try {
      for (final candidate in task.quality.candidateUrls) {
        if (_cancelFlags[task.id] == true) return null;
        final segmentsBefore = task.hlsSegmentsDone;
        final ok = await _tryHlsCandidate(client, task, candidate, file);
        if (ok) return file;
        if (_cancelFlags[task.id] == true) return null;
        if (task.hlsSegmentsDone > segmentsBefore) {
          // Partial segments from this candidate belong to a different
          // variant — they would corrupt the next candidate's stream.
          task.log(
            'Discarding partial HLS segments from ${hostOf(candidate)}.',
          );
          await file.writeAsBytes([]);
          task.hlsSegmentsDone = 0;
          task.downloadedBytes = 0;
          task.progress = 0;
        }
        task.log('Failed on ${hostOf(candidate)}, trying next source…');
      }
      throw Exception(
        'All sources failed for this HLS stream. Try another quality or retry later.',
      );
    } finally {
      client.close(force: true);
    }
  }

  /// One HLS attempt against one playlist URL. Returns true when every
  /// segment was downloaded and appended to [file].
  Future<bool> _tryHlsCandidate(
    HttpClient client,
    DownloadTask task,
    String playlistUrl,
    File file,
  ) async {
    final headers = task.quality.headers;
    final body = await _fetchText(
      client,
      task,
      playlistUrl,
      headers,
      'HLS playlist',
    );
    if (body == null) return false;
    var playlist = parseHlsPlaylist(body, playlistUrl);
    if (playlist.encrypted) {
      task.log(
        'This HLS stream is encrypted and cannot be downloaded.',
      );
      return false;
    }
    if (playlist.isMaster) {
      final variant = bestVariant(playlist);
      if (variant == null) {
        task.log('The HLS playlist has no playable variant.');
        return false;
      }
      task.log('HLS variant: ${hostOf(variant.url)} (best quality).');
      final variantBody = await _fetchText(
        client,
        task,
        variant.url,
        headers,
        'HLS variant playlist',
      );
      if (variantBody == null) return false;
      playlist = parseHlsPlaylist(variantBody, variant.url);
      if (playlist.encrypted) {
        task.log(
          'This HLS stream is encrypted and cannot be downloaded.',
        );
        return false;
      }
    }
    if (!playlist.isMedia || playlist.segments.isEmpty) {
      task.log('The HLS playlist contains no downloadable segments.');
      return false;
    }
    if (!playlist.hasEndList) {
      task.log(
        'This is a live HLS stream — live streams cannot be downloaded.',
      );
      return false;
    }
    // The saved file is the concatenated media, not the playlist:
    // MPEG-TS segments -> .ts, fragmented MP4 -> .mp4.
    _setHlsOutputExt(task, playlist.isFmp4 ? 'mp4' : 'ts');
    final totalSegments = playlist.segments.length;
    task.hlsTotalSegments = totalSegments;
    task.log(
      'HLS: $totalSegments segments'
      '${task.hlsSegmentsDone > 0 ? ' (${task.hlsSegmentsDone} already downloaded)' : ''}.',
    );

    final sink = file.openWrite(mode: FileMode.append);
    try {
      // Fragmented MP4 needs its init segment first — once per file.
      // The sink is flushed BEFORE hlsInitDone is set, and the queue is
      // saved right after, so a kill can never leave the queue claiming
      // an init segment the file does not have.
      if (playlist.initSegmentUrl != null && !task.hlsInitDone) {
        final initBytes = await _downloadSegmentBytes(
          client,
          task,
          playlist.initSegmentUrl!,
          headers,
        );
        if (initBytes == null) {
          task.log('Failed to download the HLS init segment.');
          return false;
        }
        sink.add(initBytes);
        await sink.flush();
        task.hlsInitDone = true;
        task.downloadedBytes += initBytes.length;
        task.update(downloadedBytes: task.downloadedBytes);
        await _saveQueue();
      } else if (playlist.initSegmentUrl == null && !task.hlsInitDone) {
        // MPEG-TS has no init segment: the prefix is valid as-is.
        task.hlsInitDone = true;
        await _saveQueue();
      }
      for (var i = task.hlsSegmentsDone; i < totalSegments; i++) {
        if (_cancelFlags[task.id] == true) return false;
        final segment = playlist.segments[i];
        List<int>? bytes;
        // Two attempts per segment; a failed segment fails the task
        // (it would leave a hole in the middle of the video).
        for (var attempt = 0; attempt < 2 && bytes == null; attempt++) {
          if (_cancelFlags[task.id] == true) return false;
          bytes = await _downloadSegmentBytes(
            client,
            task,
            segment.url,
            headers,
          );
        }
        if (bytes == null) {
          task.log(
            'Failed to download HLS segment ${i + 1}/$totalSegments.',
          );
          return false;
        }
        sink.add(bytes);
        // Flush BEFORE counting the segment, then save the queue: the
        // on-disk file always holds exactly hlsSegmentsDone whole
        // segments, so a kill mid-download resumes cleanly.
        await sink.flush();
        task.downloadedBytes += bytes.length;
        task.hlsSegmentsDone = i + 1;
        task.progress = task.hlsSegmentsDone / totalSegments;
        task.update(
          downloadedBytes: task.downloadedBytes,
          progress: task.progress,
          totalBytes: task.totalBytes,
        );
        await _saveQueue();
      }
    } finally {
      await sink.close();
    }
    task.progress = 1;
    return true;
  }

  /// Fetch a small text body (an HLS playlist) with the quality headers.
  /// Returns null on any failure (already logged).
  Future<String?> _fetchText(
    HttpClient client,
    DownloadTask task,
    String url,
    Map<String, String> headers,
    String what,
  ) async {
    final request = await client.getUrl(Uri.parse(url));
    for (final e in headers.entries) {
      request.headers.set(e.key, e.value);
    }
    _activeRequests[task.id] = request;
    try {
      final response = await request.close().timeout(
            const Duration(seconds: 30),
          );
      if (response.statusCode != 200) {
        task.log(
          '$what on ${hostOf(url)} returned HTTP ${response.statusCode}.',
        );
        await response.drain<void>();
        return null;
      }
      return await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 30));
    } on TimeoutException {
      task.log('$what timed out on ${hostOf(url)}.');
      return null;
    } catch (e) {
      task.log('Could not fetch $what (${hostOf(url)}): $e');
      return null;
    } finally {
      _activeRequests.remove(task.id);
    }
  }

  /// Download one HLS segment (or init segment) fully into memory, then
  /// return its bytes. Buffering per segment keeps a failed attempt from
  /// leaving a partial segment in the output file. Returns null on
  /// failure or when paused/cancelled.
  Future<List<int>?> _downloadSegmentBytes(
    HttpClient client,
    DownloadTask task,
    String url,
    Map<String, String> headers,
  ) async {
    final request = await client.getUrl(Uri.parse(url));
    for (final e in headers.entries) {
      request.headers.set(e.key, e.value);
    }
    _activeRequests[task.id] = request;
    try {
      final response = await request.close().timeout(
            const Duration(seconds: 60),
          );
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (_cancelFlags[task.id] == true) return null;
        bytes.addAll(chunk);
      }
      return bytes;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    } finally {
      _activeRequests.remove(task.id);
    }
  }

  /// The HLS output file is the concatenated media, not the playlist:
  /// rename `… .m3u8` to the real container extension (.ts / .mp4).
  void _setHlsOutputExt(DownloadTask task, String ext) {
    final name = task.fileName;
    final newName = name.toLowerCase().endsWith('.m3u8')
        ? '${name.substring(0, name.length - 5)}.$ext'
        : '$name.$ext';
    if (newName != name) {
      task.fileName = newName;
      task.notifyListeners();
    }
  }
}
