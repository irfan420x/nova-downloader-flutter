// HLS (.m3u8) support: playlist parsing + segment downloading.
//
// Why this file exists (audit F-1): the app used to plain-GET a variant
// .m3u8 URL and save it as a file — a playlist, not a video, effectively
// unplayable from local storage. A real HLS download fetches the playlist,
// picks the best variant, then downloads every media segment and
// concatenates them into one playable file (MPEG-TS, or fragmented MP4
// when the playlist carries an #EXT-X-MAP init segment).
//
// Honest limits, stated where they are enforced:
//   - Encrypted streams (#EXT-X-KEY) are refused, never faked.
//   - Live streams (no #EXT-X-ENDLIST) are refused — there is no end.
//   - Segments are downloaded sequentially with the same per-quality
//     headers the API returned (Cookie / Referer / User-Agent).
//   - Progress is by segment count, not bytes: segment sizes are not
//     known up front, so totalBytes stays unknown for HLS tasks.
import '../api/models.dart';

/// True when [quality] is an HLS stream (its ext is m3u8, or its URL's
/// path ends in .m3u8 — the query string is NOT consulted, so a URL that
/// merely mentions ".m3u8" in a parameter is not misrouted).
bool isHlsQuality(Quality quality) {
  if (quality.ext.toLowerCase() == 'm3u8') return true;
  return urlPathEndsWithM3u8(quality.url);
}

/// True when [url]'s path (not its query string) ends in `.m3u8`.
bool urlPathEndsWithM3u8(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return false;
  return uri.path.toLowerCase().endsWith('.m3u8');
}

/// One variant rendition of a master playlist.
class HlsVariant {
  final String url;
  final int bandwidth;

  const HlsVariant({required this.url, required this.bandwidth});
}

/// One media segment of a media playlist.
class HlsSegment {
  final String url;
  final double durationSeconds;

  const HlsSegment({required this.url, required this.durationSeconds});
}

/// A parsed HLS playlist — either a master playlist (variants) or a
/// media playlist (segments), or both fields when a playlist is unusual.
class HlsPlaylist {
  /// Variant renditions (master playlist). Empty for a media playlist.
  final List<HlsVariant> variants;

  /// Media segments (media playlist). Empty for a master playlist.
  final List<HlsSegment> segments;

  /// #EXT-X-MAP init segment (fragmented MP4). Null for MPEG-TS.
  final String? initSegmentUrl;

  /// True when the playlist ends with #EXT-X-ENDLIST (a VOD, not live).
  final bool hasEndList;

  /// True when any #EXT-X-KEY tag is present (encrypted segments).
  final bool encrypted;

  const HlsPlaylist({
    this.variants = const [],
    this.segments = const [],
    this.initSegmentUrl,
    this.hasEndList = false,
    this.encrypted = false,
  });

  bool get isMaster => variants.isNotEmpty;
  bool get isMedia => segments.isNotEmpty;

  /// Fragmented MP4 when an init segment exists or segments are .m4s.
  bool get isFmp4 {
    if (initSegmentUrl != null) return true;
    return segments.any(
      (s) => Uri.tryParse(s.url)?.path.toLowerCase().endsWith('.m4s') ?? false,
    );
  }

  double get totalDurationSeconds =>
      segments.fold(0.0, (sum, s) => sum + s.durationSeconds);
}

/// Parse an .m3u8 playlist body. [playlistUrl] is used to resolve
/// relative segment/variant/init URIs (per RFC 8216 §4.1).
HlsPlaylist parseHlsPlaylist(String body, String playlistUrl) {
  final variants = <HlsVariant>[];
  final segments = <HlsSegment>[];
  String? initSegmentUrl;
  var hasEndList = false;
  var encrypted = false;

  String resolve(String uri) {
    try {
      return Uri.parse(playlistUrl).resolve(uri).toString();
    } catch (_) {
      return uri;
    }
  }

  final lines = body.split('\n').map((l) => l.trim()).where(
        (l) => l.isNotEmpty,
      );
  var pendingBandwidth = 0;
  var pendingDuration = 0.0;
  var expectVariant = false;
  var expectSegment = false;

  for (final line in lines) {
    if (line.startsWith('#')) {
      if (line.startsWith('#EXT-X-STREAM-INF:')) {
        pendingBandwidth = _attributeInt(line, 'BANDWIDTH') ?? 0;
        expectVariant = true;
        expectSegment = false;
      } else if (line.startsWith('#EXT-X-MAP:')) {
        final uri = _attributeString(line, 'URI');
        if (uri != null) initSegmentUrl = resolve(uri);
      } else if (line.startsWith('#EXT-X-KEY:')) {
        encrypted = true;
      } else if (line.startsWith('#EXTINF:')) {
        final rest = line.substring('#EXTINF:'.length);
        final durationText = rest.split(',').first.trim();
        pendingDuration = double.tryParse(durationText) ?? 0.0;
        expectSegment = true;
        expectVariant = false;
      } else if (line == '#EXT-X-ENDLIST') {
        hasEndList = true;
      }
      continue;
    }
    // A bare URI line: it belongs to the tag directly above it.
    if (expectVariant) {
      variants.add(
        HlsVariant(url: resolve(line), bandwidth: pendingBandwidth),
      );
      expectVariant = false;
      pendingBandwidth = 0;
    } else if (expectSegment) {
      segments.add(
        HlsSegment(url: resolve(line), durationSeconds: pendingDuration),
      );
      expectSegment = false;
      pendingDuration = 0.0;
    }
    // Any other bare line (e.g. a stray URI with no tag) is ignored.
  }

  return HlsPlaylist(
    variants: variants,
    segments: segments,
    initSegmentUrl: initSegmentUrl,
    hasEndList: hasEndList,
    encrypted: encrypted,
  );
}

/// Highest-bandwidth variant, or null when the playlist has none.
HlsVariant? bestVariant(HlsPlaylist playlist) {
  if (playlist.variants.isEmpty) return null;
  var best = playlist.variants.first;
  for (final v in playlist.variants) {
    if (v.bandwidth > best.bandwidth) best = v;
  }
  return best;
}

int? _attributeInt(String tagLine, String name) {
  final value = _attributeString(tagLine, name);
  return value == null ? null : int.tryParse(value);
}

/// Read a `NAME=value` attribute from an HLS tag line. Values may be
/// quoted ("...") or bare (12345).
String? _attributeString(String tagLine, String name) {
  final match = RegExp('$name=("([^"]*)"|([^,]*))').firstMatch(tagLine);
  if (match == null) return null;
  return match.group(2) ?? match.group(3);
}
