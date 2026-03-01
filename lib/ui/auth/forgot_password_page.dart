import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';

class ForgotPasswordPage extends StatefulWidget {
  const ForgotPasswordPage({super.key});

  @override
  State<ForgotPasswordPage> createState() => _ForgotPasswordPageState();
}

class _ForgotPasswordPageState extends State<ForgotPasswordPage> {
  final _emailController = TextEditingController();
  bool _isLoading = false;

  void _submit() async {
    setState(() => _isLoading = true);
    try {
      await context.read<AuthProvider>().forgotPassword(_emailController.text);
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Email Sent"),
            content: const Text(
              "Check your inbox for password reset instructions.",
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text("Error"),
            content: Text(
              e.toString().replaceFirst('Exception: ', ''),
              style: GoogleFonts.inter(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("OK"),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFFAFAFA);
    final textColor = isDark ? Colors.white : Colors.black;

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: const Text("Forgot Password"),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  CupertinoIcons.lock_shield,
                  size: 64,
                  color: isDark ? Colors.white70 : Colors.black87,
                ),
                const SizedBox(height: 32),
                Text(
                  "Reset Password",
                  style: GoogleFonts.playfairDisplay(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: textColor,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  "Enter your email to receive reset link",
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 16,
                    color: textColor.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 48),
                TextField(
                  controller: _emailController,
                  style: TextStyle(color: isDark ? Colors.white : Colors.black),
                  decoration: InputDecoration(
                    labelText: "Email",
                    prefixIcon: Icon(
                      CupertinoIcons.mail,
                      color: isDark ? Colors.white54 : Colors.black54,
                    ),
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withOpacity(0.05)
                        : Colors.grey[200],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isDark ? Colors.white : Colors.black87,
                      foregroundColor: isDark ? Colors.black : Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const CupertinoActivityIndicator(color: Colors.white)
                        : const Text(
                            "Send Reset Link",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
