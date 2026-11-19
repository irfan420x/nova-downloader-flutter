import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nova_downloader/download/downloads_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('nova_downloader/files');
  var fakeResult = '/fake/cache';
  var failWithNull = false;

  setUp(() {
    fakeResult = '/fake/cache';
    failWithNull = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getCacheDir' || call.method == 'getFilesDir') {
        return failWithNull ? null : fakeResult;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('getCacheDir returns the host cache path', () async {
    fakeResult = '/data/data/com.nova.downloader/cache';
    expect(
      await DownloadsChannel.getCacheDir(),
      '/data/data/com.nova.downloader/cache',
    );
  });

  test('getFilesDir returns the host files path', () async {
    fakeResult = '/data/data/com.nova.downloader/files';
    expect(
      await DownloadsChannel.getFilesDir(),
      '/data/data/com.nova.downloader/files',
    );
  });

  test('getCacheDir throws a clear error when the host returns null',
      () async {
    failWithNull = true;
    await expectLater(
      DownloadsChannel.getCacheDir(),
      throwsA(isA<Exception>()),
    );
  });

  test('getFilesDir throws a clear error when the host returns null',
      () async {
    failWithNull = true;
    await expectLater(
      DownloadsChannel.getFilesDir(),
      throwsA(isA<Exception>()),
    );
  });
}
