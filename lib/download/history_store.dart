// Download history: persisted JSON in the app documents directory.
// Stores titles, platform, quality label, saved location and outcome —
// never stream URLs or cookie values.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'downloads_channel.dart';

class HistoryEntry {
  final String title;
  final String sourceUrl;
  final String platform;
  final String qualityLabel;
  final String fileName;
  final String? savedLocation;
  final int? sizeBytes;
  final DateTime completedAt;
  final bool success;

  const HistoryEntry({
    required this.title,
    required this.sourceUrl,
    required this.platform,
    required this.qualityLabel,
    required this.fileName,
    this.savedLocation,
    this.sizeBytes,
    required this.completedAt,
    required this.success,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        'sourceUrl': sourceUrl,
        'platform': platform,
        'qualityLabel': qualityLabel,
        'fileName': fileName,
        'savedLocation': savedLocation,
        'sizeBytes': sizeBytes,
        'completedAt': completedAt.toIso8601String(),
        'success': success,
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) {
    return HistoryEntry(
      title: (json['title'] ?? 'Download').toString(),
      sourceUrl: (json['sourceUrl'] ?? '').toString(),
      platform: (json['platform'] ?? '').toString(),
      qualityLabel: (json['qualityLabel'] ?? '').toString(),
      fileName: (json['fileName'] ?? '').toString(),
      savedLocation: json['savedLocation']?.toString(),
      sizeBytes: json['sizeBytes'] is num
          ? (json['sizeBytes'] as num).toInt()
          : null,
      completedAt: DateTime.tryParse(
            (json['completedAt'] ?? '').toString(),
          ) ??
          DateTime.now(),
      success: json['success'] == true,
    );
  }
}

class HistoryStore extends ChangeNotifier {
  final List<HistoryEntry> entries = [];
  final Directory? dirOverride;
  final Future<Directory> Function()? dirResolver;
  bool _loaded = false;

  HistoryStore({this.dirOverride, this.dirResolver});

  /// App documents dir. Tests inject [dirOverride]; the app wires
  /// [dirResolver] (host channel — plain Context.filesDir, no
  /// path_provider, whose JNI lookup crashed the v1.0.0 release build).
  Future<Directory> get _dir async {
    if (dirOverride != null) return dirOverride!;
    if (dirResolver != null) return dirResolver!();
    return Directory(await DownloadsChannel.getFilesDir());
  }

  Future<File> get _file async =>
      File('${(await _dir).path}/download_history.json');

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file;
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map<String, dynamic>) {
              entries.add(HistoryEntry.fromJson(item));
            } else if (item is Map) {
              entries.add(
                HistoryEntry.fromJson(Map<String, dynamic>.from(item)),
              );
            }
          }
          entries.sort((a, b) => b.completedAt.compareTo(a.completedAt));
        }
      }
    } catch (_) {
      // Corrupt history file: start empty rather than crashing.
      entries.clear();
    }
    notifyListeners();
  }

  Future<void> add(HistoryEntry entry) async {
    entries.insert(0, entry);
    if (entries.length > 500) entries.removeRange(500, entries.length);
    notifyListeners();
    await _save();
  }

  Future<void> clear() async {
    entries.clear();
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    try {
      final file = await _file;
      await file.writeAsString(
        jsonEncode(entries.map((e) => e.toJson()).toList()),
      );
    } catch (_) {
      // History is best-effort; a failed write must not break downloads.
    }
  }
}
