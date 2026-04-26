import 'package:inkspacex/models/image_meta.dart';

class Bookshelf {
  final String id;
  final String name;
  final String description;
  final bool isPrivate;
  final List<String> itemIds;
  final String? coverImageUrl;
  final ImageMeta? coverImageMeta;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const Bookshelf({
    required this.id,
    required this.name,
    this.description = '',
    this.isPrivate = false,
    this.itemIds = const [],
    this.coverImageUrl,
    this.coverImageMeta,
    this.createdAt,
    this.updatedAt,
  });

  int get itemCount => itemIds.length;

  factory Bookshelf.fromJson(Map<String, dynamic> json) {
    return Bookshelf(
      id: json['id'] ?? '',
      name: json['name'] ?? '',
      description: json['description'] ?? '',
      isPrivate: json['isPrivate'] ?? false,
      itemIds: List<String>.from(json['itemIds'] ?? []),
      coverImageUrl: json['coverImageUrl'],
      coverImageMeta: ImageMeta.tryFromJson(
          json['coverImageMeta'] ?? json['cover_image_meta']),
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'].toString())
          : null,
      updatedAt: json['updatedAt'] != null
          ? DateTime.tryParse(json['updatedAt'].toString())
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'isPrivate': isPrivate,
        'itemIds': itemIds,
        'coverImageUrl': coverImageUrl,
        'coverImageMeta': coverImageMeta?.toJson(),
        'createdAt': createdAt?.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
      };

  Bookshelf copyWith({
    String? id,
    String? name,
    String? description,
    bool? isPrivate,
    List<String>? itemIds,
    String? coverImageUrl,
    ImageMeta? coverImageMeta,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) =>
      Bookshelf(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        isPrivate: isPrivate ?? this.isPrivate,
        itemIds: itemIds ?? this.itemIds,
        coverImageUrl: coverImageUrl ?? this.coverImageUrl,
        coverImageMeta: coverImageMeta ?? this.coverImageMeta,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
}
