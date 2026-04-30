import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/mdi.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
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

    // Surface errors from the backend's Google OAuth callback (e.g. token
    // verification failed). Read after first frame so the SnackBar has a
    // ScaffoldMessenger to attach to.
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
                        "Welcome back",
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 30,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Sign in to continue writing",
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          color: subtleColor,
                          fontWeight: FontWeight.w400,
                        ),
                      ),

                      const SizedBox(height: 40),

                      // Google button first (highest conversion)
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
                        hint: "Enter your password",
                        icon: CupertinoIcons.lock,
                        obscureText: _obscurePassword,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _login(),
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

                      const SizedBox(height: 8),

                      // Forgot password
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => context.push('/forgot-password'),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text(
                            "Forgot password?",
                            style: GoogleFonts.inter(
                              fontSize: 13,
                              color: subtleColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 24),

                      // Login button
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: ElevatedButton(
                          onPressed: (_isLoading || _isGoogleLoading) ? null : _login,
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
                                  "Sign in",
                                  style: GoogleFonts.inter(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                        ),
                      ),

                      const SizedBox(height: 32),

                      // Sign up link
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            "Don't have an account? ",
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: subtleColor,
                            ),
                          ),
                          GestureDetector(
                            onTap: () => context.go('/signup'),
                            child: Text(
                              "Sign up",
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                color: textColor,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 48),

                      // Legal links
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          GestureDetector(
                            onTap: () => context.go('/privacy-policy'),
                            child: Text(
                              'Privacy Policy',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: textColor.withOpacity(0.35),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              '·',
                              style: TextStyle(
                                fontSize: 12,
                                color: textColor.withOpacity(0.25),
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: () => context.go('/terms-of-service'),
                            child: Text(
                              'Terms of Service',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: textColor.withOpacity(0.35),
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
