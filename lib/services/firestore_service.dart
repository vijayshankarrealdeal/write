import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:flutter/material.dart' show Color;
import 'package:inkspacex/models/section_model.dart';
import 'package:inkspacex/models/user_model.dart';
import 'package:inkspacex/models/user_preferences_model.dart';
import 'package:inkspacex/models/writing_model.dart';

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

  /// Publish a writing to the public feed.
  Future<void> publishToFeed(WritingModel writing, User author) async {
    final feedItem = FeedItemModel(
      id: writing.id,
      title: writing.title,
      author: author.name,
      authorId: author.id,
      description: writing.description,
      imageUrl: writing.coverImagePath,
      genres: writing.subtype.isNotEmpty ? [writing.subtype] : [],
      writingTypes: [writing.writingType.displayName],
      tags: [],
      createdAt: DateTime.now(),
      likesCount: 0,
    );

    await _firestore
        .collection(_feedItems)
        .doc(feedItem.id) // Use writing ID as feed item ID for easy updates
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

  /// One-time fetch for initial load (no stream).
  Future<List<FeedItemModel>> getPersonalizedFeed(
    UserPreferences preferences, {
    int limit = 20,
  }) async {
    final genres = preferences.preferredGenres.take(10).toList();

    if (genres.isEmpty) {
      final snap = await _firestore
          .collection(_feedItems)
          .orderBy('likesCount', descending: true)
          .orderBy('createdAt', descending: true)
          .limit(limit)
          .get();
      return snap.docs.map((d) {
        final converted = _convertFeedItemTimestamps(d.data());
        return FeedItemModel.fromJson({...converted, 'id': d.id});
      }).toList();
    }

    final snap = await _firestore
        .collection(_feedItems)
        .where('genres', arrayContainsAny: genres)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    return snap.docs.map((d) {
      final data = d.data();
      final converted = _convertFeedItemTimestamps(data);
      return FeedItemModel.fromJson({...converted, 'id': d.id});
    }).toList();
  }

  /// Seed default feed items (run once when collection is empty).
  Future<void> seedDefaultFeedItems() async {
    final snap = await _firestore.collection(_feedItems).limit(1).get();
    if (snap.docs.isNotEmpty) return; // Already seeded
    final batch = _firestore.batch();
    final items = _defaultFeedItems();
    for (final item in items) {
      final ref = _firestore.collection(_feedItems).doc(item.id);
      final json = item.toJson();
      json['createdAt'] = Timestamp.fromDate(item.createdAt);
      batch.set(ref, json);
    }
    await batch.commit();
  }

  static List<FeedItemModel> _defaultFeedItems() {
    final now = DateTime.now();
    return [
      FeedItemModel(
        id: 'paper-faces',
        title: "Paper Faces, Real Skin: On the Mask We Choose",
        author: "Nina Abraham",
        authorId: 'demo-author-1',
        description:
            "You are not your reflection. You are not your bio. You're not even your favourite book. This essay explores the absurdity of identity in a world where we curate ourselves more than we understand ourselves.",
        imageUrl:
            "https://images.unsplash.com/photo-1544502062-f82887f03d1c?fit=crop&w=400&q=80",
        genres: ['creative', 'personal', 'essay'],
        writingTypes: ['creative', 'personal'],
        tags: ['identity', 'reflection'],
        createdAt: now,
        likesCount: 42,
      ),
      FeedItemModel(
        id: 'soft-apocalypse',
        title: "Soft Apocalypse: How We Fall Apart Quietly",
        author: "Rayan V",
        authorId: 'demo-author-2',
        description:
            "Some days, your thoughts feel like bubblegum caught in a microwave. This isn't a piece about breakdowns—it's about breakthroughs that look like breakdowns.",
        imageUrl:
            "https://images.unsplash.com/photo-1618005182384-a83a8bd57fbe?fit=crop&w=400&q=80",
        genres: ['creative', 'personal', 'poetry'],
        writingTypes: ['creative', 'personal'],
        tags: ['mental health', 'growth'],
        createdAt: now,
        likesCount: 38,
      ),
      FeedItemModel(
        id: 'gallery-1',
        title: "Morning Pages",
        author: "Anonymous",
        authorId: 'demo-author-3',
        description: "A journey through journaling and self-discovery.",
        imageUrl:
            "https://images.unsplash.com/photo-1533738363-b7f9aef128ce?fit=crop&w=400&q=80",
        genres: ['personal', 'journal'],
        writingTypes: ['personal'],
        tags: ['journaling'],
        createdAt: now,
        likesCount: 15,
      ),
      FeedItemModel(
        id: 'gallery-2',
        title: "Digital Detox",
        author: "Anonymous",
        authorId: 'demo-author-4',
        description: "Finding peace in a connected world.",
        imageUrl:
            "https://images.unsplash.com/photo-1507608616759-54f48f0af0ee?fit=crop&w=400&q=80",
        genres: ['digitalContent', 'personal'],
        writingTypes: ['digitalContent'],
        tags: ['wellness'],
        createdAt: now,
        likesCount: 22,
      ),
      FeedItemModel(
        id: 'gallery-3',
        title: "Creative Block",
        author: "Anonymous",
        authorId: 'demo-author-5',
        description: "Breaking through when words won't come.",
        imageUrl:
            "https://images.unsplash.com/photo-1604076913837-52ab5629fba9?fit=crop&w=400&q=80",
        genres: ['creative', 'personal'],
        writingTypes: ['creative'],
        tags: ['creativity'],
        createdAt: now,
        likesCount: 31,
      ),
      FeedItemModel(
        id: 'gallery-4',
        title: "Storytelling",
        author: "Anonymous",
        authorId: 'demo-author-6',
        description: "The art of narrative in everyday life.",
        imageUrl:
            "https://images.unsplash.com/photo-1550684848-fac1c5b4e853?fit=crop&w=400&q=80",
        genres: ['creative', 'essay'],
        writingTypes: ['creative'],
        tags: ['narrative'],
        createdAt: now,
        likesCount: 19,
      ),
    ];
  }

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
  }) async {
    final updates = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };
    if (title != null) updates['title'] = title;
    if (description != null) updates['description'] = description;
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
}
