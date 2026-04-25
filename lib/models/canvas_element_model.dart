import 'dart:ui';

enum CanvasElementType { image, text }

/// A single element on the free-form canvas (image or text block).
/// Stores position, size, rotation, and content for scrapbook-style layouts.
class CanvasElement {
  String id;
  CanvasElementType type;
  double x;
  double y;
  double width;
  double height;
  double rotation; // radians
  int zIndex;

  // Image properties
  String imageUrl; // data-URI or https URL

  // Text properties
  String text;
  String fontFamily;
  double fontSize;
  int textColorValue;
  int bgColorValue;
  bool isBold;
  bool isItalic;
  String textAlign; // 'left', 'center', 'right'
  bool hasBorder;
  int borderColorValue;

  // Gradient (optional — two-color linear gradient instead of solid bg)
  int? gradientStartColor;
  int? gradientEndColor;
  String gradientDirection; // 'topLeft', 'topRight', 'top', 'left'

  CanvasElement({
    required this.id,
    required this.type,
    this.x = 0.05,
    this.y = 0.05,
    this.width = 0.27,
    this.height = 0.27,
    this.rotation = 0,
    this.zIndex = 0,
    this.imageUrl = '',
    this.text = 'Tap to edit',
    this.fontFamily = 'Inter',
    this.fontSize = 20,
    this.textColorValue = 0xFF000000,
    this.bgColorValue = 0x00000000,
    this.isBold = false,
    this.isItalic = false,
    this.textAlign = 'left',
    this.hasBorder = false,
    this.borderColorValue = 0x40FFFFFF,
    this.gradientStartColor,
    this.gradientEndColor,
    this.gradientDirection = 'topLeft',
  });

  factory CanvasElement.fromJson(Map<String, dynamic> json) {
    return CanvasElement(
      id: json['id'] ?? '',
      type: json['type'] == 'image'
          ? CanvasElementType.image
          : CanvasElementType.text,
      x: (json['x'] ?? 0.05).toDouble(),
      y: (json['y'] ?? 0.05).toDouble(),
      width: (json['width'] ?? 0.27).toDouble(),
      height: (json['height'] ?? 0.27).toDouble(),
      rotation: (json['rotation'] ?? 0).toDouble(),
      zIndex: json['zIndex'] ?? 0,
      imageUrl: json['imageUrl'] ?? '',
      text: json['text'] ?? 'Tap to edit',
      fontFamily: json['fontFamily'] ?? 'Inter',
      fontSize: (json['fontSize'] ?? 20).toDouble(),
      textColorValue: json['textColorValue'] ?? 0xFF000000,
      bgColorValue: json['bgColorValue'] ?? 0x00000000,
      isBold: json['isBold'] ?? false,
      isItalic: json['isItalic'] ?? false,
      textAlign: json['textAlign'] ?? 'left',
      hasBorder: json['hasBorder'] ?? false,
      borderColorValue: json['borderColorValue'] ?? 0x40FFFFFF,
      gradientStartColor: json['gradientStartColor'],
      gradientEndColor: json['gradientEndColor'],
      gradientDirection: json['gradientDirection'] ?? 'topLeft',
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type == CanvasElementType.image ? 'image' : 'text',
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'rotation': rotation,
        'zIndex': zIndex,
        'imageUrl': imageUrl,
        'text': text,
        'fontFamily': fontFamily,
        'fontSize': fontSize,
        'textColorValue': textColorValue,
        'bgColorValue': bgColorValue,
        'isBold': isBold,
        'isItalic': isItalic,
        'textAlign': textAlign,
        'hasBorder': hasBorder,
        'borderColorValue': borderColorValue,
        if (gradientStartColor != null) 'gradientStartColor': gradientStartColor,
        if (gradientEndColor != null) 'gradientEndColor': gradientEndColor,
        if (gradientStartColor != null) 'gradientDirection': gradientDirection,
      };

  Color get textColor => Color(textColorValue);
  Color get bgColor => Color(bgColorValue);

  CanvasElement copyWith({
    String? id,
    CanvasElementType? type,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    int? zIndex,
    String? imageUrl,
    String? text,
    String? fontFamily,
    double? fontSize,
    int? textColorValue,
    int? bgColorValue,
    bool? isBold,
    bool? isItalic,
    String? textAlign,
    bool? hasBorder,
    int? borderColorValue,
    int? gradientStartColor,
    int? gradientEndColor,
    String? gradientDirection,
  }) =>
      CanvasElement(
        id: id ?? this.id,
        type: type ?? this.type,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
        rotation: rotation ?? this.rotation,
        zIndex: zIndex ?? this.zIndex,
        imageUrl: imageUrl ?? this.imageUrl,
        text: text ?? this.text,
        fontFamily: fontFamily ?? this.fontFamily,
        fontSize: fontSize ?? this.fontSize,
        textColorValue: textColorValue ?? this.textColorValue,
        bgColorValue: bgColorValue ?? this.bgColorValue,
        isBold: isBold ?? this.isBold,
        isItalic: isItalic ?? this.isItalic,
        textAlign: textAlign ?? this.textAlign,
        hasBorder: hasBorder ?? this.hasBorder,
        borderColorValue: borderColorValue ?? this.borderColorValue,
        gradientStartColor: gradientStartColor ?? this.gradientStartColor,
        gradientEndColor: gradientEndColor ?? this.gradientEndColor,
        gradientDirection: gradientDirection ?? this.gradientDirection,
      );
}
