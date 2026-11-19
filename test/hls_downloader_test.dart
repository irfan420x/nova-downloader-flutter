import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/api/models.dart';
import 'package:nova_downloader/download/hls_downloader.dart';

void main() {
  group('parseHlsPlaylist', () {
    test('parses a media playlist with relative segment URLs', () {
      const body = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
#EXTINF:2.5,
seg2.ts
#EXT-X-ENDLIST
''';
      final playlist = parseHlsPlaylist(
        body,
        'https://cdn.example.com/hls/list.m3u8',
      );
      expect(playlist.isMedia, isTrue);
      expect(playlist.isMaster, isFalse);
      expect(playlist.hasEndList, isTrue);
      expect(playlist.encrypted, isFalse);
      expect(playlist.segments.length, 3);
      expect(
        playlist.segments[0].url,
        'https://cdn.example.com/hls/seg0.ts',
      );
      expect(playlist.segments[2].durationSeconds, 2.5);
      expect(playlist.totalDurationSeconds, 10.5);
      expect(playlist.isFmp4, isFalse);
    });

    test('parses a master playlist and bestVariant picks the highest', () {
      const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360
v360.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720
v720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=854x480
v480.m3u8
''';
      final playlist = parseHlsPlaylist(
        body,
        'https://cdn.example.com/hls/master.m3u8',
      );
      expect(playlist.isMaster, isTrue);
      expect(playlist.isMedia, isFalse);
      expect(playlist.variants.length, 3);
      expect(bestVariant(playlist)?.url,
          'https://cdn.example.com/hls/v720.m3u8');
      expect(bestVariant(playlist)?.bandwidth, 2000000);
    });

    test('absolute segment URLs are kept as-is', () {
      const body = '''
#EXTM3U
#EXTINF:6.0,
https://other.cdn.com/a/b.ts
#EXT-X-ENDLIST
''';
      final playlist = parseHlsPlaylist(
        body,
        'https://cdn.example.com/hls/list.m3u8',
      );
      expect(playlist.segments.single.url, 'https://other.cdn.com/a/b.ts');
    });

    test('detects an init segment and fragmented MP4', () {
      const body = '''
#EXTM3U
#EXT-X-MAP:URI="init.mp4"
#EXTINF:4.0,
seg0.m4s
#EXTINF:4.0,
seg1.m4s
#EXT-X-ENDLIST
''';
      final playlist = parseHlsPlaylist(
        body,
        'https://cdn.example.com/hls/fmp4.m3u8',
      );
      expect(playlist.initSegmentUrl,
          'https://cdn.example.com/hls/init.mp4');
      expect(playlist.isFmp4, isTrue);
      expect(playlist.segments.length, 2);
    });

    test('detects encryption and live playlists', () {
      const encrypted = '''
#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.com/key.bin"
#EXTINF:4.0,
seg0.ts
#EXT-X-ENDLIST
''';
      expect(parseHlsPlaylist(encrypted, 'https://x/l.m3u8').encrypted,
          isTrue);
      const live = '''
#EXTM3U
#EXTINF:4.0,
seg0.ts
#EXTINF:4.0,
seg1.ts
''';
      final livePlaylist = parseHlsPlaylist(live, 'https://x/l.m3u8');
      expect(livePlaylist.hasEndList, isFalse);
      expect(livePlaylist.isMedia, isTrue);
    });

    test('ignores stray lines and empty playlists', () {
      final empty = parseHlsPlaylist('#EXTM3U\n', 'https://x/e.m3u8');
      expect(empty.isMaster, isFalse);
      expect(empty.isMedia, isFalse);
      expect(bestVariant(empty), isNull);
    });
  });

  group('isHlsQuality', () {
    test('ext m3u8 counts, and only the URL path is consulted', () {
      const hls = Quality(
        id: 'q',
        label: '720p',
        ext: 'm3u8',
        url: 'https://cdn.example.com/v.m3u8',
      );
      expect(isHlsQuality(hls), isTrue);
      const byPath = Quality(
        id: 'q',
        label: '720p',
        ext: '',
        url: 'https://cdn.example.com/stream.m3u8?token=abc',
      );
      expect(isHlsQuality(byPath), isTrue);
      // ".m3u8" only in the query string must NOT route to HLS (F-7).
      const queryOnly = Quality(
        id: 'q',
        label: '720p',
        ext: 'mp4',
        url: 'https://cdn.example.com/v.mp4?format=.m3u8',
      );
      expect(isHlsQuality(queryOnly), isFalse);
      const plain = Quality(
        id: 'q',
        label: '720p',
        ext: 'mp4',
        url: 'https://cdn.example.com/v.mp4',
      );
      expect(isHlsQuality(plain), isFalse);
    });

    test('urlPathEndsWithM3u8 is path-only', () {
      expect(urlPathEndsWithM3u8('https://x/a.m3u8'), isTrue);
      expect(urlPathEndsWithM3u8('https://x/a.M3U8'), isTrue);
      expect(urlPathEndsWithM3u8('https://x/a.mp4?x=.m3u8'), isFalse);
      expect(urlPathEndsWithM3u8('not a url'), isFalse);
    });
  });
}
