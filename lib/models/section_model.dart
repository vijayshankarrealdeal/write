import 'dart:math';
import 'package:flutter/material.dart';

class SectionModel {
  String id;
  String title;
  String content;
  bool isSynced = false;
  Color sectionColor;
  DateTime createdAt;
  SectionModel({
    required this.id,
    required this.title,
    required this.content,
    this.isSynced = false,
    required this.sectionColor,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory SectionModel.fromJson(Map<String, dynamic> json) {
    return SectionModel(
      id: json['id'],
      title: json['title'],
      content: json['content'],
      sectionColor: Colors.primaries[Random().nextInt(Colors.primaries.length)]
          .withAlpha(150),
      isSynced: json['isSynced'] ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.parse(json['createdAt'])
          : DateTime.now(),
    );
  }
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'content': content,
      'isSynced': isSynced,
      'sectionColor': sectionColor.toARGB32(),
      'createdAt': createdAt.toIso8601String(),
    };
  }
}
