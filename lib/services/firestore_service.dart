import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:flutter/material.dart' show Color;
import 'package:inkspacex/models/reading_progress_model.dart';
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/user_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';

class FeedPage {
  final List<FeedItemModel> items;
  final DocumentSnapshot? lastDoc;
  const FeedPage({required this.items, this.lastDoc});
}

/// Firestore structure (optimized for reads):
///
/// users/{userId}
///   - Single document: profile + preferences + likes (embedded for 1 read)
///   - id, email, name, photoUrl, createdAt, updatedAt
///   - onboardingData: { preferredGenres, preferredWritingTypes, interests }
///   - likes: string[] (article IDs)
///   - readingList: string[]
///
/// feed_items/{feedItemId}
///   - title, author, authorId, description, imageUrl
///   - genres: string[] (for array-contains-any queries)
///   - writingTypes: string[]
///   - tags: string[]
///   - createdAt, likesCount
///
/// users/{userId}/writings/{writingId}
///   - title, author, description, coverImagePath, status, writingType, subtype
///   - createdAt, updatedAt, sectionIds: string[]
///
/// users/{userId}/writings/{writingId}/sections/{sectionId}
///   - title, sectionColor (int), content (Quill Delta JSON)
///   - updatedAt
///
/// Indexes needed (Firestore will prompt): genres ASC, createdAt DESC
class FirestoreService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static const String _users = 'users';
  static const String _feedItems = 'feed_items';
  static const String _comments = 'comments';
  static const String _writings = 'writings';
  static const String _sections = 'sections';

  // =========================================================================
  // USER CRUD (optimized: single document read/write)
  // =========================================================================

  /// Create or overwrite user profile. Use batched write if updating multiple.
  Future<void> setUser(User user) async {
    await _firestore.doc('$_users/${user.id}').set({
      ...user.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  /// Single read for full user data (profile + preferences + likes).
  Future<User?> getUser(String userId) async {
    final doc = await _firestore.doc('$_users/$userId').get();
    if (!doc.exists || doc.data() == null) return null;
    final data = _convertTimestamps(doc.data()!);
    return User.fromJson({...data, 'id': doc.id});
  }

  Map<String, dynamic> _convertTimestamps(Map<String, dynamic> data) {
    final result = Map<String, dynamic>.from(data);
    for (final k in result.keys.toList()) {
      final v = result[k];
      if (v is Timestamp) result[k] = v.toDate().toIso8601String();
    }
    return result;
  }

  Map<String, dynamic> _convertFeedItemTimestamps(Map<String, dynamic> data) {
    final result = Map<String, dynamic>.from(data);
    if (result['createdAt'] is Timestamp) {
      result['createdAt'] = (result['createdAt'] as Timestamp)
          .toDate()
          .toIso8601String();
    }
    return result;
  }

  /// Optimized: update only changed fields (reduces write cost).
  Future<void> updateUserPreferences(
    String userId,
    UserPreferences prefs,
  ) async {
    await _firestore.doc('$_users/$userId').update({
      'onboardingData': prefs.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Mark onboarding complete and save preferences.
  Future<void> completeOnboarding(String userId, UserPreferences prefs) async {
    await _firestore.doc('$_users/$userId').update({
      'onboardingComplete': true,
      'onboardingData': prefs.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Publish a single section from a book as a feed post.
  Future<void> publishSection(
    WritingModel book,
    SectionModel section,
    User author,
  ) async {
    final docId = '${book.id}_${section.id}';
    final feedItem = FeedItemModel(
      id: docId,
      title: section.title,
      author: author.name,
      authorId: author.id,
      description: book.description,
      imageUrl: book.coverImagePath,
      genres: book.subtype.isNotEmpty ? [book.subtype] : [],
      writingTypes: [book.writingType.displayName],
      tags: [],
      createdAt: DateTime.now(),
      likesCount: 0,
      content: section.content,
      bookTitle: book.title,
      bookId: book.id,
    );

    await _firestore
        .collection(_feedItems)
        .doc(docId)
        .set(feedItem.toJson());
  }

  /// Add like - batch: update user.likes + feed_item.likesCount.
  Future<void> addLike(String userId, String feedItemId) async {
    final userRef = _firestore.doc('$_users/$userId');
    final itemRef = _firestore.doc('$_feedItems/$feedItemId');

    await _firestore.runTransaction((tx) async {
      final userDoc = await tx.get(userRef);
      if (!userDoc.exists) return;
      final likes = List<String>.from(userDoc.data()?['likes'] ?? []);
      if (likes.contains(feedItemId)) return;

      tx.update(userRef, {
        'likes': FieldValue.arrayUnion([feedItemId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(itemRef, {'likesCount': FieldValue.increment(1)});
    });
  }

  /// Remove like - batch update.
  Future<void> removeLike(String userId, String feedItemId) async {
    final userRef = _firestore.doc('$_users/$userId');
    final itemRef = _firestore.doc('$_feedItems/$feedItemId');

    await _firestore.runTransaction((tx) async {
      tx.update(userRef, {
        'likes': FieldValue.arrayRemove([feedItemId]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      tx.update(itemRef, {'likesCount': FieldValue.increment(-1)});
    });
  }

  /// Add to reading list.
  Future<void> addToReadingList(String userId, String feedItemId) async {
    await _firestore.doc('$_users/$userId').update({
      'readingList': FieldValue.arrayUnion([feedItemId]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // =========================================================================
  // COMMENTS (subcollection of feed_items)
  // =========================================================================

  Future<void> addComment(CommentModel comment) async {
    final batch = _firestore.batch();
    final commentRef = _firestore
        .collection(_feedItems)
        .doc(comment.feedItemId)
        .collection(_comments)
        .doc(comment.id);
    final feedRef = _firestore.collection(_feedItems).doc(comment.feedItemId);

    batch.set(commentRef, {
      ...comment.toJson(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    batch.update(feedRef, {'commentsCount': FieldValue.increment(1)});
    await batch.commit();
  }

  Future<void> deleteComment(String feedItemId, String commentId) async {
    final batch = _firestore.batch();
    final commentRef = _firestore
        .collection(_feedItems)
        .doc(feedItemId)
        .collection(_comments)
        .doc(commentId);
    final feedRef = _firestore.collection(_feedItems).doc(feedItemId);

    batch.delete(commentRef);
    batch.update(feedRef, {'commentsCount': FieldValue.increment(-1)});
    await batch.commit();
  }

  Future<List<CommentModel>> getComments(
    String feedItemId, {
    int limit = 50,
  }) async {
    final snap = await _firestore
        .collection(_feedItems)
        .doc(feedItemId)
        .collection(_comments)
        .orderBy('createdAt', descending: false)
        .limit(limit)
        .get();
    return snap.docs.map((d) {
      final data = _convertTimestamps(d.data());
      return CommentModel.fromJson({...data, 'id': d.id});
    }).toList();
  }

  Stream<List<CommentModel>> getCommentsStream(String feedItemId) {
    return _firestore
        .collection(_feedItems)
        .doc(feedItemId)
        .collection(_comments)
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs.map((d) {
              final data = _convertTimestamps(d.data());
              return CommentModel.fromJson({...data, 'id': d.id});
            }).toList());
  }

  // =========================================================================
  // FEED ITEMS (optimized queries)
  // =========================================================================

  /// Personalized feed: query by user preferences. Uses array-contains-any
  /// (max 10 values). For more genres, split into multiple queries and merge.
  Stream<List<FeedItemModel>> getPersonalizedFeedStream(
    UserPreferences preferences, {
    int limit = 20,
  }) {
    final genres = preferences.preferredGenres;
    final writingTypes = preferences.preferredWritingTypes;

    // If no preferences, return trending (by likesCount + createdAt).
    if (genres.isEmpty && writingTypes.isEmpty) {
      return _firestore
          .collection(_feedItems)
          .orderBy('likesCount', descending: true)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map(
            (snap) => snap.docs.map((d) {
              final converted = _convertFeedItemTimestamps(d.data());
              return FeedItemModel.fromJson({...converted, 'id': d.id});
            }).toList(),
          );
    }

    // Use first 10 genres for array-contains-any (Firestore limit).
    final queryGenres = genres.take(10).toList();
    if (queryGenres.isEmpty) {
      return _firestore
          .collection(_feedItems)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .snapshots()
          .map(
            (snap) => snap.docs.map((d) {
              final converted = _convertFeedItemTimestamps(d.data());
              return FeedItemModel.fromJson({...converted, 'id': d.id});
            }).toList(),
          );
    }

    return _firestore
        .collection(_feedItems)
        .where('genres', arrayContainsAny: queryGenres)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(
          (snap) => snap.docs.map((d) {
            final converted = _convertFeedItemTimestamps(d.data());
            return FeedItemModel.fromJson({...converted, 'id': d.id});
          }).toList(),
        );
  }

  /// Recommendation engine: merges personalized + trending + recent,
  /// deduplicates, excludes the current user's own posts, then ranks
  /// by a composite score. Supports cursor-based pagination.
  Future<FeedPage> getPersonalizedFeed(
    UserPreferences preferences, {
    int pageSize = 10,
    DocumentSnapshot? lastDocument,
    String? currentUserId,
  }) async {
    final genres = preferences.preferredGenres.take(10).toList();
    final writingTypes = preferences.preferredWritingTypes.take(10).toList();
    final seen = <String>{};
    final all = <FeedItemModel>[];
    DocumentSnapshot? lastDoc;

    List<FeedItemModel> parse(QuerySnapshot<Map<String, dynamic>> snap) {
      return snap.docs.map((d) {
        final converted = _convertFeedItemTimestamps(d.data());
        return FeedItemModel.fromJson({...converted, 'id': d.id});
      }).toList();
    }

    Query<Map<String, dynamic>> _applyPagination(
      Query<Map<String, dynamic>> query,
    ) {
      var q = query.limit(pageSize);
      if (lastDocument != null) q = q.startAfterDocument(lastDocument);
      return q;
    }

    // 1. Fetch by preferred genres
    if (genres.isNotEmpty) {
      final snap = await _applyPagination(
        _firestore
            .collection(_feedItems)
            .where('genres', arrayContainsAny: genres)
            .orderBy('createdAt', descending: true),
      ).get();
      if (snap.docs.isNotEmpty) lastDoc = snap.docs.last;
      for (final item in parse(snap)) {
        if (seen.add(item.id)) all.add(item);
      }
    }

    // 2. Fetch by preferred writing types
    if (writingTypes.isNotEmpty) {
      final snap = await _applyPagination(
        _firestore
            .collection(_feedItems)
            .where('writingTypes', arrayContainsAny: writingTypes)
            .orderBy('createdAt', descending: true),
      ).get();
      if (snap.docs.isNotEmpty) lastDoc = snap.docs.last;
      for (final item in parse(snap)) {
        if (seen.add(item.id)) all.add(item);
      }
    }

    // 3. Trending (by engagement: likes + comments)
    final trendingSnap = await _applyPagination(
      _firestore
          .collection(_feedItems)
          .orderBy('likesCount', descending: true),
    ).get();
    if (trendingSnap.docs.isNotEmpty) lastDoc = trendingSnap.docs.last;
    for (final item in parse(trendingSnap)) {
      if (seen.add(item.id)) all.add(item);
    }

    // 4. Recent posts (catch new content regardless of genre)
    final recentSnap = await _applyPagination(
      _firestore
          .collection(_feedItems)
          .orderBy('createdAt', descending: true),
    ).get();
    if (recentSnap.docs.isNotEmpty) lastDoc = recentSnap.docs.last;
    for (final item in parse(recentSnap)) {
      if (seen.add(item.id)) all.add(item);
    }

    // 5. Exclude current user's own posts
    if (currentUserId != null) {
      all.removeWhere((item) => item.authorId == currentUserId);
    }

    // 6. Score and rank
    final now = DateTime.now();
    final genreSet = genres.map((g) => g.toLowerCase()).toSet();
    final typeSet = writingTypes.map((t) => t.toLowerCase()).toSet();

    all.sort((a, b) {
      final scoreA = _scoreItem(a, now, genreSet, typeSet);
      final scoreB = _scoreItem(b, now, genreSet, typeSet);
      return scoreB.compareTo(scoreA);
    });

    return FeedPage(items: all, lastDoc: lastDoc);
  }

  /// Composite score: preference match + engagement + freshness.
  double _scoreItem(
    FeedItemModel item,
    DateTime now,
    Set<String> preferredGenres,
    Set<String> preferredTypes,
  ) {
    double score = 0;

    // Genre match bonus (+3 per matching genre)
    for (final g in item.genres) {
      if (preferredGenres.contains(g.toLowerCase())) score += 3;
    }
    // Writing type match bonus (+2 per match)
    for (final t in item.writingTypes) {
      if (preferredTypes.contains(t.toLowerCase())) score += 2;
    }

    // Engagement score (logarithmic to avoid domination by viral posts)
    final engagement = item.likesCount + item.commentsCount * 2;
    if (engagement > 0) {
      score += _log2(engagement.toDouble() + 1) * 1.5;
    }

    // Freshness decay: full score within 24h, halves every 3 days
    final hoursOld = now.difference(item.createdAt).inHours;
    final freshness = 1.0 / (1.0 + hoursOld / 72.0);
    score += freshness * 5;

    return score;
  }

  static double _log2(double x) => x > 0 ? x.toStringAsFixed(0).length.toDouble() : 0;

  // =========================================================================
  // WRITINGS (optimized: metadata + sections subcollection)
  // =========================================================================

  /// Load all writings for user (fetches sections for each).
  /// For large projects, consider lazy-loading sections on open.
  Future<List<WritingModel>> getWritings(String userId) async {
    final snap = await _firestore
        .collection(_users)
        .doc(userId)
        .collection(_writings)
        .orderBy('updatedAt', descending: true)
        .get();

    final books = <WritingModel>[];
    for (final doc in snap.docs) {
      final book = await _writingDocToModel(userId, doc);
      if (book != null) books.add(book);
    }
    return books;
  }

  Future<WritingModel?> _writingDocToModel(
    String userId,
    DocumentSnapshot doc,
  ) async {
    final data = doc.data() as Map<String, dynamic>?;
    if (data == null) return null;
    final sectionIds = List<String>.from(data['sectionIds'] ?? []);
    final sections = <SectionModel>[];
    for (final sid in sectionIds) {
      final sDoc = await _firestore
          .doc('$_users/$userId/$_writings/${doc.id}/$_sections/$sid')
          .get();
      final sData = sDoc.data();
      if (sDoc.exists && sData != null) {
        sections.add(_sectionDocToModel(sData, sid));
      }
    }
    final book = WritingModel(
      id: doc.id,
      title: data['title'] ?? '',
      author: data['author'] ?? '',
      description: data['description'] ?? '',
      coverImagePath: data['coverImagePath'] ?? '',
      status: WritingStatus.values[data['status'] ?? 0],
      writingType: WritingType.values[data['writingType'] ?? 0],
      subtype: data['subtype'] ?? '',
      sections: sections,
    );
    final created = _parseTimestamp(data['createdAt']);
    if (created != null) book.createdAt = created;
    return book;
  }

  SectionModel _sectionDocToModel(Map<String, dynamic> data, String id) {
    final updatedAt = _parseTimestamp(data['updatedAt']) ?? DateTime.now();
    return SectionModel(
      id: id,
      title: data['title'] ?? '',
      content: data['content'] ?? '',
      sectionColor: Color(
        (data['sectionColor'] as num?)?.toInt() ?? 0xFF1982C4,
      ),
      createdAt: _parseTimestamp(data['createdAt']) ?? updatedAt,
      updatedAt: updatedAt,
      isSynced: true,
    );
  }

  DateTime? _parseTimestamp(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    return DateTime.tryParse(v.toString());
  }

  /// Create new writing: batch write metadata + all sections.
  Future<WritingModel> createWriting(String userId, WritingModel book) async {
    final ref = _firestore
        .collection(_users)
        .doc(userId)
        .collection(_writings)
        .doc(book.id);

    final batch = _firestore.batch();
    final now = Timestamp.now();
    final sectionIds = book.sections.map((s) => s.id).toList();

    batch.set(ref, {
      'title': book.title,
      'author': book.author,
      'description': book.description,
      'coverImagePath': book.coverImagePath,
      'status': book.status.index,
      'writingType': book.writingType.index,
      'subtype': book.subtype,
      'sectionIds': sectionIds,
      'createdAt': now,
      'updatedAt': now,
    });

    for (final s in book.sections) {
      batch.set(ref.collection(_sections).doc(s.id), {
        'title': s.title,
        'sectionColor': s.sectionColor.toARGB32(),
        'content': s.content,
        'updatedAt': now,
      });
    }
    await batch.commit();
    return book;
  }

  /// Optimized: update only the changed section content (most frequent write).
  /// Uses set+merge so it works even if the section doc doesn't exist yet.
  Future<void> updateSectionContent(
    String userId,
    String writingId,
    String sectionId,
    String content,
  ) async {
    await _firestore
        .doc('$_users/$userId/$_writings/$writingId/$_sections/$sectionId')
        .set({
          'content': content,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
    await _firestore.doc('$_users/$userId/$_writings/$writingId').update({
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Add new section: write section doc + update writing metadata.
  Future<void> addSection(
    String userId,
    String writingId,
    SectionModel section,
  ) async {
    final batch = _firestore.batch();
    final writingRef = _firestore.doc('$_users/$userId/$_writings/$writingId');
    final sectionRef = writingRef.collection(_sections).doc(section.id);

    batch.set(sectionRef, {
      'title': section.title,
      'sectionColor': section.sectionColor.toARGB32(),
      'content': section.content,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    batch.update(writingRef, {
      'sectionIds': FieldValue.arrayUnion([section.id]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Rename section: update only section doc.
  Future<void> renameSection(
    String userId,
    String writingId,
    String sectionId,
    String newTitle,
  ) async {
    await _firestore
        .doc('$_users/$userId/$_writings/$writingId/$_sections/$sectionId')
        .update({'title': newTitle, 'updatedAt': FieldValue.serverTimestamp()});
  }

  /// Delete section: delete section doc + remove from writing metadata.
  Future<void> deleteSection(
    String userId,
    String writingId,
    String sectionId,
  ) async {
    final batch = _firestore.batch();
    final writingRef = _firestore.doc('$_users/$userId/$_writings/$writingId');
    final sectionRef = writingRef.collection(_sections).doc(sectionId);

    batch.delete(sectionRef);
    batch.update(writingRef, {
      'sectionIds': FieldValue.arrayRemove([sectionId]),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  }

  /// Update book metadata (title, description, etc.).
  Future<void> updateWritingMetadata(
    String userId,
    String writingId, {
    String? title,
    String? description,
    String? coverImagePath,
  }) async {
    final updates = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (title != null) updates['title'] = title;
    if (description != null) updates['description'] = description;
    if (coverImagePath != null) updates['coverImagePath'] = coverImagePath;
    await _firestore
        .doc('$_users/$userId/$_writings/$writingId')
        .update(updates);
  }

  /// Delete entire writing.
  Future<void> deleteWriting(String userId, String writingId) async {
    final sectionsSnap = await _firestore
        .doc('$_users/$userId/$_writings/$writingId')
        .collection(_sections)
        .get();

    final batch = _firestore.batch();
    for (final doc in sectionsSnap.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(_firestore.doc('$_users/$userId/$_writings/$writingId'));
    await batch.commit();
  }

  // =========================================================================
  // READING PROGRESS
  // =========================================================================

  Future<void> updateReadingProgress(
    String userId,
    String feedItemId,
    double scrollPosition, {
    bool completed = false,
  }) async {
    await _firestore
        .collection(_users)
        .doc(userId)
        .collection('reading_progress')
        .doc(feedItemId)
        .set({
      'feedItemId': feedItemId,
      'scrollPosition': scrollPosition,
      'lastReadAt': DateTime.now().toIso8601String(),
      'completed': completed,
    }, SetOptions(merge: true));
  }

  Future<ReadingProgressModel?> getReadingProgress(
    String userId,
    String feedItemId,
  ) async {
    final doc = await _firestore
        .collection(_users)
        .doc(userId)
        .collection('reading_progress')
        .doc(feedItemId)
        .get();
    if (!doc.exists || doc.data() == null) return null;
    return ReadingProgressModel.fromJson(doc.data()!);
  }

  Future<List<ReadingProgressModel>> getAllReadingProgress(
    String userId,
  ) async {
    final snap = await _firestore
        .collection(_users)
        .doc(userId)
        .collection('reading_progress')
        .orderBy('lastReadAt', descending: true)
        .limit(50)
        .get();
    return snap.docs
        .map((d) => ReadingProgressModel.fromJson(d.data()))
        .toList();
  }
}
