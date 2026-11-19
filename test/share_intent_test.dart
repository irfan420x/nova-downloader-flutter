import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:nova_downloader/api/api_client.dart';
import 'package:nova_downloader/download/download_manager.dart';
import 'package:nova_downloader/download/downloads_channel.dart';
import 'package:nova_downloader/theme/nebula.dart';
import 'package:nova_downloader/ui/home_screen.dart';

void main() {
  test('DownloadsChannel forwards a host sharedLink call to the handler',
      () async {
    var received = '';
    DownloadsChannel.setSharedLinkHandler((link) => received = link);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      'nova_downloader/files',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('sharedLink', 'https://www.youtube.com/watch?v=abc'),
      ),
      (_) {},
    );

    expect(received, 'https://www.youtube.com/watch?v=abc');

    // Empty / blank shares are ignored.
    await messenger.handlePlatformMessage(
      'nova_downloader/files',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('sharedLink', '   '),
      ),
      (_) {},
    );
    expect(received, 'https://www.youtube.com/watch?v=abc');
  });

  testWidgets('a shared link prefills the link field and is detected',
      (tester) async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final api = ApiClient(client: client);
    final tmp = Directory.systemTemp.createTempSync('nova-share-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final manager = DownloadManager(
      fileSaver: (a, b, c) async => null,
      tempDirOverride: () => tmp,
    );
    final incoming = ValueNotifier<String?>(null);

    await tester.pumpWidget(
      MaterialApp(
        theme: nebulaTheme(),
        home: Scaffold(
          body: HomeScreen(
            api: api,
            downloads: manager,
            apiHealthy: true,
            incomingLink: incoming,
            onDownloadStarted: () {},
          ),
        ),
      ),
    );

    // No link yet: the field is empty.
    expect(find.text('https://www.tiktok.com/@a/video/1'), findsNothing);

    incoming.value = 'https://www.tiktok.com/@a/video/1';
    await tester.pump();

    expect(find.text('https://www.tiktok.com/@a/video/1'), findsOneWidget);
    expect(find.textContaining('Detected: TikTok'), findsOneWidget);
    // The notifier is consumed (cleared) after prefill.
    expect(incoming.value, isNull);
    api.close();
  });

  testWidgets('a link already waiting at startup is picked up', (tester) async {
    final client = MockClient((_) async => http.Response('{}', 200));
    final api = ApiClient(client: client);
    final tmp = Directory.systemTemp.createTempSync('nova-share-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final manager = DownloadManager(
      fileSaver: (a, b, c) async => null,
      tempDirOverride: () => tmp,
    );
    final incoming =
        ValueNotifier<String?>('https://www.youtube.com/watch?v=abc');

    await tester.pumpWidget(
      MaterialApp(
        theme: nebulaTheme(),
        home: Scaffold(
          body: HomeScreen(
            api: api,
            downloads: manager,
            apiHealthy: true,
            incomingLink: incoming,
            onDownloadStarted: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('https://www.youtube.com/watch?v=abc'), findsOneWidget);
    expect(find.textContaining('Detected: YouTube'), findsOneWidget);
    api.close();
  });
}
