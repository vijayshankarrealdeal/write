import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MonochromeTheme {
  // Common design constants based on your images
  static const double _borderRadius = 28.0; // Sharp, modern edges
  static const double _pillRadius =
      90.0; // For those elegant buttons in Image 3

  // ==========================================
  // LIGHT THEME (Pure White & Deep Black)
  // ==========================================
  static ThemeData get lightTheme {
    final base = ThemeData.light();

    // Core Colors
    const Color bgWhite = Color(0xFFFFFFFF);
    const Color surfaceGrey = Color(0xFFFAFAFA);
    const Color borderGrey = Color(0xFFE5E5E5);
    const Color textBlack = Color(0xFF111827);
    const Color textSecondary = Color(0xFF6B7280);

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: bgWhite,

      // Forces the Material 3 engine to strictly use black/white/greys (Zero color tint)
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.black,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        primary: textBlack,
        onPrimary: bgWhite,
        surface: bgWhite,
        onSurface: textBlack,
      ),

      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        bodyLarge: GoogleFonts.inter(color: textBlack),
        bodyMedium: GoogleFonts.inter(color: textSecondary),
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: bgWhite,
        foregroundColor: textBlack,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),

      dividerTheme: const DividerThemeData(
        color: borderGrey,
        thickness: 1,
        space: 1,
      ),

      cardTheme: CardThemeData(
        color: surfaceGrey,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          side: const BorderSide(color: borderGrey),
        ),
      ),

      // Outlined buttons styled exactly like Image 3
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textBlack,
          side: const BorderSide(color: borderGrey, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_pillRadius),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      // Solid contrasting buttons
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: textBlack,
          foregroundColor: bgWhite,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_borderRadius),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceGrey,
        hintStyle: GoogleFonts.inter(color: textSecondary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          borderSide: const BorderSide(color: borderGrey),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          borderSide: const BorderSide(color: borderGrey),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          borderSide: const BorderSide(color: textBlack, width: 2),
        ),
      ),
    );
  }

  // ==========================================
  // DARK THEME (Charcoal, Deep Black & White)
  // ==========================================
  static ThemeData get darkTheme {
    final base = ThemeData.dark();

    // Core Colors based on your dark references
    const Color bgDark = Color(0xFF111111); // Very dark grey/black
    const Color surfaceDark = Color(0xFF1C1C1E); // Slightly lighter panel color
    const Color borderDark = Color(0xFF333333); // Subtle divider lines
    const Color textWhite = Color(0xFFF9FAFB); // Off-white for less eye strain
    const Color textSecondary = Color(0xFFA1A1AA); // Muted grey text

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,

      // Strictly monochrome Dark variant
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.white,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
        primary: textWhite,
        onPrimary: bgDark,
        surface: surfaceDark,
        onSurface: textWhite,
      ),

      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        bodyLarge: GoogleFonts.inter(color: textWhite),
        bodyMedium: GoogleFonts.inter(color: textSecondary),
        // Used in your image headers
        titleMedium: GoogleFonts.inter(
          color: textWhite,
          letterSpacing: 1.2,
          fontWeight: FontWeight.w500,
        ),
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: bgDark,
        foregroundColor: textWhite,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),

      dividerTheme: const DividerThemeData(
        color: borderDark,
        thickness: 1,
        space: 1,
      ),

      cardTheme: CardThemeData(
        color: surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          side: const BorderSide(color: borderDark),
        ),
      ),

      // Recreating the elegant pill buttons from Image 3
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textWhite,
          side: const BorderSide(
            color: textWhite,
            width: 1.0,
          ), // Stark white border
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_pillRadius),
          ),
          textStyle: GoogleFonts.inter(
            fontSize: 16,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.5,
          ),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: textWhite,
          foregroundColor: bgDark,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_borderRadius),
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surfaceDark, // Uses panel background like Image 1
        hintStyle: GoogleFonts.inter(color: textSecondary),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          borderSide: const BorderSide(color: borderDark),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          borderSide: const BorderSide(color: borderDark),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_borderRadius),
          borderSide: const BorderSide(color: textWhite, width: 1.5),
        ),
      ),
    );
  }
}
