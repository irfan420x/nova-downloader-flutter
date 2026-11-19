// History tab: past downloads, newest first.
import 'package:material_ui/material_ui.dart';

import '../api/platform_detect.dart';
import '../download/history_store.dart';
import '../theme/nebula.dart';
import 'format.dart';

class HistoryScreen extends StatelessWidget {
  final HistoryStore store;

  const HistoryScreen({super.key, required this.store});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: store,
      builder: (context, _) {
        if (store.entries.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(32),
              child: Text(
                'No history yet.\nFinished downloads show up here.',
                textAlign: TextAlign.center,
                style: TextStyle(color: NebulaColors.textSecondary),
              ),
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: store.entries.length,
                itemBuilder: (context, i) {
                  final entry = store.entries[i];
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        entry.success
                            ? Icons.check_circle
                            : Icons.error_outline,
                        color: entry.success
                            ? NebulaColors.success
                            : NebulaColors.error,
                      ),
                      title: Text(
                        entry.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${platformDisplayName(entry.platform)} · ${entry.qualityLabel} · ${formatAgo(entry.completedAt)}'
                        '${entry.sizeBytes != null ? ' · ${formatBytes(entry.sizeBytes)}' : ''}',
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: TextButton.icon(
                onPressed: () => store.clear(),
                icon: const Icon(Icons.delete_sweep),
                label: const Text('Clear history'),
              ),
            ),
          ],
        );
      },
    );
  }
}
