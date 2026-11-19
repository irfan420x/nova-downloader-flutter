// Downloads tab: queue with progress, pause/resume, cancel, retry,
// per-file log, and open/share/delete for finished files.
import 'package:material_ui/material_ui.dart';

import '../api/platform_detect.dart';
import '../download/download_manager.dart';
import '../download/downloads_channel.dart';
import '../theme/nebula.dart';
import 'format.dart';

class DownloadsScreen extends StatelessWidget {
  final DownloadManager manager;

  const DownloadsScreen({super.key, required this.manager});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        if (manager.tasks.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No downloads yet.\nPaste a link on the Download tab to start.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NebulaColors.textSecondary),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: manager.tasks.length,
          itemBuilder: (context, i) {
            final task = manager.tasks[i];
            return _TaskCard(task: task, manager: manager);
          },
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  final DownloadTask task;
  final DownloadManager manager;

  const _TaskCard({required this.task, required this.manager});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: task,
      builder: (context, _) {
        final status = task.status;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        task.title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    _statusChip(status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${platformDisplayName(task.platform)} · ${task.quality.label} · ${task.quality.kindLabel}',
                  style: const TextStyle(color: NebulaColors.textSecondary),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: status == DownloadStatus.completed
                      ? 1
                      : (task.progress > 0 ? task.progress : null),
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  color: status == DownloadStatus.failed
                      ? NebulaColors.error
                      : NebulaColors.primary,
                ),
                const SizedBox(height: 6),
                Text(
                  status == DownloadStatus.completed
                      ? formatBytes(task.downloadedBytes)
                      : '${formatBytes(task.downloadedBytes)}'
                          '${task.totalBytes != null ? ' / ${formatBytes(task.totalBytes)}' : ''}'
                          ' · ${(task.progress * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: NebulaColors.textSecondary),
                ),
                if (task.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      task.error!,
                      style: const TextStyle(color: NebulaColors.error),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (status == DownloadStatus.downloading)
                      OutlinedButton.icon(
                        onPressed: () => manager.pause(task.id),
                        icon: const Icon(Icons.pause, size: 18),
                        label: const Text('Pause'),
                      ),
                    if (status == DownloadStatus.paused)
                      ElevatedButton.icon(
                        onPressed: () => manager.resume(task.id),
                        icon: const Icon(Icons.play_arrow, size: 18),
                        label: const Text('Resume'),
                      ),
                    if (status == DownloadStatus.failed ||
                        status == DownloadStatus.cancelled)
                      ElevatedButton.icon(
                        onPressed: () => manager.retry(task.id),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Retry'),
                      ),
                    if (status == DownloadStatus.downloading ||
                        status == DownloadStatus.queued)
                      OutlinedButton.icon(
                        onPressed: () => manager.cancel(task.id),
                        icon: const Icon(Icons.close, size: 18),
                        label: const Text('Cancel'),
                      ),
                    if (status == DownloadStatus.completed &&
                        task.savedLocation != null)
                      OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await DownloadsChannel.openFile(
                            task.savedLocation!,
                            mimeTypeForExt(task.quality.ext),
                          );
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'No app can open this file type.',
                                ),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('Open'),
                      ),
                    if (status == DownloadStatus.completed &&
                        task.savedLocation != null)
                      OutlinedButton.icon(
                        onPressed: () async {
                          final ok = await DownloadsChannel.shareFile(
                            task.savedLocation!,
                            mimeTypeForExt(task.quality.ext),
                          );
                          if (!ok && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Sharing failed.'),
                              ),
                            );
                          }
                        },
                        icon: const Icon(Icons.share, size: 18),
                        label: const Text('Share'),
                      ),
                    if (status == DownloadStatus.completed ||
                        status == DownloadStatus.failed ||
                        status == DownloadStatus.cancelled)
                      TextButton.icon(
                        onPressed: () async {
                          if (task.savedLocation != null) {
                            await DownloadsChannel.deleteFile(
                              task.savedLocation!,
                            );
                          }
                          manager.remove(task.id);
                        },
                        icon: const Icon(Icons.delete, size: 18),
                        label: const Text('Delete'),
                      ),
                    TextButton.icon(
                      onPressed: () => _showLog(context, task),
                      icon: const Icon(Icons.receipt_long, size: 18),
                      label: const Text('Log'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statusChip(DownloadStatus status) {
    final label = switch (status) {
      DownloadStatus.queued => 'Queued',
      DownloadStatus.downloading => 'Downloading',
      DownloadStatus.paused => 'Paused',
      DownloadStatus.completed => 'Done',
      DownloadStatus.failed => 'Failed',
      DownloadStatus.cancelled => 'Cancelled',
    };
    final color = switch (status) {
      DownloadStatus.completed => NebulaColors.success,
      DownloadStatus.failed => NebulaColors.error,
      DownloadStatus.paused => NebulaColors.warning,
      _ => NebulaColors.secondary,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }

  void _showLog(BuildContext context, DownloadTask task) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Download log'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              task.logLines.isEmpty
                  ? 'No log entries yet.'
                  : task.logLines.join('\n'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
