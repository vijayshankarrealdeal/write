/// "Manage Downloads" — list every offline `.inkx` with size, expiry,
/// and a Remove action. Surfaces a "Clear all" entry that wipes both
/// the on-disk store and the device key (subsequent downloads issue a
/// fresh `book_key`, see `OfflineLibrary.evictAll`).
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/offline_provider.dart';
import 'package:inkspacex/services/image_cache_manager.dart';
import 'package:inkspacex/services/offline/offline_library.dart';

class ManageDownloadsPage extends StatefulWidget {
  const ManageDownloadsPage({super.key});

  @override
  State<ManageDownloadsPage> createState() => _ManageDownloadsPageState();
}

class _ManageDownloadsPageState extends State<ManageDownloadsPage> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      context.read<OfflineProvider>().ensureReady();
    });
  }

  String _fmtSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  String _fmtExpiry(int unixSec) {
    final dt = DateTime.fromMillisecondsSinceEpoch(unixSec * 1000);
    final now = DateTime.now();
    final delta = dt.difference(now);
    if (delta.isNegative) return 'expired';
    final days = delta.inDays;
    if (days >= 1) return 'expires in $days day${days == 1 ? '' : 's'}';
    final hours = delta.inHours;
    if (hours >= 1) return 'expires in $hours hour${hours == 1 ? '' : 's'}';
    return 'expires soon';
  }

  Future<void> _confirmEvict(OfflineProvider offline, OfflineBookMeta meta) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(meta.title),
        content: const Text('Remove the offline copy of this book?'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await offline.evict(meta.bookId);
    }
  }

  Future<void> _confirmClearImageCache() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Clear image cache?'),
        content: const Text(
          'Removes cached covers and inline images. They will redownload '
          'the next time you open a book or scroll the feed.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppImageCacheManager().emptyCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Image cache cleared')),
    );
  }

  Future<void> _confirmEvictAll(OfflineProvider offline) async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Remove all downloads?'),
        content: const Text(
          'This deletes every offline copy and rotates the device key. '
          'You will need to redownload anything you want to read offline.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove all'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await offline.evictAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black;
    final subtle = isDark ? Colors.white70 : Colors.black54;

    return Consumer<OfflineProvider>(
      builder: (context, offline, _) {
        final books = offline.list();
        return Scaffold(
          appBar: AppBar(
            title: const Text('Manage downloads'),
            centerTitle: true,
            actions: [
              if (books.isNotEmpty)
                TextButton(
                  onPressed: () => _confirmEvictAll(offline),
                  child: const Text('Clear all'),
                ),
            ],
          ),
          body: SafeArea(
            child: offline.unavailableReason != null
                ? _UnavailableState(reason: offline.unavailableReason!)
                : books.isEmpty
                    ? ListView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        children: [
                          _EmptyState(textColor: textColor, subtle: subtle),
                          const SizedBox(height: 24),
                          _ClearImageCacheTile(
                            textColor: textColor,
                            subtle: subtle,
                            onTap: _confirmClearImageCache,
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        itemCount: books.length + 2,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          if (i == books.length) {
                            return _UsageFooter(
                              total: offline.totalBytes(),
                              count: books.length,
                              fmt: _fmtSize,
                            );
                          }
                          if (i == books.length + 1) {
                            return _ClearImageCacheTile(
                              textColor: textColor,
                              subtle: subtle,
                              onTap: _confirmClearImageCache,
                            );
                          }
                          final b = books[i];
                          return ListTile(
                            title: Text(
                              b.title.isEmpty ? 'Untitled' : b.title,
                              style: GoogleFonts.inter(
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                            ),
                            subtitle: Text(
                              '${b.author.isEmpty ? 'Unknown author' : b.author}'
                              '  •  ${_fmtSize(b.sizeBytes)}'
                              '  •  ${_fmtExpiry(b.licenseExpiresAt)}',
                              style: GoogleFonts.inter(
                                fontSize: 12,
                                color: subtle,
                              ),
                            ),
                            trailing: IconButton(
                              icon: Icon(CupertinoIcons.delete, color: subtle),
                              onPressed: () => _confirmEvict(offline, b),
                            ),
                          );
                        },
                      ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.textColor, required this.subtle});
  final Color textColor;
  final Color subtle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(CupertinoIcons.cloud_download, size: 48, color: subtle),
            const SizedBox(height: 12),
            Text(
              'No downloads yet',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Open a book and tap the download icon to read it offline.',
              textAlign: TextAlign.center,
              style: GoogleFonts.inter(fontSize: 13, color: subtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnavailableState extends StatelessWidget {
  const _UnavailableState({required this.reason});
  final String reason;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          reason,
          textAlign: TextAlign.center,
          style: GoogleFonts.inter(fontSize: 14),
        ),
      ),
    );
  }
}

class _ClearImageCacheTile extends StatelessWidget {
  const _ClearImageCacheTile({
    required this.textColor,
    required this.subtle,
    required this.onTap,
  });
  final Color textColor;
  final Color subtle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(CupertinoIcons.photo, color: subtle),
      title: Text(
        'Clear image cache',
        style: GoogleFonts.inter(
          fontWeight: FontWeight.w600,
          color: textColor,
        ),
      ),
      subtitle: Text(
        'Remove cached covers and inline images',
        style: GoogleFonts.inter(fontSize: 12, color: subtle),
      ),
      trailing: const Icon(CupertinoIcons.chevron_right, size: 16),
      onTap: onTap,
    );
  }
}

class _UsageFooter extends StatelessWidget {
  const _UsageFooter({
    required this.total,
    required this.count,
    required this.fmt,
  });

  final int total;
  final int count;
  final String Function(int) fmt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        '$count book${count == 1 ? '' : 's'}  •  ${fmt(total)} on disk',
        style: GoogleFonts.inter(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
