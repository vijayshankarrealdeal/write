import 'package:inkspacex/models/image_meta.dart';
import 'package:inkspacex/models/user_preferences_model.dart';

/// Well-known keys allowed in [User.socialLinks]. Mirrored on the
/// backend (`SOCIAL_LINK_KEYS` in `app/schemas/user.py`); anything
/// outside this set is dropped server-side on write, so the client
/// shouldn't bother sending it.
const List<String> kSocialLinkKeys = <String>[
  'website',
  'twitter',
  'instagram',
  'linkedin',
  'goodreads',
];

Map<String, String> _socialLinksFromJson(dynamic raw) {
  if (raw is! Map) return const {};
  final out = <String, String>{};
  for (final key in kSocialLinkKeys) {
    final v = raw[key];
    if (v is String && v.trim().isNotEmpty) {
      out[key] = v.trim();
    }
  }
  return out;
}

class User {
  final String id;
  final String email;
  final String name;
  final String? photoUrl;
  final ImageMeta? photoMeta;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool onboardingComplete;
  final UserPreferences preferences;
  /// Free-text author bio shown on the public profile page. Server
  /// caps the persisted value at ~1000 chars and trims whitespace.
  final String? bio;
  /// Flat map of platform → URL/handle, restricted to
  /// [kSocialLinkKeys]. Empty values are stripped server-side.
  final Map<String, String> socialLinks;
  final List<String> likes;
  final List<String> readingList;
  final List<String> savedPosts;
  final List<String> favoritePosts;
  final List<String> sectionBookmarks;

  User({
    required this.id,
    required this.email,
    required this.name,
    this.photoUrl,
    this.photoMeta,
    this.createdAt,
    this.updatedAt,
    this.onboardingComplete = false,
    UserPreferences? preferences,
    this.bio,
    Map<String, String>? socialLinks,
    List<String>? likes,
    List<String>? readingList,
    List<String>? savedPosts,
    List<String>? favoritePosts,
    List<String>? sectionBookmarks,
  })  : preferences = preferences ?? const UserPreferences(),
        socialLinks = socialLinks ?? const {},
        likes = likes ?? [],
        readingList = readingList ?? [],
        savedPosts = savedPosts ?? [],
        favoritePosts = favoritePosts ?? [],
        sectionBookmarks = sectionBookmarks ?? [];

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] ?? '',
      email: json['email'] ?? '',
      name: json['name'] ?? '',
      photoUrl: json['photoUrl'],
      photoMeta: ImageMeta.tryFromJson(json['photoMeta'] ?? json['photo_meta']),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString())
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'].toString())
          : null,
      onboardingComplete: json['onboardingComplete'] ?? true,
      preferences: UserPreferences.fromJson(
        (json['onboardingData'] ?? json['preferences']) as Map<String, dynamic>?,
      ),
      bio: json['bio'] as String?,
      socialLinks: _socialLinksFromJson(json['socialLinks'] ?? json['social_links']),
      likes: List<String>.from(json['likes'] ?? []),
      readingList: List<String>.from(json['readingList'] ?? []),
      savedPosts: List<String>.from(json['savedPosts'] ?? []),
      favoritePosts: List<String>.from(json['favoritePosts'] ?? []),
      sectionBookmarks: List<String>.from(json['sectionBookmarks'] ?? []),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'name': name,
        'photoUrl': photoUrl,
        'photoMeta': photoMeta?.toJson(),
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
        'onboardingComplete': onboardingComplete,
        'onboardingData': preferences.toJson(),
        'bio': bio,
        'socialLinks': socialLinks,
        'likes': likes,
        'readingList': readingList,
        'savedPosts': savedPosts,
        'favoritePosts': favoritePosts,
        'sectionBookmarks': sectionBookmarks,
      };

  User copyWith({
    String? id,
    String? email,
    String? name,
    String? photoUrl,
    ImageMeta? photoMeta,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? onboardingComplete,
    UserPreferences? preferences,
    String? bio,
    bool clearBio = false,
    Map<String, String>? socialLinks,
    List<String>? likes,
    List<String>? readingList,
    List<String>? savedPosts,
    List<String>? favoritePosts,
    List<String>? sectionBookmarks,
  }) =>
      User(
        id: id ?? this.id,
        email: email ?? this.email,
        name: name ?? this.name,
        photoUrl: photoUrl ?? this.photoUrl,
        photoMeta: photoMeta ?? this.photoMeta,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        onboardingComplete: onboardingComplete ?? this.onboardingComplete,
        preferences: preferences ?? this.preferences,
        bio: clearBio ? null : (bio ?? this.bio),
        socialLinks: socialLinks ?? this.socialLinks,
        likes: likes ?? this.likes,
        readingList: readingList ?? this.readingList,
        savedPosts: savedPosts ?? this.savedPosts,
        favoritePosts: favoritePosts ?? this.favoritePosts,
        sectionBookmarks: sectionBookmarks ?? this.sectionBookmarks,
      );
}
