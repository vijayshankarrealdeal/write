import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/mdi.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/ui/auth/widgets/auth_scaffold.dart';
import 'package:inkspacex/web_utils_stub.dart'
    if (dart.library.html) 'package:inkspacex/web_utils.dart' as web_utils;

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with TickerProviderStateMixin {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  bool _obscurePassword = true;

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      'auth_login_viewed',
      screen: '/login',
      action: 'view',
    );
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnim = CurvedAnimation(parent: _animController, curve: Curves.easeOut);
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    ));
    _animController.forward();

    // Surface errors from the backend's Google OAuth callback.
    if (kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final err = web_utils.consumeGoogleErrorFromUrl();
        if (err != null && mounted) {
          _showError('Google sign-in failed: $err');
        }
      });
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.inter()),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );
  }

  void _login() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      _showError('Please fill in all fields');
      return;
    }
    setState(() => _isLoading = true);
    try {
      await context.read<AuthProvider>().login(email, password);
    } catch (e) {
      _showError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _googleSignIn() async {
    setState(() => _isGoogleLoading = true);
    try {
      await context.read<AuthProvider>().signInWithGoogle();
    } catch (e) {
      _showError(e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isGoogleLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? const Color(0xFFF1F5F9) : const Color(0xFF111111);
    final subtle = ink.withOpacity(0.55);
    final busy = _isLoading || _isGoogleLoading;

    return AuthScaffold(
      title: 'Welcome back',
      subtitle: "Sign in to pick up where you left off.",
      heroCaption: 'Your story is waiting.',
      formChild: FadeTransition(
        opacity: _fadeAnim,
        child: SlideTransition(
          position: _slideAnim,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AuthSecondaryButton(
                label: 'Continue with Google',
                onPressed: busy ? null : _googleSignIn,
                loading: _isGoogleLoading,
                leading: Iconify(Mdi.google, size: 20, color: ink),
              ),
              const SizedBox(height: 18),
              const AuthDivider(),
              const SizedBox(height: 18),
              AuthField(
                controller: _emailController,
                focusNode: _emailFocus,
                label: 'Email',
                hint: 'you@example.com',
                icon: CupertinoIcons.mail,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
              const SizedBox(height: 14),
              AuthField(
                controller: _passwordController,
                focusNode: _passwordFocus,
                label: 'Password',
                hint: 'Your secret words',
                icon: CupertinoIcons.lock,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _login(),
                suffix: GestureDetector(
                  onTap: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                  child: Icon(
                    _obscurePassword
                        ? CupertinoIcons.eye_slash
                        : CupertinoIcons.eye,
                    size: 20,
                    color: subtle,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => context.push('/forgot-password'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 4, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    'Forgot password?',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: ink.withOpacity(0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              AuthPrimaryButton(
                label: 'Sign in',
                onPressed: busy ? null : _login,
                loading: _isLoading,
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    "New here? ",
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      color: subtle,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => context.go('/signup'),
                    child: Text(
                      'Create an account',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: ink,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () => context.go('/privacy-policy'),
                    child: Text(
                      'Privacy',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: ink.withOpacity(0.4),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text('·',
                        style: TextStyle(
                            fontSize: 12, color: ink.withOpacity(0.3))),
                  ),
                  GestureDetector(
                    onTap: () => context.go('/terms-of-service'),
                    child: Text(
                      'Terms',
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: ink.withOpacity(0.4),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
