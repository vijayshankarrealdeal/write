import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:inkspacex/ui/auth/widgets/auth_scaffold.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';

/// Shown while auth state is being determined. No login form or home UI.
///
/// We piggy-back on this idle moment to warm up the auth-screen assets so
/// that if the user lands on /login or /signup next, the doodles and
/// scribbles paint instantly instead of streaming in.
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Fire-and-forget. Failures here are non-critical.
      precacheAuthAssets(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              "Inkspacex",
              style: GoogleFonts.playfairDisplay(
                fontSize: 38,
                fontWeight: FontWeight.bold,
                color: textColor,
              ),
            ),
            const SizedBox(height: 32),
            AppSpinner(
              size: 24,
              color: textColor.withValues(alpha: 0.6),
            ),
          ],
        ),
      ),
    );
  }
}
