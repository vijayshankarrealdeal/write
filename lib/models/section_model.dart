import 'dart:math';
import 'package:flutter/material.dart';

class SectionModel {
  String id;
  String title;
  String content;
  bool isSynced;
  Color sectionColor;
  DateTime createdAt;
  DateTime updatedAt;

  SectionModel({
    required this.id,
    required this.title,
    required this.content,
    this.isSynced = false,
    required this.sectionColor,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  factory SectionModel.fromJson(Map<String, dynamic> json) {
    return SectionModel(
      id: json['id'],
      title: json['title'],
      content: json['content'],
      sectionColor: json['sectionColor'] != null
          ? Color(json['sectionColor'])
          : Colors.primaries[Random().nextInt(Colors.primaries.length)]
                .withAlpha(150),
      isSynced: json['isSynced'] ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
      updatedAt: json['updatedAt'] != null
          ? DateTime.parse(json['updatedAt'])
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'isSynced': isSynced,
      'sectionColor': sectionColor.value,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}
