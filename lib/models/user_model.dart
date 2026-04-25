import 'package:inkspacex/models/user_preferences_model.dart';

class User {
  final String id;
  final String email;
  final String name;
  final String? photoUrl;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final bool onboardingComplete;
  final UserPreferences preferences;
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
    this.createdAt,
    this.updatedAt,
    this.onboardingComplete = false,
    UserPreferences? preferences,
    List<String>? likes,
    List<String>? readingList,
    List<String>? savedPosts,
    List<String>? favoritePosts,
    List<String>? sectionBookmarks,
  })  : preferences = preferences ?? const UserPreferences(),
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
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
        'onboardingComplete': onboardingComplete,
        'onboardingData': preferences.toJson(),
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
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? onboardingComplete,
    UserPreferences? preferences,
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
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        onboardingComplete: onboardingComplete ?? this.onboardingComplete,
        preferences: preferences ?? this.preferences,
        likes: likes ?? this.likes,
        readingList: readingList ?? this.readingList,
        savedPosts: savedPosts ?? this.savedPosts,
        favoritePosts: favoritePosts ?? this.favoritePosts,
        sectionBookmarks: sectionBookmarks ?? this.sectionBookmarks,
      );
}
