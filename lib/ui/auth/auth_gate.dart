import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:writer/main.dart'; // To access HomePage
import 'package:writer/provider/auth_provider.dart';
import 'package:writer/ui/auth/login_page.dart';
import 'package:writer/ui/auth/splash_screen.dart';
import 'package:writer/ui/onboarding/onboarding_page.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        // 0. Auth state not yet known, or restoring session → Splash only
        if (!auth.authStateKnown || auth.isRestoringSession) {
          return const SplashScreen();
        }
        // 1. Not authenticated → Login/Signup first
        if (!auth.isAuthenticated) {
          return const LoginPage();
        }
        // 2. Authenticated but new user (onboarding not complete) → Onboarding
        if (!auth.isOnboardingComplete) {
          return const OnboardingPage();
        }
        // 3. Authenticated + onboarding done → Home
        return const HomePage();
      },
    );
  }
}
