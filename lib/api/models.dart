// Data models for the NOVA Downloader API.
// Contract: ~/workspace/nova-downloader-review/API-CHECK-2026-11-19.md
// Success: {title, thumbnail?, source, qualities[{id, label, ext, url,
//   alternates[], headers{User-Agent, Referer, Cookie}, size, videoOnly,
//   audioOnly}], debug{platform, ms, attempts[]}}
// Error: {error:{code, message}, debug}

/// One downloadable quality returned by the API.
class Quality {
  final String id;
  final String label;
  final String ext;
  final String url;
  final List<String> alternates;
  final Map<String, String> headers;
  final int? size;
  final bool videoOnly;
  final bool audioOnly;

  const Quality({
    required this.id,
    required this.label,
    required this.ext,
    required this.url,
    this.alternates = const [],
    this.headers = const {},
    this.size,
    this.videoOnly = false,
    this.audioOnly = false,
  });

  factory Quality.fromJson(Map<String, dynamic> json) {
    final headers = <String, String>{};
    final rawHeaders = json['headers'];
    if (rawHeaders is Map) {
      for (final entry in rawHeaders.entries) {
        headers[entry.key.toString()] = entry.value?.toString() ?? '';
      }
    }
    final alternates = <String>[];
    final rawAlt = json['alternates'];
    if (rawAlt is List) {
      for (final a in rawAlt) {
        if (a is String && a.isNotEmpty) alternates.add(a);
      }
    }
    return Quality(
      id: (json['id'] ?? json['label'] ?? '').toString(),
      label: (json['label'] ?? json['id'] ?? 'Unknown').toString(),
      ext: (json['ext'] ?? '').toString(),
      url: (json['url'] ?? '').toString(),
      alternates: alternates,
      headers: headers,
      size: json['size'] is num ? (json['size'] as num).toInt() : null,
      videoOnly: json['videoOnly'] == true,
      audioOnly: json['audioOnly'] == true,
    );
  }

  /// All candidate URLs to try in order: primary first, then alternates.
  List<String> get candidateUrls => [url, ...alternates];

  /// Human-readable kind badge: "Video + audio", "Video only", "Audio only".
  String get kindLabel {
    if (audioOnly) return 'Audio only';
    if (videoOnly) return 'Video only — no audio';
    return 'Video + audio';
  }

  bool get isCombined => !videoOnly && !audioOnly;
}

/// Result of a successful resolve call.
class ResolveResult {
  final String title;
  final String? thumbnail;
  final String source;
  final List<Quality> qualities;
  final String? platform;
  final int? resolveMs;

  const ResolveResult({
    required this.title,
    this.thumbnail,
    required this.source,
    required this.qualities,
    this.platform,
    this.resolveMs,
  });

  factory ResolveResult.fromJson(Map<String, dynamic> json) {
    final rawQualities = json['qualities'];
    final qualities = <Quality>[];
    if (rawQualities is List) {
      for (final q in rawQualities) {
        if (q is Map<String, dynamic>) {
          final quality = Quality.fromJson(q);
          if (quality.url.isNotEmpty) qualities.add(quality);
        } else if (q is Map) {
          final quality =
              Quality.fromJson(Map<String, dynamic>.from(q));
          if (quality.url.isNotEmpty) qualities.add(quality);
        }
      }
    }
    // Dedupe by URL (SoundCloud returns duplicate labels for the same
    // preset). Keep the first occurrence; prefer a combined entry when
    // two entries share a label.
    final deduped = dedupeQualities(qualities);
    final debug = json['debug'];
    String? platform;
    int? ms;
    if (debug is Map) {
      platform = debug['platform']?.toString();
      if (debug['ms'] is num) ms = (debug['ms'] as num).toInt();
    }
    return ResolveResult(
      title: (json['title'] ?? 'Download').toString(),
      thumbnail: json['thumbnail']?.toString(),
      source: (json['source'] ?? '').toString(),
      qualities: deduped,
      platform: platform,
      resolveMs: ms,
    );
  }
}

/// Dedupe qualities by URL. When two entries share a label, prefer the
/// combined (video+audio) one over a video-only one.
List<Quality> dedupeQualities(List<Quality> qualities) {
  final byUrl = <String, Quality>{};
  for (final q in qualities) {
    byUrl.putIfAbsent(q.url, () => q);
  }
  final byLabel = <String, Quality>{};
  for (final q in byUrl.values) {
    final existing = byLabel[q.label];
    if (existing == null) {
      byLabel[q.label] = q;
    } else if (existing.videoOnly && q.isCombined) {
      byLabel[q.label] = q;
    }
  }
  return byLabel.values.toList();
}

/// An honest API error surfaced to the user (never a generic "failed").
class ApiException implements Exception {
  final String code;
  final String message;
  final String? platform;

  const ApiException(this.code, this.message, {this.platform});

  @override
  String toString() => '[$code] $message';
}
