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
}
