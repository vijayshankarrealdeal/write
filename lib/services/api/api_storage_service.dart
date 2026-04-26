import 'dart:typed_data';

import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/services/api/api_client.dart';

/// Result of an upload — both the legacy primary URL (for backwards compat
/// with anything that still stores raw URL strings) and the rich metadata
/// (variants, blurhash, color, dimensions) the backend now emits.
class UploadResult {
  final String url;        // primary / largest variant URL
  final ImageMeta? meta;   // null only if backend is older than the pipeline

  const UploadResult({required this.url, this.meta});
}

/// Storage service backed by FastAPI + MinIO.
class ApiStorageService {
  final ApiClient _client;

  ApiStorageService(this._client);

  Future<UploadResult> uploadProfilePhoto(String userId, Uint8List bytes) async {
    final response = await _client.uploadFile('/api/upload/profile', bytes,
        filename: 'avatar.jpg');
    return _parse(response.data);
  }

  Future<UploadResult> uploadCoverImage(
    String userId,
    String bookId,
    Uint8List bytes,
  ) async {
    final response = await _client.uploadFile(
        '/api/upload/cover/$bookId', bytes,
        filename: '$bookId.jpg');
    return _parse(response.data);
  }

  Future<UploadResult> uploadEditorImage(String userId, Uint8List bytes) async {
    final response = await _client.uploadFile('/api/upload/editor', bytes,
        filename: '${DateTime.now().millisecondsSinceEpoch}.jpg');
    return _parse(response.data);
  }

  UploadResult _parse(Map<String, dynamic> data) {
    return UploadResult(
      url: (data['url'] as String?) ?? '',
      meta: ImageMeta.tryFromJson(data['meta']),
    );
  }
}
