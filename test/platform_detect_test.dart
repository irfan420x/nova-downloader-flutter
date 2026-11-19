import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/api/platform_detect.dart';

void main() {
  group('detectPlatform', () {
    test('named platforms', () {
      expect(detectPlatform('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
          'youtube');
      expect(detectPlatform('https://youtu.be/dQw4w9WgXcQ'), 'youtube');
      expect(detectPlatform('https://music.youtube.com/watch?v=x'), 'youtube');
      expect(detectPlatform('https://www.tiktok.com/@zachking/video/1'),
          'tiktok');
      expect(detectPlatform('https://vm.tiktok.com/abc'), 'tiktok');
      expect(
          detectPlatform('https://www.facebook.com/reel/1121767350734551'),
          'facebook');
      expect(detectPlatform('https://fb.watch/abc'), 'facebook');
      expect(detectPlatform('https://x.com/user/status/123'), 'x');
      expect(detectPlatform('https://mobile.twitter.com/user/status/1'), 'x');
      expect(detectPlatform('https://soundcloud.com/artist/track'),
          'soundcloud');
      expect(detectPlatform('https://snd.sc/abc'), 'soundcloud');
    });

    test('.m3u8 goes to hls', () {
      expect(
        detectPlatform('https://example.com/stream/master.m3u8'),
        'hls',
      );
    });

    test('anything else http(s) goes to direct', () {
      expect(
        detectPlatform('https://example.com/file.zip'),
        'direct',
      );
      expect(
        detectPlatform('https://raw.githubusercontent.com/x/y/main/f.txt'),
        'direct',
      );
    });

    test('unsupported platforms are named honestly', () {
      expect(detectPlatform('https://www.instagram.com/p/abc/'), 'instagram');
      expect(detectPlatform('https://www.twitch.tv/someone'), 'twitch');
      expect(detectPlatform('https://vimeo.com/123'), 'vimeo');
      expect(detectPlatform('https://www.dailymotion.com/video/x1'), 'dailymotion');
      expect(detectPlatform('https://www.reddit.com/r/x/comments/1/'), 'reddit');
      expect(detectPlatform('https://www.pinterest.com/pin/1/'), 'pinterest');
      for (final p in [
        'instagram',
        'twitch',
        'vimeo',
        'dailymotion',
        'reddit',
        'pinterest',
      ]) {
        expect(supportedPlatforms.contains(p), isFalse);
        expect(unsupportedPlatforms[p], isNotNull);
      }
    });

    test('invalid URLs return null', () {
      expect(detectPlatform('not a url'), isNull);
      expect(detectPlatform('ftp://example.com/file'), isNull);
      expect(detectPlatform(''), isNull);
    });
  });
}
