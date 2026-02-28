import 'package:writer/models/section_model.dart';

enum WritingStatus { ongoing, completed, paused }

// 🔥 Social Writing Categories
enum WritingType { creative, digitalContent, personal, journalistic, marketing }

// =======================
// Social-Relevant Subtypes
// =======================

enum CreativeWriting { shortStory, poetry, script, flashFiction }

enum DigitalContentWriting {
  blogPost,
  newsletter,
  socialMediaPost,
  caption,
  thread,
  reelsScript,
}

enum PersonalWriting {
  storytime,
  rant,
  openLetter,
  lifeUpdate,
  affirmation,
  deepTalk,
  relationshipTea,
  mentalHealthLog,
}

enum JournalisticWriting { newsArticle, editorial, opinionPiece, interview }

enum MarketingWriting { adCopy, productDescription, emailCampaign, slogan }

// Extension to convert WritingType enum to display string
extension WritingTypeDisplay on WritingType {
  String get displayName {
    switch (this) {
      case WritingType.creative:
        return 'Creative';
      case WritingType.digitalContent:
        return 'Digital Content';
      case WritingType.personal:
        return 'Personal';
      case WritingType.journalistic:
        return 'Journalistic';
      case WritingType.marketing:
        return 'Marketing';
    }
  }
}

// Extensions for each subtype enum

extension CreativeWritingDisplay on CreativeWriting {
  String get displayName {
    switch (this) {
      case CreativeWriting.shortStory:
        return 'Short Story';
      case CreativeWriting.poetry:
        return 'Poetry';
      case CreativeWriting.script:
        return 'Script';
      case CreativeWriting.flashFiction:
        return 'Flash Fiction';
    }
  }
}

extension DigitalContentWritingDisplay on DigitalContentWriting {
  String get displayName {
    switch (this) {
      case DigitalContentWriting.blogPost:
        return 'Blog Post';
      case DigitalContentWriting.newsletter:
        return 'Newsletter';
      case DigitalContentWriting.socialMediaPost:
        return 'Social Media Post';
      case DigitalContentWriting.caption:
        return 'Caption';
      case DigitalContentWriting.thread:
        return 'Thread';
      case DigitalContentWriting.reelsScript:
        return 'Reels Script';
    }
  }
}

extension PersonalWritingDisplay on PersonalWriting {
  String get displayName {
    switch (this) {
      case PersonalWriting.storytime:
        return 'Storytime';
      case PersonalWriting.rant:
        return 'Rant';
      case PersonalWriting.openLetter:
        return 'Open Letter';
      case PersonalWriting.lifeUpdate:
        return 'Life Update';
      case PersonalWriting.affirmation:
        return 'Affirmation';
      case PersonalWriting.deepTalk:
        return 'Deep Talk';
      case PersonalWriting.relationshipTea:
        return 'Relationship Tea';
      case PersonalWriting.mentalHealthLog:
        return 'Mental Health Log';
    }
  }
}

extension JournalisticWritingDisplay on JournalisticWriting {
  String get displayName {
    switch (this) {
      case JournalisticWriting.newsArticle:
        return 'News Article';
      case JournalisticWriting.editorial:
        return 'Editorial';
      case JournalisticWriting.opinionPiece:
        return 'Opinion Piece';
      case JournalisticWriting.interview:
        return 'Interview';
    }
  }
}

extension MarketingWritingDisplay on MarketingWriting {
  String get displayName {
    switch (this) {
      case MarketingWriting.adCopy:
        return 'Ad Copy';
      case MarketingWriting.productDescription:
        return 'Product Description';
      case MarketingWriting.emailCampaign:
        return 'Email Campaign';
      case MarketingWriting.slogan:
        return 'Slogan';
    }
  }
}

List<String> getDisplaySubtypesForWritingType(WritingType type) {
  switch (type) {
    case WritingType.creative:
      return CreativeWriting.values.map((e) => e.displayName).toList();
    case WritingType.digitalContent:
      return DigitalContentWriting.values.map((e) => e.displayName).toList();
    case WritingType.personal:
      return PersonalWriting.values.map((e) => e.displayName).toList();
    case WritingType.journalistic:
      return JournalisticWriting.values.map((e) => e.displayName).toList();
    case WritingType.marketing:
      return MarketingWriting.values.map((e) => e.displayName).toList();
  }
}

class WritingModel {
  String id;
  String title;
  String author;
  String description;
  String coverImagePath;
  WritingStatus status;
  WritingType writingType; // 🔥 NEW
  String subtype; // 🔥 NEW (stores enum.name)
  DateTime createdAt = DateTime.now();
  List<SectionModel> sections;

  WritingModel({
    required this.id,
    required this.title,
    required this.sections,
    required this.author,
    required this.description,
    required this.coverImagePath,
    required this.writingType, // 🔥 NEW
    required this.subtype, // 🔥 NEW
    this.status = WritingStatus.ongoing,
  });

  factory WritingModel.fromJson(Map<String, dynamic> json) {
    return WritingModel(
      id: json['id'],
      title: json['title'],
      author: json['author'],
      status: WritingStatus.values[json['status']],
      description: json['description'],
      coverImagePath: json['coverImagePath'],
      writingType: WritingType.values[json['writingType']], // 🔥
      subtype: json['subtype'], // 🔥
      sections: (json['sections'] as List)
          .map((sectionJson) => SectionModel.fromJson(sectionJson))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'status': status.index,
      'author': author,
      'description': description,
      'coverImagePath': coverImagePath,
      'writingType': writingType.index, // 🔥
      'subtype': subtype, // 🔥
      'createdAt': createdAt.toIso8601String(),
      'sections': sections.map((section) => section.toJson()).toList(),
    };
  }
}
