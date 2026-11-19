import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/api/models.dart';

void main() {
  group('Quality.fromJson', () {
    test('parses all fields including headers and alternates', () {
      final q = Quality.fromJson({
        'id': 'q1080',
        'label': '1080p',
        'ext': 'mp4',
        'url': 'https://cdn.example.com/v1080.mp4',
        'alternates': [
          'https://cdn2.example.com/v1080.mp4',
          'https://cdn3.example.com/v1080.mp4',
        ],
        'headers': {
          'User-Agent': 'Mozilla/5.0',
          'Referer': 'https://www.tiktok.com/',
          'Cookie': 'sessionid=abc',
        },
        'size': 12345678,
        'videoOnly': false,
        'audioOnly': false,
      });
      expect(q.id, 'q1080');
      expect(q.label, '1080p');
      expect(q.ext, 'mp4');
      expect(q.candidateUrls.length, 3);
      expect(q.candidateUrls.first, 'https://cdn.example.com/v1080.mp4');
      expect(q.headers['Cookie'], 'sessionid=abc');
      expect(q.size, 12345678);
      expect(q.isCombined, isTrue);
      expect(q.kindLabel, 'Video + audio');
    });

    test('video-only and audio-only badges', () {
      final videoOnly = Quality.fromJson({
        'label': '720p',
        'url': 'https://x/v.mp4',
        'videoOnly': true,
      });
      expect(videoOnly.kindLabel, 'Video only — no audio');
      final audioOnly = Quality.fromJson({
        'label': 'Audio 160k',
        'url': 'https://x/a.mp3',
        'audioOnly': true,
      });
      expect(audioOnly.kindLabel, 'Audio only');
    });
  });

  group('ResolveResult.fromJson', () {
    test('dedupes SoundCloud-style duplicate labels by URL', () {
      final result = ResolveResult.fromJson({
        'title': 'Perfect',
        'source': 'https://soundcloud.com/a/perfect',
        'qualities': [
          {'label': 'aac 160k', 'url': 'https://cdn/a.mp3', 'ext': 'mp3'},
          {'label': 'aac 160k', 'url': 'https://cdn/a.mp3', 'ext': 'mp3'},
          {'label': 'aac 96k', 'url': 'https://cdn/b.mp3', 'ext': 'mp3'},
          {'label': 'aac 96k', 'url': 'https://cdn/b.mp3', 'ext': 'mp3'},
        ],
        'debug': {'platform': 'soundcloud', 'ms': 1200},
      });
      expect(result.qualities.length, 2);
      expect(
        result.qualities.map((q) => q.label).toList(),
        ['aac 160k', 'aac 96k'],
      );
      expect(result.platform, 'soundcloud');
      expect(result.resolveMs, 1200);
    });

    test('drops qualities with an empty url', () {
      final result = ResolveResult.fromJson({
        'title': 't',
        'source': 's',
        'qualities': [
          {'label': 'ok', 'url': 'https://cdn/a.mp4'},
          {'label': 'empty', 'url': ''},
        ],
      });
      expect(result.qualities.length, 1);
    });
  });
}
