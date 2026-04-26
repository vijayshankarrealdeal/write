import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/writing_model.dart';

/// The slice of `ApiDataService` the outbox drainer actually depends on.
///
/// Extracted so tests can substitute a fake without standing up the full
/// HTTP stack. `ApiDataService` declares `implements SyncDispatcher` so
/// production code passes the concrete service unchanged.
abstract class SyncDispatcher {
  Future<WritingModel> createWriting(String userId, WritingModel book);
  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
    ImageMeta? coverImageMeta,
  });
  Future<void> deleteWriting(String userId, String writingId);
  Future<void> addSection(
      String userId, String writingId, SectionModel section);
  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content, {
    String canvasData = '',
  });
  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle,
  );
  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId,
  );
}
