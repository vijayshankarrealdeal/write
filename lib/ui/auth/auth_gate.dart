import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:writer/main.dart'; // To access HomePage
import 'package:writer/provider/auth_provider.dart';
import 'package:writer/services/storage_service.dart';
import 'package:writer/ui/auth/login_page.dart';
import 'package:writer/ui/onboarding/onboarding_page.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (!auth.isOnboardingComplete) {
          return OnboardingPage(storageService: context.read<StorageService>());
        }

        if (auth.isAuthenticated) {
          // If authenticated, ensure data is loaded
          // The EditorProvider loads data on init, so it should be fine.
          return const HomePage();
        } else {
          return const LoginPage();
        }
      },
    );
  }
}
