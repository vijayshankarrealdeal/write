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
import 'package:inkspacex/web_utils_stub.dart'
    if (dart.library.html) 'package:inkspacex/web_utils.dart' as web_utils;

class SignupPage extends StatefulWidget {
  const SignupPage({super.key});

  @override
  State<SignupPage> createState() => _SignupPageState();
}

class _SignupPageState extends State<SignupPage> with TickerProviderStateMixin {
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
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnim = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOut,
    );
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? const Color(0xFFF1F5F9) : const Color(0xFF212529);
    final subtleColor = textColor.withOpacity(0.5);
    final surfaceColor = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF8F9FA);
    final borderColor = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE9ECEF);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: FadeTransition(
            opacity: _fadeAnim,
            child: SlideTransition(
              position: _slideAnim,
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Logo
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: surfaceColor,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: borderColor),
                        ),
                        child: Icon(
                          CupertinoIcons.pencil_outline,
                          size: 32,
                          color: textColor.withOpacity(0.8),
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Title
                      Text(
                        "Create account",
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Start your writing journey",
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          color: subtleColor,
                          fontWeight: FontWeight.w400,
                        ),
                      ),

                      const SizedBox(height: 40),

                      // Google button first
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: OutlinedButton(
                          onPressed: (_isLoading || _isGoogleLoading) ? null : _googleSignIn,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: textColor,
                            side: BorderSide(color: borderColor, width: 1.5),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _isGoogleLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: subtleColor,
                                  ),
                                )
                              : Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Iconify(Mdi.google, size: 20, color: textColor),
                                    const SizedBox(width: 12),
                                    Text(
                                      "Continue with Google",
                                      style: GoogleFonts.inter(
                                        fontSize: 15,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // Divider
                      Row(
                        children: [
                          Expanded(child: Divider(color: borderColor)),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              "or",
                              style: GoogleFonts.inter(
                                fontSize: 13,
                                color: subtleColor,
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          ),
                          Expanded(child: Divider(color: borderColor)),
                        ],
                      ),

                      const SizedBox(height: 28),

                      // Name field
                      _AuthTextField(
                        controller: _nameController,
                        focusNode: _nameFocus,
                        label: "Name",
                        hint: "Your full name",
                        icon: CupertinoIcons.person,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _emailFocus.requestFocus(),
                        isDark: isDark,
                      ),

                      const SizedBox(height: 14),

                      // Email field
                      _AuthTextField(
                        controller: _emailController,
                        focusNode: _emailFocus,
                        label: "Email",
                        hint: "you@example.com",
                        icon: CupertinoIcons.mail,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _passwordFocus.requestFocus(),
                        isDark: isDark,
                      ),

                      const SizedBox(height: 14),

                      // Password field
                      _AuthTextField(
                        controller: _passwordController,
                        focusNode: _passwordFocus,
                        label: "Password",
                        hint: "At least 6 characters",
                        icon: CupertinoIcons.lock,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => _confirmFocus.requestFocus(),
                        isDark: isDark,
                        suffix: GestureDetector(
                          onTap: () => setState(() => _obscurePassword = !_obscurePassword),
                          child: Icon(
                            _obscurePassword
                                ? CupertinoIcons.eye_slash
                                : CupertinoIcons.eye,
                            size: 20,
                            color: subtleColor,
                          ),
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Confirm password field
                      _AuthTextField(
                        controller: _confirmPasswordController,
                        focusNode: _confirmFocus,
                        label: "Confirm password",
                        hint: "Re-enter your password",
                        icon: CupertinoIcons.lock,
                        obscureText: _obscureConfirm,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _signup(),
                        isDark: isDark,
                        suffix: GestureDetector(
                          onTap: () => setState(() => _obscureConfirm = !_obscureConfirm),
                          child: Icon(
                            _obscureConfirm
                                ? CupertinoIcons.eye_slash
                                : CupertinoIcons.eye,
                            size: 20,
                            color: subtleColor,
                          ),
                        ),
                      ),

                      const SizedBox(height: 28),

                      // Sign up button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: (_isLoading || _isGoogleLoading) ? null : _signup,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: isDark ? Colors.white : const Color(0xFF212529),
                            foregroundColor: isDark ? Colors.black : Colors.white,
                            disabledBackgroundColor: (isDark ? Colors.white : const Color(0xFF212529)).withOpacity(0.6),
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: _isLoading
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: isDark ? Colors.black : Colors.white,
                                  ),
                                )
                              : Text(
                                  "Create account",
                                  style: GoogleFonts.inter(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 16),

                      // Terms notice
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text.rich(
                          TextSpan(
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: textColor.withOpacity(0.35),
                              height: 1.5,
                            ),
                            children: [
                              const TextSpan(text: "By creating an account, you agree to our "),
                              WidgetSpan(
                                child: GestureDetector(
                                  onTap: () => context.go('/terms-of-service'),
                                  child: Text(
                                    "Terms",
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      color: textColor.withOpacity(0.5),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const TextSpan(text: " and "),
                              WidgetSpan(
                                child: GestureDetector(
                                  onTap: () => context.go('/privacy-policy'),
                                  child: Text(
                                    "Privacy Policy",
                                    style: GoogleFonts.inter(
                                      fontSize: 12,
                                      color: textColor.withOpacity(0.5),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                              const TextSpan(text: "."),
                            ],
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Login link
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            "Already have an account? ",
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: subtleColor,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => context.go('/login'),
                            child: Text(
                              "Sign in",
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: textColor,
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
            ),
          ),
        ),
      ),
    );
  }
}

class _AuthTextField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String label;
  final String? hint;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final bool isDark;
  final Widget? suffix;

  const _AuthTextField({
    required this.controller,
    this.focusNode,
    required this.label,
    this.hint,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    required this.isDark,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? const Color(0xFFF1F5F9) : const Color(0xFF212529);
    final subtleColor = textColor.withOpacity(0.5);
    final fillColor = isDark ? const Color(0xFF1A1A1A) : const Color(0xFFF8F9FA);
    final borderColor = isDark ? const Color(0xFF2E2E2E) : const Color(0xFFE9ECEF);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: textColor.withOpacity(0.7),
            ),
          ),
        ),
        TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscureText,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          onSubmitted: onSubmitted,
          style: GoogleFonts.inter(
            color: textColor,
            fontSize: 15,
          ),
          cursorColor: textColor.withOpacity(0.6),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: GoogleFonts.inter(
              color: subtleColor.withOpacity(0.5),
              fontSize: 15,
            ),
            prefixIcon: Padding(
              padding: const EdgeInsets.only(left: 16, right: 12),
              child: Icon(icon, size: 20, color: subtleColor),
            ),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: suffix != null
                ? Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: suffix,
                  )
                : null,
            suffixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            filled: true,
            fillColor: fillColor,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: textColor.withOpacity(0.4), width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}
