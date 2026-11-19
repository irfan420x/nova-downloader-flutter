// HTTP client for the NOVA Downloader API.
//
// Base URL: https://nova-downloader-api.vercel.app
// Endpoints: POST {"url": ...} -> /tiktok /youtube /facebook /x /soundcloud
//   /direct /hls, plus GET /api/health -> {"ok": true} and GET / -> endpoint
//   list {"endpoints": ["/youtube", ...]}.
// The API only resolves (returns stream URLs + per-quality headers); it
// never proxies bytes. The app downloads bytes directly from CDNs.
//
// Client rules (from API-CHECK-2026-11-19.md):
//  - Cold start can be ~49s: 90s timeout + ONE retry on timeout/network
//    failure, with a visible "Resolving…" state in the UI.
//  - Error shape {error:{code, message}} is surfaced honestly, never
//    replaced with a generic "failed".
//  - Routing consults GET / (endpoint list) so future API endpoints light
//    up without an app update; the known host table in platform_detect.dart
//    is the fallback when the list cannot be fetched.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'platform_detect.dart';

class ApiClient {
  static const String defaultBaseUrl =
      'https://nova-downloader-api.vercel.app';

  /// 90s: the API cold start was measured at ~49s.
  static const Duration resolveTimeout = Duration(seconds: 90);
  static const Duration healthTimeout = Duration(seconds: 15);

  final String baseUrl;
  final http.Client _client;

  /// Endpoints the API currently advertises (from GET /), or null when the
  /// list has not been fetched / could not be parsed.
  List<String>? advertisedEndpoints;

  ApiClient({this.baseUrl = defaultBaseUrl, http.Client? client})
      : _client = client ?? http.Client();

  void close() => _client.close();

  /// GET /api/health -> true when the API answers {"ok": true}.
  Future<bool> checkHealth() async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/api/health'))
          .timeout(healthTimeout);
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map && body['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  /// GET / -> the API's endpoint list. Falls back to the known list when
  /// the response is not JSON (e.g. the deployed root serves something
  /// else) or the request fails.
  Future<List<String>> fetchEndpoints() async {
    const known = [
      '/youtube',
      '/tiktok',
      '/facebook',
      '/x',
      '/soundcloud',
      '/direct',
      '/hls',
    ];
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl/'))
          .timeout(healthTimeout);
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is Map && body['endpoints'] is List) {
          final list = (body['endpoints'] as List)
              .map((e) => e.toString())
              .where((e) => e.startsWith('/'))
              .toList();
          if (list.isNotEmpty) {
            advertisedEndpoints = list;
            return list;
          }
        }
      }
    } catch (_) {
      // Fall through to the known list.
    }
    advertisedEndpoints = known;
    return known;
  }

  /// Resolve [url] for [platform] (must be a supported platform id).
  /// Retries ONCE on timeout / network failure.
  Future<ResolveResult> resolve(String platform, String url) async {
    if (!supportedPlatforms.contains(platform)) {
      throw ApiException(
        'UNSUPPORTED',
        unsupportedPlatforms[platform] ??
            '$platform is not supported by the API yet.',
        platform: platform,
      );
    }
    final uri = Uri.parse('$baseUrl${endpointFor(platform)}');
    http.Response response;
    try {
      response = await _postWithRetry(uri, url);
    } on TimeoutException {
      throw const ApiException(
        'TIMEOUT',
        'The API took too long to respond (cold start can take ~50s). '
        'Check your connection and try again.',
      );
    } on SocketException {
      throw const ApiException(
        'NO_NETWORK',
        'No network connection — check your internet and try again.',
      );
    } on http.ClientException catch (e) {
      throw ApiException('NETWORK_ERROR', 'Network error: ${e.message}');
    }
    return _parseResolveResponse(response, platform);
  }

  Future<http.Response> _postWithRetry(Uri uri, String url) async {
    try {
      return await _postOnce(uri, url);
    } on TimeoutException {
      // One retry — the first call may have hit a cold start.
      return await _postOnce(uri, url);
    } on SocketException {
      // One retry on a transient network failure.
      return await _postOnce(uri, url);
    }
  }

  Future<http.Response> _postOnce(Uri uri, String url) {
    return _client
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'url': url}),
        )
        .timeout(resolveTimeout);
  }

  ResolveResult _parseResolveResponse(
    http.Response response,
    String platform,
  ) {
    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
      if (decoded is Map) body = Map<String, dynamic>.from(decoded);
    } catch (_) {
      body = null;
    }
    if (response.statusCode == 200 && body != null) {
      if (body['error'] is Map) {
        final err = body['error'] as Map;
        throw ApiException(
          (err['code'] ?? 'UPSTREAM_ERROR').toString(),
          (err['message'] ?? 'The API returned an error.').toString(),
          platform: platform,
        );
      }
      return ResolveResult.fromJson(body);
    }
    if (body != null && body['error'] is Map) {
      final err = body['error'] as Map;
      throw ApiException(
        (err['code'] ?? 'UPSTREAM_ERROR').toString(),
        (err['message'] ?? 'The API returned an error.').toString(),
        platform: platform,
      );
    }
    switch (response.statusCode) {
      case 400:
        throw ApiException(
          'UNSUPPORTED',
          'This link is not supported by the /$platform endpoint.',
          platform: platform,
        );
      case 404:
        throw const ApiException(
          'NOT_FOUND',
          'This video was not found — it may be private or deleted.',
        );
      case 502:
        throw const ApiException(
          'BLOCKED',
          'The video host blocked the request. Try again later.',
        );
      default:
        throw ApiException(
          'UPSTREAM_ERROR',
          'The API returned HTTP ${response.statusCode}. Try again later.',
          platform: platform,
        );
    }
  }
}
