// Persisted download queue (audit F-3).
//
// The download queue used to live only in memory: killing the app
// mid-download lost every queued/downloading task and orphaned its
// `.part` file. This store writes one JSON snapshot of the queue into the
// app documents directory and reads it back on launch, so interrupted
// downloads can be resumed instead of lost.
//
// Snapshot contents per task: id, title, source URL, platform, file name,
// quality (as JSON), status, downloaded bytes, total bytes, saved
// location, error, and HLS segment progress. Stream URLs inside the
// quality ARE persisted here — they are short-lived CDN links the app
// re-requests from the API on a fresh resolve anyway, and the queue file
// lives in the app-private documents directory, never in history.
// (History, by contrast, stores only the public source URL — see
// history_store.dart.)
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class QueueStore {
  final Directory? dirOverride;

  QueueStore({this.dirOverride});

  Future<File> get _file async {
    final dir =
        dirOverride ?? await getApplicationDocumentsDirectory();
    return File('${dir.path}/download_queue.json');
  }

  /// Load the saved queue snapshots. Missing or corrupt file -> empty.
  Future<List<Map<String, dynamic>>> load() async {
    try {
      final file = await _file;
      if (!await file.exists()) return [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! List) return [];
      final out = <Map<String, dynamic>>[];
      for (final item in decoded) {
        if (item is Map<String, dynamic>) {
          out.add(item);
        } else if (item is Map) {
          out.add(Map<String, dynamic>.from(item));
        }
      }
      return out;
    } catch (_) {
      // Corrupt queue file: start empty rather than crashing.
      return [];
    }
  }

  /// Save the queue snapshots. Best-effort: a failed write must never
  /// break a download in progress.
  Future<void> save(List<Map<String, dynamic>> snapshots) async {
    try {
      final file = await _file;
      // Write to a temp file then rename, so a kill mid-write cannot
      // leave a half-written queue behind.
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode(snapshots), flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      // The in-memory queue is the source of truth; persistence is a
      // convenience. Log nothing here — callers must not fail on this.
      debugPrint('QueueStore: failed to save queue snapshot.');
    }
  }

  /// Remove the saved queue entirely (used when the queue is empty).
  Future<void> clear() async {
    try {
      final file = await _file;
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort.
    }
  }
}
