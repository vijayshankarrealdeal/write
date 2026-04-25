import 'dart:typed_data';
import 'package:inkspacex/services/api/api_client.dart';

/// Storage service backed by FastAPI + MinIO (replaces FirebaseStorageService).
class ApiStorageService {
  final ApiClient _client;

  ApiStorageService(this._client);

  Future<String> uploadProfilePhoto(String userId, Uint8List bytes) async {
    final response = await _client.uploadFile('/api/upload/profile', bytes,
        filename: 'avatar.jpg');
    return response.data['url'];
  }

  Future<String> uploadCoverImage(
    String userId,
    String bookId,
    Uint8List bytes,
  ) async {
    final response = await _client.uploadFile(
        '/api/upload/cover/$bookId', bytes,
        filename: '$bookId.jpg');
    return response.data['url'];
  }

  Future<String> uploadEditorImage(String userId, Uint8List bytes) async {
    final response = await _client.uploadFile('/api/upload/editor', bytes,
        filename: '${DateTime.now().millisecondsSinceEpoch}.jpg');
    return response.data['url'];
  }
}
