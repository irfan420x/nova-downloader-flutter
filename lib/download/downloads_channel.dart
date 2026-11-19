// Platform channel to the Android host (MainActivity): MediaStore
// Downloads, open and share. On Android 10+ a direct Dart write to the
// public Downloads folder is blocked by scoped storage, so the finished
// temp file is handed to the host, which inserts it via MediaStore and
// returns the content:// URI. No file bytes cross the channel — only paths.
import 'package:flutter/services.dart';

class DownloadsChannel {
  static const MethodChannel _channel =
      MethodChannel('nova_downloader/files');

  /// Move [tempPath] into the public Downloads folder as [displayName].
  /// Returns the content:// URI (Android) or the destination path.
  static Future<String?> moveToDownloads(
    String tempPath,
    String displayName,
    String mimeType,
  ) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'moveToDownloads',
        {
          'tempPath': tempPath,
          'displayName': displayName,
          'mimeType': mimeType,
        },
      );
      return result;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Open a previously saved location (content:// URI or file path).
  static Future<bool> openFile(String location, String mimeType) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'openFile',
        {'location': location, 'mimeType': mimeType},
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Share a previously saved location via the system share sheet.
  static Future<bool> shareFile(String location, String mimeType) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'shareFile',
        {'location': location, 'mimeType': mimeType},
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// Delete a previously saved location (content:// URI or file path).
  static Future<bool> deleteFile(String location) async {
    try {
      final result = await _channel.invokeMethod<bool>(
        'deleteFile',
        {'location': location},
      );
      return result == true;
    } catch (_) {
      return false;
    }
  }

  /// App cache dir (Android: Context.cacheDir) from the host channel.
  /// Throws a clear [Exception] when the host returns nothing — the
  /// download path cannot run without a temp dir, and the failure must
  /// surface as a failed task, not a crash.
  static Future<String> getCacheDir() async {
    final result = await _channel.invokeMethod<String>('getCacheDir');
    if (result == null || result.isEmpty) {
      throw Exception(
        'Could not resolve the app cache directory '
        '(host channel returned nothing).',
      );
    }
    return result;
  }

  /// App files dir (Android: Context.filesDir) from the host channel.
  /// Throws a clear [Exception] when the host returns nothing.
  static Future<String> getFilesDir() async {
    final result = await _channel.invokeMethod<String>('getFilesDir');
    if (result == null || result.isEmpty) {
      throw Exception(
        'Could not resolve the app files directory '
        '(host channel returned nothing).',
      );
    }
    return result;
  }

  /// Register the handler for links shared into the app from other apps
  /// (ACTION_SEND / text/plain — MainActivity forwards Intent.EXTRA_TEXT
  /// as the 'sharedLink' method call). Call once at startup.
  static void setSharedLinkHandler(void Function(String link) onLink) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedLink') {
        final text = call.arguments as String?;
        if (text != null && text.trim().isNotEmpty) onLink(text.trim());
      }
    });
  }
}
