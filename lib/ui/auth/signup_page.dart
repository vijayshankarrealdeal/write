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

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage>
    with TickerProviderStateMixin {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _nameFocus = FocusNode();
  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _confirmFocus = FocusNode();
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;

  late final AnimationController _animController;
  late final Animation<double> _fadeAnim;
  late final Animation<Offset> _slideAnim;

  @override
  void initState() {
    super.initState();
    AnalyticsService.instance.track(
      'auth_signup_viewed',
      screen: '/signup',
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
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _nameFocus.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    _confirmFocus.dispose();
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

  void _signup() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmPasswordController.text;

    if (name.isEmpty || email.isEmpty || password.isEmpty || confirm.isEmpty) {
      _showError('Please fill in all fields');
      return;
    }
    if (password != confirm) {
      _showError('Passwords do not match');
      return;
    }
    if (password.length < 6) {
      _showError('Password must be at least 6 characters');
      return;
    }

    setState(() => _isLoading = true);
    try {
      await context.read<AuthProvider>().signup(name, email, password);
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
      title: 'Create your account',
      subtitle: 'Free, no card needed. Start writing in seconds.',
      heroCaption: 'Craft captivating stories.',
      formChild: FadeTransition(
        opacity: _fadeAnim,
        child: SlideTransition(
          position: _slideAnim,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AuthSecondaryButton(
                label: 'Sign up with Google',
                onPressed: busy ? null : _googleSignIn,
                loading: _isGoogleLoading,
                leading: Iconify(Mdi.google, size: 20, color: ink),
              ),
              const SizedBox(height: 18),
              const AuthDivider(),
              const SizedBox(height: 18),
              AuthField(
                controller: _nameController,
                focusNode: _nameFocus,
                label: 'Name',
                hint: 'What should we call you?',
                icon: CupertinoIcons.person,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _emailFocus.requestFocus(),
              ),
              const SizedBox(height: 14),
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
                hint: 'At least 6 characters',
                icon: CupertinoIcons.lock,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.next,
                onSubmitted: (_) => _confirmFocus.requestFocus(),
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
              const SizedBox(height: 14),
              AuthField(
                controller: _confirmPasswordController,
                focusNode: _confirmFocus,
                label: 'Confirm password',
                hint: 'Type it once more',
                icon: CupertinoIcons.lock,
                obscureText: _obscureConfirm,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _signup(),
                suffix: GestureDetector(
                  onTap: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                  child: Icon(
                    _obscureConfirm
                        ? CupertinoIcons.eye_slash
                        : CupertinoIcons.eye,
                    size: 20,
                    color: subtle,
                  ),
                ),
              ),
              const SizedBox(height: 22),
              AuthPrimaryButton(
                label: 'Create account',
                onPressed: busy ? null : _signup,
                loading: _isLoading,
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text.rich(
                  TextSpan(
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: ink.withOpacity(0.45),
                      height: 1.5,
                    ),
                    children: [
                      const TextSpan(text: 'By creating an account, you agree to our '),
                      WidgetSpan(
                        child: GestureDetector(
                          onTap: () => context.go('/terms-of-service'),
                          child: Text(
                            'Terms',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: ink.withOpacity(0.65),
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                      const TextSpan(text: ' and '),
                      WidgetSpan(
                        child: GestureDetector(
                          onTap: () => context.go('/privacy-policy'),
                          child: Text(
                            'Privacy Policy',
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: ink.withOpacity(0.65),
                              fontWeight: FontWeight.w700,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                      ),
                      const TextSpan(text: '.'),
                    ],
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Already have an account? ',
                    style: GoogleFonts.inter(fontSize: 14, color: subtle),
                  ),
                  GestureDetector(
                    onTap: () => context.go('/login'),
                    child: Text(
                      'Sign in',
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: ink,
                        fontWeight: FontWeight.w600,
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
