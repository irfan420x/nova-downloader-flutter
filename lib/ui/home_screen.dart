// Home tab: paste a link -> detect platform -> resolve via the API ->
// quality sheet with every quality -> download.
//
// The API is the ONLY resolver. No local extractors, no yt-dlp, no
// fallback. If the API fails, its honest error message is shown.
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../api/api_client.dart';
import '../api/models.dart';
import '../api/platform_detect.dart';
import '../download/download_manager.dart';
import '../theme/nebula.dart';
import 'format.dart';

class HomeScreen extends StatefulWidget {
  final ApiClient api;
  final DownloadManager downloads;
  final bool apiHealthy;
  final VoidCallback onDownloadStarted;

  const HomeScreen({
    super.key,
    required this.api,
    required this.downloads,
    required this.apiHealthy,
    required this.onDownloadStarted,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _linkController = TextEditingController();
  bool _resolving = false;
  String? _error;
  String? _detected;

  @override
  void dispose() {
    _linkController.dispose();
    super.dispose();
  }

  void _onLinkChanged(String value) {
    final detected = detectPlatform(value);
    setState(() {
      _detected = detected;
      _error = null;
    });
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      _linkController.text = text;
      _onLinkChanged(text);
    }
  }

  Future<void> _resolve() async {
    final url = _linkController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Paste a link first.');
      return;
    }
    final platform = detectPlatform(url);
    if (platform == null) {
      setState(
        () => _error = 'That does not look like a valid http(s) link.',
      );
      return;
    }
    if (!supportedPlatforms.contains(platform)) {
      setState(() => _error = unsupportedPlatforms[platform]);
      return;
    }
    setState(() {
      _resolving = true;
      _error = null;
    });
    try {
      final result = await widget.api.resolve(platform, url);
      if (!mounted) return;
      setState(() => _resolving = false);
      await _showQualitySheet(result, url, platform);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = '[${e.code}] ${e.message}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = 'Could not reach the API: $e';
      });
    }
  }

  Future<void> _showQualitySheet(
    ResolveResult result,
    String url,
    String platform,
  ) async {
    // Combined formats first, then video-only, then audio-only.
    final qualities = List<Quality>.from(result.qualities)
      ..sort((a, b) {
        int rank(Quality q) => q.isCombined ? 0 : (q.videoOnly ? 1 : 2);
        return rank(a).compareTo(rank(b));
      });
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: NebulaColors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.7,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (result.thumbnail != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        result.thumbnail!,
                        height: 140,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    result.title,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${platformDisplayName(platform)}'
                    '${result.resolveMs != null ? ' · resolved in ${(result.resolveMs! / 1000).toStringAsFixed(1)}s' : ''}',
                    style: const TextStyle(color: NebulaColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Choose quality',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: qualities.isEmpty
                        ? const Center(
                            child: Text(
                              'The API returned no downloadable qualities for this link.',
                            ),
                          )
                        : ListView.separated(
                            controller: scrollController,
                            itemCount: qualities.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, i) {
                              final q = qualities[i];
                              return _QualityRow(
                                quality: q,
                                onDownload: () {
                                  widget.downloads.addDownload(
                                    title: result.title,
                                    sourceUrl: url,
                                    quality: q,
                                    platform: platform,
                                  );
                                  Navigator.of(context).pop();
                                  widget.onDownloadStarted();
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Downloading ${q.label} — see the Downloads tab.',
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Video-only files have no audio. Merging video + audio is not supported yet — download both parts if you need them.',
                    style: TextStyle(
                      fontSize: 12,
                      color: NebulaColors.textSecondary,
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final detected = _detected;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        if (!widget.apiHealthy)
          const Card(
            color: NebulaColors.card,
            child: ListTile(
              leading: Icon(Icons.cloud_off, color: NebulaColors.warning),
              title: Text('API unreachable'),
              subtitle: Text(
                'The NOVA Downloader API did not answer the health check. '
                'Resolving may fail until it is back — check your connection.',
              ),
            ),
          ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            gradient: NebulaColors.primaryGradient,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: const EdgeInsets.all(20),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Download anything',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              SizedBox(height: 6),
              Text(
                'Paste a video, audio or file link — the API finds every quality, you pick one.',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _linkController,
          onChanged: _onLinkChanged,
          keyboardType: TextInputType.url,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => _resolve(),
          decoration: InputDecoration(
            hintText: 'Paste a link… (YouTube, TikTok, Facebook, X, SoundCloud, direct file, .m3u8)',
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste),
              tooltip: 'Paste from clipboard',
              onPressed: _pasteFromClipboard,
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (detected != null)
          Chip(
            avatar: Icon(
              supportedPlatforms.contains(detected)
                  ? Icons.check_circle
                  : Icons.info_outline,
              size: 18,
              color: supportedPlatforms.contains(detected)
                  ? NebulaColors.success
                  : NebulaColors.warning,
            ),
            label: Text(
              supportedPlatforms.contains(detected)
                  ? 'Detected: ${platformDisplayName(detected)}'
                  : '${platformDisplayName(detected)} — not supported yet',
            ),
          ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _resolving ? null : _resolve,
            icon: _resolving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.download),
            label: Text(_resolving ? 'Resolving…' : 'Find downloads'),
          ),
        ),
        if (_resolving)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Resolving… the API can take up to ~50s on a cold start. Please wait.',
              style: TextStyle(color: NebulaColors.textSecondary),
              textAlign: TextAlign.center,
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              color: NebulaColors.card,
              child: ListTile(
                leading: const Icon(
                  Icons.error_outline,
                  color: NebulaColors.error,
                ),
                title: Text(_error!),
              ),
            ),
          ),
        const SizedBox(height: 24),
        const Text(
          'Supported now',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('YouTube')),
            Chip(label: Text('TikTok')),
            Chip(label: Text('Facebook')),
            Chip(label: Text('X')),
            Chip(label: Text('SoundCloud')),
            Chip(label: Text('Direct file')),
            Chip(label: Text('HLS (.m3u8)')),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'Not supported yet: Instagram, Pinterest, Twitch, Reddit, Vimeo, Dailymotion — the API has no endpoint for these yet.',
          style: TextStyle(color: NebulaColors.textSecondary),
        ),
      ],
    );
  }
}

class _QualityRow extends StatelessWidget {
  final Quality quality;
  final VoidCallback onDownload;

  const _QualityRow({required this.quality, required this.onDownload});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        title: Text(quality.label),
        subtitle: Text(
          '${quality.kindLabel} · ${formatBytes(quality.size)}'
          '${quality.ext.isNotEmpty ? ' · .${quality.ext}' : ''}',
        ),
        trailing: IconButton(
          icon: const Icon(Icons.download, color: NebulaColors.primary),
          tooltip: 'Download ${quality.label}',
          onPressed: onDownload,
        ),
        onTap: onDownload,
      ),
    );
  }
}
