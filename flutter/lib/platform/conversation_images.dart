import 'dart:convert';
import 'dart:io';

/// Persists attached conversation images as files so checkpoints hold short
/// file paths instead of hundreds of KB of base64 per image.
class ConversationImageStore {
  ConversationImageStore(this.root);

  /// Directory the image files live in (created on demand).
  final Directory root;

  /// Writes a `data:` URL to disk and returns the stored file path that
  /// replaces it inside checkpoints and message state. Throws on IO errors —
  /// callers degrade to keeping the data URL inline.
  Future<String> save(String dataUrl) async {
    final parsed = _parseDataUrl(dataUrl);
    if (parsed == null) {
      throw ArgumentError('not a base64 data URL');
    }
    final (mime, payload) = parsed;
    await root.create(recursive: true);
    final name =
        'img-${DateTime.now().microsecondsSinceEpoch}-${payload.length}.${_extensionFor(mime)}';
    final file = File('${root.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(base64Decode(payload), flush: true);
    return file.path;
  }

  static (String, String)? _parseDataUrl(String dataUrl) {
    final marker = 'base64,';
    if (!dataUrl.startsWith('data:image/') || !dataUrl.contains(marker)) {
      return null;
    }
    final mime = dataUrl.substring(5, dataUrl.indexOf(';'));
    final payload = dataUrl.substring(dataUrl.indexOf(marker) + marker.length);
    return (mime, payload);
  }

  static String _extensionFor(String mime) =>
      mime == 'image/png' ? 'png' : 'jpg';
}

/// Expands a stored image reference into a wire-ready URL. Data URLs pass
/// through; file paths are read back as data URLs. Returns null when a file
/// reference can no longer be read (deleted cache), letting the encoder drop
/// that image part instead of failing the request.
String? imageWireUrl(String reference) {
  if (reference.startsWith('data:')) return reference;
  try {
    final bytes = File(reference).readAsBytesSync();
    final mime = reference.toLowerCase().endsWith('.png')
        ? 'image/png'
        : 'image/jpeg';
    return 'data:$mime;base64,${base64Encode(bytes)}';
  } catch (_) {
    return null;
  }
}
