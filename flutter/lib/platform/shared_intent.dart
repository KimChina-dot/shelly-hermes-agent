import 'dart:async';

import 'package:receive_sharing_intent/receive_sharing_intent.dart' as rsi;

/// Text shared into Shelly from other apps via the system share sheet
/// (ACTION_SEND text/*). Injectable so widget tests can simulate intents
/// without the platform channel.
Stream<String> Function() sharedTextStream = _defaultSharedTextStream;

Future<String?> Function() initialSharedText = _defaultInitialSharedText;

void resetSharedIntent() {
  sharedTextStream = _defaultSharedTextStream;
  initialSharedText = _defaultInitialSharedText;
}

Stream<String> _defaultSharedTextStream() {
  return rsi.ReceiveSharingIntent.instance.getMediaStream().expand(
        (media) => [
          for (final item in media)
            if (item.type == rsi.SharedMediaType.text &&
                item.path.trim().isNotEmpty)
              item.path,
        ],
      );
}

Future<String?> _defaultInitialSharedText() async {
  try {
    final media = await rsi.ReceiveSharingIntent.instance.getInitialMedia();
    for (final item in media) {
      if (item.type == rsi.SharedMediaType.text &&
          item.path.trim().isNotEmpty) {
        return item.path;
      }
    }
  } catch (_) {
    // Platform channel unavailable (e.g. desktop/web dev harness).
  }
  return null;
}
