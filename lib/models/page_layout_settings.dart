/// Page-layout settings for the paginated ("Page") editor view.
///
/// Stored per-project on [WritingModel] and persisted to the backend
/// as a single JSONB blob (`page_layout`) so legacy projects keep
/// working and new fields can be added without a migration.
///
/// All physical dimensions are stored in **inches**. Converters at
/// the bottom of this file provide pixel sizing for screen layout
/// (96 DPI, the de-facto CSS reference).
library;

enum PageSize { letter, a4, custom }

extension PageSizeLabel on PageSize {
  String get label {
    switch (this) {
      case PageSize.letter:
        return 'US Letter (8.5 × 11 in)';
      case PageSize.a4:
        return 'A4 (210 × 297 mm)';
      case PageSize.custom:
        return 'Custom';
    }
  }

  /// Default physical dimensions in inches for the named sizes.
  /// Custom returns the Letter defaults so the dialog has a starting
  /// point — the caller is expected to override with user-entered
  /// values.
  ({double widthIn, double heightIn}) get defaults {
    switch (this) {
      case PageSize.letter:
        return (widthIn: 8.5, heightIn: 11.0);
      case PageSize.a4:
        // A4 = 210 × 297 mm, converted to inches.
        return (widthIn: 210 / 25.4, heightIn: 297 / 25.4);
      case PageSize.custom:
        return (widthIn: 8.5, heightIn: 11.0);
    }
  }
}

/// Font face used for page-view rendering. The values match Google
/// Fonts that the project already pulls in elsewhere — keeps the
/// pubspec footprint flat.
enum PageFont { merriweather, lora, sourceSerif, inter, jetbrainsMono }

extension PageFontLabel on PageFont {
  String get label {
    switch (this) {
      case PageFont.merriweather:
        return 'Merriweather (serif)';
      case PageFont.lora:
        return 'Lora (serif)';
      case PageFont.sourceSerif:
        return 'Source Serif (serif)';
      case PageFont.inter:
        return 'Inter (sans)';
      case PageFont.jetbrainsMono:
        return 'JetBrains Mono';
    }
  }

  /// google_fonts method name. Resolved at the call site via a switch
  /// because google_fonts has no string-keyed factory.
  String get googleFontsKey {
    switch (this) {
      case PageFont.merriweather:
        return 'merriweather';
      case PageFont.lora:
        return 'lora';
      case PageFont.sourceSerif:
        return 'sourceSerif4';
      case PageFont.inter:
        return 'inter';
      case PageFont.jetbrainsMono:
        return 'jetBrainsMono';
    }
  }
}

class PageLayoutSettings {
  final PageSize size;
  final double widthIn;
  final double heightIn;
  final double marginTopIn;
  final double marginBottomIn;
  final double marginLeftIn;
  final double marginRightIn;
  final PageFont font;
  final double fontSizePt;
  final double lineHeight;

  const PageLayoutSettings({
    required this.size,
    required this.widthIn,
    required this.heightIn,
    required this.marginTopIn,
    required this.marginBottomIn,
    required this.marginLeftIn,
    required this.marginRightIn,
    required this.font,
    required this.fontSizePt,
    required this.lineHeight,
  });

  /// Industry-standard manuscript defaults: Letter, 1" margins all
  /// around, Merriweather 12 pt, double-spaced. Editors expect this
  /// shape when reviewing print-ready drafts.
  static const PageLayoutSettings standard = PageLayoutSettings(
    size: PageSize.letter,
    widthIn: 8.5,
    heightIn: 11.0,
    marginTopIn: 1.0,
    marginBottomIn: 1.0,
    marginLeftIn: 1.0,
    marginRightIn: 1.0,
    font: PageFont.merriweather,
    fontSizePt: 12,
    lineHeight: 1.5,
  );

  PageLayoutSettings copyWith({
    PageSize? size,
    double? widthIn,
    double? heightIn,
    double? marginTopIn,
    double? marginBottomIn,
    double? marginLeftIn,
    double? marginRightIn,
    PageFont? font,
    double? fontSizePt,
    double? lineHeight,
  }) {
    return PageLayoutSettings(
      size: size ?? this.size,
      widthIn: widthIn ?? this.widthIn,
      heightIn: heightIn ?? this.heightIn,
      marginTopIn: marginTopIn ?? this.marginTopIn,
      marginBottomIn: marginBottomIn ?? this.marginBottomIn,
      marginLeftIn: marginLeftIn ?? this.marginLeftIn,
      marginRightIn: marginRightIn ?? this.marginRightIn,
      font: font ?? this.font,
      fontSizePt: fontSizePt ?? this.fontSizePt,
      lineHeight: lineHeight ?? this.lineHeight,
    );
  }

  Map<String, dynamic> toJson() => {
        'size': size.name,
        'widthIn': widthIn,
        'heightIn': heightIn,
        'marginTopIn': marginTopIn,
        'marginBottomIn': marginBottomIn,
        'marginLeftIn': marginLeftIn,
        'marginRightIn': marginRightIn,
        'font': font.name,
        'fontSizePt': fontSizePt,
        'lineHeight': lineHeight,
      };

  /// Tolerant decoder. Anything missing or wrong-typed falls back to
  /// the matching field on [standard] so a partially-corrupted record
  /// never wedges the editor.
  factory PageLayoutSettings.fromJson(Map<String, dynamic> json) {
    PageSize parseSize(dynamic raw) {
      if (raw is String) {
        for (final v in PageSize.values) {
          if (v.name == raw) return v;
        }
      }
      return standard.size;
    }

    PageFont parseFont(dynamic raw) {
      if (raw is String) {
        for (final v in PageFont.values) {
          if (v.name == raw) return v;
        }
      }
      return standard.font;
    }

    double dbl(dynamic raw, double fallback) {
      if (raw is num) return raw.toDouble();
      return fallback;
    }

    return PageLayoutSettings(
      size: parseSize(json['size']),
      widthIn: dbl(json['widthIn'], standard.widthIn),
      heightIn: dbl(json['heightIn'], standard.heightIn),
      marginTopIn: dbl(json['marginTopIn'], standard.marginTopIn),
      marginBottomIn: dbl(json['marginBottomIn'], standard.marginBottomIn),
      marginLeftIn: dbl(json['marginLeftIn'], standard.marginLeftIn),
      marginRightIn: dbl(json['marginRightIn'], standard.marginRightIn),
      font: parseFont(json['font']),
      fontSizePt: dbl(json['fontSizePt'], standard.fontSizePt),
      lineHeight: dbl(json['lineHeight'], standard.lineHeight),
    );
  }

  // ── Pixel converters ──────────────────────────────────────────────
  // 1 inch == 96 logical pixels at the conventional CSS DPI.
  // 1 point == 1/72 inch. Internally we work in pixels, but settings
  // expose the friendlier inches/points to the user.

  static const double _pxPerIn = 96.0;
  static const double _ptPerIn = 72.0;

  double get pageWidthPx => widthIn * _pxPerIn;
  double get pageHeightPx => heightIn * _pxPerIn;
  double get marginTopPx => marginTopIn * _pxPerIn;
  double get marginBottomPx => marginBottomIn * _pxPerIn;
  double get marginLeftPx => marginLeftIn * _pxPerIn;
  double get marginRightPx => marginRightIn * _pxPerIn;
  double get contentWidthPx => pageWidthPx - marginLeftPx - marginRightPx;
  double get contentHeightPx => pageHeightPx - marginTopPx - marginBottomPx;
  double get fontSizePx => fontSizePt * _pxPerIn / _ptPerIn;
  double get lineHeightPx => fontSizePx * lineHeight;

  /// How many body lines fit between the top and bottom margins.
  /// Floor (not round) so we never overflow the bottom margin.
  int get linesPerPage {
    final raw = contentHeightPx / lineHeightPx;
    return raw.isFinite && raw > 0 ? raw.floor() : 1;
  }
}
