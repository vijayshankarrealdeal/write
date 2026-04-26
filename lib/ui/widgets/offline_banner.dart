import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/services/connectivity_service.dart';

/// App-wide top banner that appears whenever the device is offline.
///
/// Render this once near the root by wrapping the page subtree:
/// `OfflineBanner(child: child)`. It stays out of the way when online and
/// adds a single 28px-tall strip when offline.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final svc = context.read<ConnectivityService>();
    return ValueListenableBuilder<bool>(
      valueListenable: svc.isOnline,
      builder: (context, online, _) {
        return Material(
          type: MaterialType.transparency,
          child: Column(
            children: [
              if (!online) const _OfflineStrip(),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }
}

class _OfflineStrip extends StatelessWidget {
  const _OfflineStrip();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF3A2A00) : const Color(0xFFFFF3CD);
    final fg = isDark ? const Color(0xFFFFE39A) : const Color(0xFF664D03);
    return SafeArea(
      bottom: false,
      child: Container(
        width: double.infinity,
        height: 28,
        color: bg,
        alignment: Alignment.center,
        child: Text(
          'You’re offline. Changes will sync when back online.',
          style: GoogleFonts.inter(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: fg,
          ),
        ),
      ),
    );
  }
}
