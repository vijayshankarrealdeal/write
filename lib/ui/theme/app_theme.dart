import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MonochromeTheme {
  // Common design constants based on your images
  static const double _borderRadius = 28.0; // Sharp, modern edges
  static const double _pillRadius =
      90.0; // For those elegant buttons in Image 3

  // ==========================================
  // LIGHT THEME (Colorful & Modern)
  // ==========================================
  static ThemeData get lightTheme {
    final base = ThemeData.light();

    // Core Colors - More vibrant
    const Color bgWhite = Color(0xFFFFFFFF);
    const Color surfaceGrey = Color(0xFFF8F9FA);
    const Color borderGrey = Color(0xFFE9ECEF);
    const Color textBlack = Color(0xFF212529);
    const Color textSecondary = Color(0xFF6C757D);
    const Color accentBlue = Color(0xFF3B82F6); // Vibrant blue

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: bgWhite,

      // Colorful scheme
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentBlue,
        brightness: Brightness.light,
        primary: accentBlue,
        onPrimary: Colors.white,
        surface: bgWhite,
        onSurface: textBlack,
        secondary: const Color(0xFF8B5CF6), // Purple accent
        tertiary: const Color(0xFF10B981), // Green accent
      ),

      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        bodyLarge: GoogleFonts.inter(color: textBlack, fontSize: 17),
        bodyMedium: GoogleFonts.inter(color: textSecondary, fontSize: 16),
        titleLarge: GoogleFonts.inter(color: textBlack, fontSize: 22),
        titleMedium: GoogleFonts.inter(color: textBlack, fontSize: 18),
      ),

      appBarTheme: const AppBarTheme(
        backgroundColor: bgWhite,
        foregroundColor: textBlack,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 56,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),

      dividerTheme: const DividerThemeData(
        color: borderGrey,
        thickness: 1,
        space: 1,
      ),

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: bgWhite,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: textBlack,
        ),
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
          foregroundColor: Colors.white,
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
  // DARK THEME (Colorful Dark Mode)
  // ==========================================
  static ThemeData get darkTheme {
    final base = ThemeData.dark();

    // Core Colors - Pure black / neutral (Google-style)
    const Color bgDark = Color(0xFF000000); // Pure black
    const Color surfaceDark = Color(0xFF1A1A1A); // Card/surface
    const Color borderDark = Color(0xFF2E2E2E); // Border
    const Color textWhite = Color(0xFFF1F5F9);
    const Color textSecondary = Color(0xFF94A3B8);
    const Color accentBlue = Color(0xFFE8E8E8); // Neutral white/gray for dark mode

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: bgDark,

      // Colorful dark scheme
      colorScheme: ColorScheme.fromSeed(
        seedColor: accentBlue,
        brightness: Brightness.dark,
        primary: accentBlue,
        onPrimary: Colors.white,
        surface: surfaceDark,
        onSurface: textWhite,
        secondary: const Color(0xFFA78BFA), // Purple
        tertiary: const Color(0xFF34D399), // Green
      ),

      textTheme: GoogleFonts.interTextTheme(base.textTheme).copyWith(
        bodyLarge: GoogleFonts.inter(color: textWhite, fontSize: 17),
        bodyMedium: GoogleFonts.inter(color: textSecondary, fontSize: 16),
        titleLarge: GoogleFonts.inter(color: textWhite, fontSize: 22),
        titleMedium: GoogleFonts.inter(
          color: textWhite,
          fontSize: 18,
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
        toolbarHeight: 56,
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          tapTargetSize: MaterialTapTargetSize.padded,
        ),
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

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceDark,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: GoogleFonts.inter(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: textWhite,
        ),
      ),

      // Recreating the elegant pill buttons from Image 3
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: accentBlue,
          side: const BorderSide(
            color: accentBlue,
            width: 1.0,
          ),
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
          backgroundColor: accentBlue,
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
