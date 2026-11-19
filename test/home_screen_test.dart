import 'dart:convert';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nova_downloader/api/api_client.dart';
import 'package:nova_downloader/download/download_manager.dart';
import 'package:nova_downloader/theme/nebula.dart';
import 'package:nova_downloader/ui/home_screen.dart';

void main() {
  testWidgets('paste link -> resolve -> quality sheet shows all qualities',
      (tester) async {
    final client = MockClient((request) async {
      if (request.url.path == '/api/health') {
        return http.Response('{"ok":true}', 200);
      }
      return http.Response(
        jsonEncode({
          'title': 'Widget test video',
          'source': 'https://www.youtube.com/watch?v=abc',
          'qualities': [
            {
              'label': '720p',
              'ext': 'mp4',
              'url': 'https://cdn/a.mp4',
              'size': 1000,
            },
            {
              'label': '360p',
              'ext': 'mp4',
              'url': 'https://cdn/b.mp4',
              'size': 500,
            },
            {
              'label': 'Audio only',
              'ext': 'mp3',
              'url': 'https://cdn/c.mp3',
              'audioOnly': true,
            },
          ],
          'debug': {'platform': 'youtube', 'ms': 900},
        }),
        200,
      );
    });
    final api = ApiClient(client: client);
    // Sync temp-dir creation. ROOT CAUSE of the old timeout: awaiting
    // Directory.systemTemp.createTemp() inside a testWidgets body before
    // the first pump deadlocks — the I/O completion microtask sits in the
    // test's fake-async queue and nothing drains it until a pump runs.
    // (Proved by bisect: the test printed "test start" and "api created"
    // and then hung on createTemp; the sibling widget test, which never
    // awaited dart:io, passed.) Sync APIs complete inline and never wait
    // on the fake-async queue.
    final tmp = Directory.systemTemp.createTempSync('nova-widget-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final manager = DownloadManager(
      fileSaver: (tempPath, name, mime) async {
        final dest = File('${tmp.path}/$name');
        await File(tempPath).copy(dest.path);
        return dest.path;
      },
      tempDirOverride: () => tmp,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: nebulaTheme(),
        home: Scaffold(
          body: HomeScreen(
            api: api,
            downloads: manager,
            apiHealthy: true,
            onDownloadStarted: () {},
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byType(TextField),
      'https://www.youtube.com/watch?v=abc',
    );
    await tester.pump();
    expect(find.textContaining('Detected: YouTube'), findsOneWidget);

    await tester.tap(find.text('Find downloads'));
    // Bounded pumps only: pumpAndSettle() never settles here because the
    // resolving spinner animates while the (mock) resolve is in flight.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    // Quality sheet: title + all three qualities.
    expect(find.text('Widget test video'), findsOneWidget);
    expect(find.text('720p'), findsOneWidget);
    expect(find.text('360p'), findsOneWidget);
    expect(find.text('Audio only'), findsOneWidget);
    expect(find.textContaining('Audio only'), findsWidgets);

    // Tapping a quality enqueues a download in the manager. This asserts
    // the wiring only — the actual download is NOT awaited here: real
    // HttpClient/network I/O is mocked out by the widget-test binding
    // (all requests return 400, no network is made), and the download
    // engine itself is covered by download_manager_test.dart, which runs
    // as plain tests against a real loopback server. No pumps after the
    // tap and no status assertion, so the test ends while the task is
    // still queued/downloading, with no pending timers.
    await tester.tap(find.text('720p'));
    expect(manager.tasks.length, 1);
    expect(manager.tasks.first.quality.label, '720p');
    api.close();
  });

  testWidgets('unsupported platform shows an honest message',
      (tester) async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final api = ApiClient(client: client);
    final manager = DownloadManager(
      fileSaver: (a, b, c) async => null,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: nebulaTheme(),
        home: Scaffold(
          body: HomeScreen(
            api: api,
            downloads: manager,
            apiHealthy: true,
            onDownloadStarted: () {},
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byType(TextField),
      'https://www.instagram.com/p/abc123/',
    );
    await tester.pump();
    await tester.tap(find.text('Find downloads'));
    await tester.pump();
    // The exact API-style message (the page footer also mentions
    // "not supported yet", so match the full sentence).
    expect(
      find.textContaining('Instagram is not supported yet'),
      findsOneWidget,
    );
    expect(manager.tasks, isEmpty);
    api.close();
  });
}
