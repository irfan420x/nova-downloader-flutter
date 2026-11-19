// Platform detection / routing for the NOVA Downloader API.
//
// Routing table copied from the API's lib/detect.js
// (~/workspace/nova-downloader-api-check/lib/detect.js) — do not guess.
// Platforms with no API endpoint yet return [UnsupportedPlatform] with an
// honest message; the app never fakes support for them.

/// Platforms the API has an endpoint for.
const Set<String> supportedPlatforms = {
  'youtube',
  'tiktok',
  'facebook',
  'x',
  'soundcloud',
  'direct',
  'hls',
};

/// Hosts per platform, copied from the API's PLATFORM_HOSTS.
const Map<String, List<String>> platformHosts = {
  'youtube': [
    'youtube.com',
    'www.youtube.com',
    'm.youtube.com',
    'youtu.be',
    'music.youtube.com',
    'www.youtube-nocookie.com',
    'youtube-nocookie.com',
  ],
  'tiktok': [
    'tiktok.com',
    'www.tiktok.com',
    'vm.tiktok.com',
    'vt.tiktok.com',
    'm.tiktok.com',
  ],
  'facebook': [
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'fb.watch',
    'fb.com',
    'www.fb.com',
  ],
  'x': [
    'x.com',
    'twitter.com',
    'www.x.com',
    'www.twitter.com',
    'mobile.twitter.com',
  ],
  'soundcloud': [
    'soundcloud.com',
    'www.soundcloud.com',
    'm.soundcloud.com',
    'snd.sc',
    'on.soundcloud.com',
  ],
};

/// Platforms with no API endpoint yet — honest "not supported yet".
const Map<String, String> unsupportedPlatforms = {
  'instagram':
      'Instagram is not supported yet — the API has no Instagram endpoint. '
      'Private and login-only posts can never be downloaded.',
  'pinterest':
      'Pinterest is not supported yet — the API has no Pinterest endpoint.',
  'twitch':
      'Twitch is not supported yet — the API has no Twitch endpoint.',
  'reddit':
      'Reddit is not supported yet — the API has no Reddit endpoint.',
  'vimeo':
      'Vimeo is not supported yet — the API has no Vimeo endpoint.',
  'dailymotion':
      'Dailymotion is not supported yet — the API has no Dailymotion endpoint.',
};

const Map<String, List<String>> unsupportedHosts = {
  'instagram': ['instagram.com', 'www.instagram.com'],
  'pinterest': ['pinterest.com', 'www.pinterest.com', 'pin.it'],
  'twitch': ['twitch.tv', 'www.twitch.tv', 'clips.twitch.tv'],
  'reddit': ['reddit.com', 'www.reddit.com', 'old.reddit.com'],
  'vimeo': ['vimeo.com', 'www.vimeo.com', 'player.vimeo.com'],
  'dailymotion': ['dailymotion.com', 'www.dailymotion.com', 'dai.ly'],
};

bool _hostMatches(String host, List<String> allowed) {
  return allowed.any((a) => host == a || host.endsWith('.$a'));
}

/// Detect the platform for [url].
///
/// Returns a supported platform id ('youtube', 'tiktok', 'facebook', 'x',
/// 'soundcloud', 'direct', 'hls'), or the key of an unsupported platform,
/// or null when the URL is not a valid http(s) URL at all.
String? detectPlatform(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
    return null;
  }
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return null;
  for (final entry in platformHosts.entries) {
    if (_hostMatches(host, entry.value)) return entry.key;
  }
  for (final entry in unsupportedHosts.entries) {
    if (_hostMatches(host, entry.value)) return entry.key;
  }
  // HLS only when the URL's PATH ends in .m3u8 — a query string that
  // merely mentions ".m3u8" must not route here (audit F-7).
  if (uri.path.toLowerCase().endsWith('.m3u8')) return 'hls';
  return 'direct';
}

/// Display name for a platform id.
String platformDisplayName(String platform) {
  switch (platform) {
    case 'youtube':
      return 'YouTube';
    case 'tiktok':
      return 'TikTok';
    case 'facebook':
      return 'Facebook';
    case 'x':
      return 'X';
    case 'soundcloud':
      return 'SoundCloud';
    case 'direct':
      return 'Direct file';
    case 'hls':
      return 'HLS stream';
    case 'instagram':
      return 'Instagram';
    case 'pinterest':
      return 'Pinterest';
    case 'twitch':
      return 'Twitch';
    case 'reddit':
      return 'Reddit';
    case 'vimeo':
      return 'Vimeo';
    case 'dailymotion':
      return 'Dailymotion';
    default:
      return platform;
  }
}

/// Endpoint path for a supported platform ("/youtube", "/tiktok", ...).
String endpointFor(String platform) => '/$platform';
