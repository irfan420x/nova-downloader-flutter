import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_downloader/api/api_client.dart';
import 'package:nova_downloader/api/models.dart';

const _successJson = {
  'title': 'Test video',
  'thumbnail': 'https://example.com/thumb.jpg',
  'source': 'https://www.tiktok.com/@a/video/1',
  'qualities': [
    {
      'id': 'q1080',
      'label': '1080p',
      'ext': 'mp4',
      'url': 'https://cdn.example.com/v1080.mp4',
      'alternates': ['https://cdn2.example.com/v1080.mp4'],
      'headers': {
        'User-Agent': 'UA',
        'Referer': 'https://www.tiktok.com/',
        'Cookie': 'sid=1',
      },
      'size': 1000,
    },
    {
      'id': 'q720',
      'label': '720p',
      'ext': 'mp4',
      'url': 'https://cdn.example.com/v720.mp4',
      'alternates': [],
      'headers': {},
      'size': 500,
    },
  ],
  'debug': {'platform': 'tiktok', 'ms': 800},
};

void main() {
  group('ApiClient.resolve', () {
    test('parses a success shape', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url.path, '/tiktok');
        expect(jsonDecode(request.body)['url'],
            'https://www.tiktok.com/@a/video/1');
        return http.Response(jsonEncode(_successJson), 200);
      });
      final api = ApiClient(client: client);
      final result = await api.resolve(
        'tiktok',
        'https://www.tiktok.com/@a/video/1',
      );
      expect(calls, 1);
      expect(result.title, 'Test video');
      expect(result.qualities.length, 2);
      expect(result.qualities.first.headers['Cookie'], 'sid=1');
      expect(result.qualities.first.candidateUrls.length, 2);
      api.close();
    });

    test('maps API error codes honestly', () async {
      Future<void> check(int status, String code, String message) async {
        final client = MockClient((_) async => http.Response(
              jsonEncode({
                'error': {'code': code, 'message': message},
              }),
              status,
            ));
        final api = ApiClient(client: client);
        try {
          await api.resolve('youtube', 'https://youtube.com/watch?v=x');
          fail('should throw');
        } on ApiException catch (e) {
          expect(e.code, code);
          expect(e.message, message);
        }
        api.close();
      }

      await check(400, 'UNSUPPORTED', 'This is not a youtube URL.');
      await check(404, 'NOT_FOUND', 'Video not found.');
      await check(502, 'BLOCKED', 'Host blocked the request.');
      await check(502, 'UPSTREAM_ERROR', 'Upstream failed.');
    });

    test('retries once after a timeout, then succeeds', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        if (calls == 1) throw TimeoutException('simulated cold start');
        return http.Response(jsonEncode(_successJson), 200);
      });
      final api = ApiClient(client: client);
      final result = await api.resolve(
        'tiktok',
        'https://www.tiktok.com/@a/video/1',
      );
      expect(calls, 2);
      expect(result.title, 'Test video');
      api.close();
    });

    test('throws TIMEOUT after two timeouts', () async {
      final client = MockClient((_) async {
        throw TimeoutException('slow');
      });
      final api = ApiClient(client: client);
      try {
        await api.resolve('tiktok', 'https://www.tiktok.com/@a/video/1');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.code, 'TIMEOUT');
      }
      api.close();
    });

    test('unsupported platform throws before any HTTP call', () async {
      var calls = 0;
      final client = MockClient((_) async {
        calls++;
        return http.Response('{}', 200);
      });
      final api = ApiClient(client: client);
      try {
        await api.resolve('instagram', 'https://www.instagram.com/p/abc/');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.code, 'UNSUPPORTED');
      }
      expect(calls, 0);
      api.close();
    });
  });

  group('ApiClient.checkHealth', () {
    test('true on {"ok": true}', () async {
      final client =
          MockClient((_) async => http.Response('{"ok":true}', 200));
      final api = ApiClient(client: client);
      expect(await api.checkHealth(), isTrue);
      api.close();
    });

    test('false on failure', () async {
      final client = MockClient((_) async => http.Response('nope', 500));
      final api = ApiClient(client: client);
      expect(await api.checkHealth(), isFalse);
      api.close();
    });
  });

  group('ApiClient.fetchEndpoints', () {
    test('uses the advertised list when the API returns JSON', () async {
      final client = MockClient((_) async => http.Response(
            jsonEncode({
              'ok': true,
              'endpoints': ['/youtube', '/tiktok', '/newthing'],
            }),
            200,
          ));
      final api = ApiClient(client: client);
      final endpoints = await api.fetchEndpoints();
      expect(endpoints, ['/youtube', '/tiktok', '/newthing']);
      api.close();
    });

    test('falls back to the known list on non-JSON', () async {
      final client = MockClient(
        (_) async => http.Response('// not json', 200),
      );
      final api = ApiClient(client: client);
      final endpoints = await api.fetchEndpoints();
      expect(endpoints, contains('/youtube'));
      expect(endpoints, contains('/hls'));
      api.close();
    });
  });
}
