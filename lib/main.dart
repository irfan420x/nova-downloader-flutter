// NOVA Downloader — Flutter, API-only.
//
// Resolves links ONLY through the NOVA Downloader API
// (https://nova-downloader-api.vercel.app) and downloads bytes directly
// from CDNs. No local extractors, no yt-dlp, no local fallback.
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:path_provider/path_provider.dart';

import 'api/api_client.dart';
import 'download/download_manager.dart';
import 'download/downloads_channel.dart';
import 'download/history_store.dart';
import 'download/queue_store.dart';
import 'theme/nebula.dart';
import 'ui/downloads_screen.dart';
import 'ui/history_screen.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final api = ApiClient();
  final downloads = DownloadManager(
    fileSaver: defaultFileSaver,
    queueStore: QueueStore(),
  );
  final history = HistoryStore();
  // Restore before the first frame so interrupted downloads are visible
  // immediately (as Paused) instead of popping in later.
  await downloads.restore();
  await history.load();
  final sharedLink = ValueNotifier<String?>(null);
  DownloadsChannel.setSharedLinkHandler((link) {
    sharedLink.value = link;
  });
  runApp(
    NovaDownloaderApp(
      api: api,
      downloads: downloads,
      history: history,
      sharedLink: sharedLink,
    ),
  );
}

/// Default file saver: on Android, move the finished file into the public
/// Downloads folder via MediaStore (platform channel); elsewhere, copy it
/// into the public Downloads directory when available.
Future<String?> defaultFileSaver(
  String tempPath,
  String displayName,
  String mimeType,
) async {
  if (Platform.isAndroid) {
    final uri = await DownloadsChannel.moveToDownloads(
      tempPath,
      displayName,
      mimeType,
    );
    if (uri != null) return uri;
    // Channel unavailable (e.g. running under `flutter test` or an old
    // build): fall through to the plain copy below, which on Android 10+
    // is blocked by scoped storage and returns null — the download then
    // fails with an honest message instead of a silent loss.
  }
  try {
    final downloads = await getDownloadsDirectory();
    final targetDir = downloads ?? await getApplicationDocumentsDirectory();
    final dest = File('${targetDir.path}/$displayName');
    await File(tempPath).copy(dest.path);
    return dest.path;
  } catch (_) {
    return null;
  }
}

class NovaDownloaderApp extends StatefulWidget {
  final ApiClient api;
  final DownloadManager downloads;
  final HistoryStore history;
  final ValueNotifier<String?> sharedLink;

  const NovaDownloaderApp({
    super.key,
    required this.api,
    required this.downloads,
    required this.history,
    required this.sharedLink,
  });

  @override
  State<NovaDownloaderApp> createState() => _NovaDownloaderAppState();
}

class _NovaDownloaderAppState extends State<NovaDownloaderApp> {
  late final ApiClient _api;
  late final DownloadManager _downloads;
  late final HistoryStore _history;
  bool _apiHealthy = true;
  bool _healthChecked = false;
  int _tabIndex = 0;

  /// Task ids already recorded in history, so a task is never logged twice.
  final Set<String> _recorded = {};

  @override
  void initState() {
    super.initState();
    _api = widget.api;
    _downloads = widget.downloads;
    _history = widget.history;
    _downloads.addListener(_onDownloadsChanged);
    _checkHealth();
  }

  @override
  void dispose() {
    _downloads.removeListener(_onDownloadsChanged);
    _api.close();
    super.dispose();
  }

  void _onDownloadsChanged() {
    for (final task in _downloads.tasks) {
      if ((task.status == DownloadStatus.completed ||
              task.status == DownloadStatus.failed) &&
          !_recorded.contains(task.id)) {
        _recorded.add(task.id);
        final completed = task.status == DownloadStatus.completed;
        _history.add(
          HistoryEntry(
            title: task.title,
            sourceUrl: task.sourceUrl,
            platform: task.platform,
            qualityLabel: task.quality.label,
            fileName: task.fileName,
            savedLocation: task.savedLocation,
            // Only a finished file has a real size — a failed entry's
            // partial bytes are not the file size (audit F-3 note).
            sizeBytes: completed ? task.downloadedBytes : null,
            completedAt: DateTime.now(),
            success: completed,
          ),
        );
      }
    }
  }

  Future<void> _checkHealth() async {
    // Fetch the API's endpoint list too, so future endpoints light up
    // without an app update (falls back to the known list on failure).
    final healthy = await _api.checkHealth();
    await _api.fetchEndpoints();
    if (mounted) {
      setState(() {
        _apiHealthy = healthy;
        _healthChecked = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        api: _api,
        downloads: _downloads,
        apiHealthy: _apiHealthy,
        incomingLink: widget.sharedLink,
        onDownloadStarted: () => setState(() => _tabIndex = 1),
      ),
      DownloadsScreen(manager: _downloads),
      HistoryScreen(store: _history),
    ];
    return MaterialApp(
      title: 'NOVA Downloader',
      theme: nebulaTheme(),
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  gradient: NebulaColors.primaryGradient,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.bolt,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'NOVA Downloader',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_healthChecked)
                Icon(
                  _apiHealthy ? Icons.cloud_done : Icons.cloud_off,
                  color: _apiHealthy
                      ? NebulaColors.success
                      : NebulaColors.warning,
                  size: 20,
                ),
            ],
          ),
        ),
        body: pages[_tabIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (i) => setState(() => _tabIndex = i),
          backgroundColor: NebulaColors.card,
          indicatorColor: NebulaColors.primary.withValues(alpha: 0.25),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.link),
              label: 'Download',
            ),
            NavigationDestination(
              icon: Icon(Icons.download),
              label: 'Downloads',
            ),
            NavigationDestination(
              icon: Icon(Icons.history),
              label: 'History',
            ),
          ],
        ),
      ),
    );
  }
}
