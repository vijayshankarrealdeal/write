import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/main.dart';
import 'package:inkspacex/web_utils_stub.dart'
    if (dart.library.html) 'package:inkspacex/web_utils.dart' as web_utils;
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/services/analytics_observer.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/ui/widgets/app_spinner.dart';
import 'package:inkspacex/ui/auth/login_page.dart';
import 'package:inkspacex/ui/auth/signup_page.dart';
import 'package:inkspacex/ui/auth/forgot_password_page.dart';
import 'package:inkspacex/ui/auth/splash_screen.dart';
import 'package:inkspacex/ui/onboarding/onboarding_page.dart';
import 'package:inkspacex/ui/app/search_page.dart';
import 'package:inkspacex/ui/app/settings.dart';
import 'package:inkspacex/ui/pages/author_profile_page.dart';
import 'package:inkspacex/ui/pages/blocked_users_page.dart';
import 'package:inkspacex/ui/pages/chat_conversation_page.dart';
import 'package:inkspacex/ui/pages/chat_list_page.dart';
import 'package:inkspacex/ui/pages/new_chat_page.dart';
import 'package:inkspacex/ui/pages/follow_list_page.dart';
import 'package:inkspacex/ui/pages/post_detail_page.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/editor_page_entry.dart';
import 'package:inkspacex/ui/pages/publish_page.dart';
import 'package:inkspacex/ui/pages/feed_preferences_page.dart';
import 'package:inkspacex/ui/pages/drafts_page.dart';
import 'package:inkspacex/ui/pages/legal_page.dart';
import 'package:inkspacex/ui/pages/merge_log_page.dart';
import 'package:inkspacex/ui/pages/follow_requests_page.dart';
import 'package:inkspacex/ui/pages/notifications_page.dart';
import 'package:inkspacex/ui/pages/bookmarks_page.dart';
import 'package:inkspacex/ui/pages/manage_downloads_page.dart';
import 'package:inkspacex/ui/pages/saved_favorites_page.dart';
import 'package:inkspacex/ui/pages/reading_statistics_page.dart';
import 'package:inkspacex/ui/pages/tag_feed_page.dart';
import 'package:inkspacex/ui/pages/shelf_all_page.dart';
import 'package:inkspacex/ui/pages/subscription_page.dart';
import 'package:inkspacex/ui/pages/create_bookshelf_page.dart';
import 'package:inkspacex/ui/pages/view_bookshelf_page.dart';
import 'package:inkspacex/ui/pages/add_books_to_shelf_page.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/models/writing_model.dart';
GoRouter createRouter(AuthProvider authProvider) {
  return GoRouter(
    refreshListenable: authProvider,
    initialLocation: '/',
    observers: [_NavigationLogger(), AnalyticsNavigatorObserver()],
    redirect: (context, state) {
      final auth = authProvider;
      final location = state.matchedLocation;
      final isAuthRoute = location == '/login' ||
          location == '/signup' ||
          location == '/forgot-password' ||
          location == '/privacy-policy' ||
          location == '/terms-of-service';

      // Auth state not yet known or restoring session → splash
      if (!auth.authStateKnown || auth.isRestoringSession) {
        // Save the intended destination before redirecting to splash
        if (location != '/splash' && location != '/' && !isAuthRoute) {
          auth.setPendingDeepLink(state.uri.toString());
        }
        return location == '/splash' ? null : '/splash';
      }

      // Not authenticated → login (unless already on an auth route)
      if (!auth.isAuthenticated) {
        if (!isAuthRoute) {
          // Web visitors landing on the root URL see the static marketing
          // page instead of the login form — native apps go straight to login.
          if (kIsWeb && location == '/') {
            web_utils.redirectToLandingPage();
            return null;
          }
          // Save the intended destination so we can redirect after login
          if (location != '/' && location != '/splash') {
            auth.setPendingDeepLink(state.uri.toString());
          }
          return '/login';
        }
        return null;
      }

      // Authenticated but onboarding incomplete → onboarding
      if (!auth.isOnboardingComplete) {
        return location == '/onboarding' ? null : '/onboarding';
      }

      // Fully authenticated — redirect away from auth/splash/onboarding pages
      // (but allow legal pages to stay accessible)
      final isLegalRoute = location == '/privacy-policy' || location == '/terms-of-service';
      if ((isAuthRoute && !isLegalRoute) || location == '/splash' || location == '/onboarding') {
        // Check if there's a pending deep link to restore
        final pendingLink = auth.consumePendingDeepLink();
        return pendingLink ?? '/';
      }

      return null;
    },
    routes: [
      // --- Auth ---
      GoRoute(
        path: '/splash',
        pageBuilder: (_, state) =>
            const NoTransitionPage(child: SplashScreen()),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (_, state) =>
            const NoTransitionPage(child: LoginPage()),
      ),
      GoRoute(
        path: '/signup',
        pageBuilder: (_, state) =>
            const NoTransitionPage(child: SignupPage()),
      ),
      GoRoute(
        path: '/forgot-password',
        pageBuilder: (_, state) =>
            const NoTransitionPage(child: ForgotPasswordPage()),
      ),
      GoRoute(path: '/onboarding', builder: (_, __) => const OnboardingPage()),

      // --- Main app ---
      GoRoute(path: '/', builder: (_, __) => const HomePage()),

      // --- Sub-pages (pushed on top) ---
      GoRoute(
        path: '/post/:id',
        pageBuilder: (_, state) {
          final extra = state.extra;
          if (extra != null) {
            final item = extra is FeedItemModel
                ? extra
                : FeedItemModel.fromJson(extra as Map<String, dynamic>);
            return CupertinoPage(child: PostDetailPage(item: item));
          }
          // Deep link: load by ID
          final id = state.pathParameters['id'] ?? '';
          return CupertinoPage(
            child: _PostLoaderPage(feedItemId: id),
          );
        },
      ),
      GoRoute(
        path: '/editor',
        pageBuilder: (_, __) => const CupertinoPage(child: EditiorPage()),
      ),
      GoRoute(
        path: '/publish',
        builder: (_, state) {
          final extra = state.extra;
          final book = extra is WritingModel
              ? extra
              : WritingModel.fromJson(extra as Map<String, dynamic>);
          return PublishPage(book: book);
        },
      ),
      GoRoute(
        path: '/profile',
        builder: (_, __) => const ProfilePage(),
      ),
      GoRoute(
        path: '/language',
        builder: (_, __) => const LanguagePage(),
      ),
      GoRoute(
        path: '/search',
        pageBuilder: (_, __) => const CupertinoPage(
          fullscreenDialog: true,
          child: SearchPage(),
        ),
      ),
      GoRoute(
        path: '/feed-preferences',
        builder: (_, __) => const FeedPreferencesPage(),
      ),
      // Explore was merged into the unified search surface — keep the
      // path for any deep links / shortcuts and redirect through.
      GoRoute(
        path: '/explore',
        redirect: (_, __) => '/search',
      ),
      GoRoute(
        path: '/u/:id',
        pageBuilder: (_, state) {
          final id = state.pathParameters['id'] ?? '';
          final extra = state.extra;
          final seed = extra is PublicUser ? extra : null;
          return CupertinoPage(
            child: AuthorProfilePage(userId: id, seed: seed),
          );
        },
      ),
      GoRoute(
        path: '/u/:id/followers',
        pageBuilder: (_, state) {
          final id = state.pathParameters['id'] ?? '';
          final extra = state.extra;
          final seed = extra is PublicUser ? extra : null;
          return CupertinoPage(
            child: FollowListPage(
              userId: id,
              mode: FollowListMode.followers,
              seed: seed,
            ),
          );
        },
      ),
      GoRoute(
        path: '/u/:id/following',
        pageBuilder: (_, state) {
          final id = state.pathParameters['id'] ?? '';
          final extra = state.extra;
          final seed = extra is PublicUser ? extra : null;
          return CupertinoPage(
            child: FollowListPage(
              userId: id,
              mode: FollowListMode.following,
              seed: seed,
            ),
          );
        },
      ),
      GoRoute(
        path: '/tag-feed/:kind/:value',
        pageBuilder: (_, state) {
          final rawKind = state.pathParameters['kind'] ?? 'tag';
          final value = Uri.decodeComponent(state.pathParameters['value'] ?? '');
          final kind = switch (rawKind) {
            'genre' => TagFeedKind.genre,
            'type' => TagFeedKind.writingType,
            _ => TagFeedKind.tag,
          };
          return CupertinoPage(
            child: TagFeedPage(kind: kind, value: value),
          );
        },
      ),
      GoRoute(
        path: '/shelf/:railId',
        pageBuilder: (_, state) {
          final railId = state.pathParameters['railId'] ?? '';
          final title =
              Uri.decodeComponent(state.uri.queryParameters['title'] ?? '');
          return CupertinoPage(
            child: ShelfAllPage(railId: railId, title: title),
          );
        },
      ),
      GoRoute(
        path: '/notifications',
        pageBuilder: (_, __) => const CupertinoPage(
          child: NotificationsPage(),
        ),
      ),
      GoRoute(
        path: '/follow-requests',
        pageBuilder: (_, __) => const CupertinoPage(
          child: FollowRequestsPage(),
        ),
      ),
      GoRoute(
        path: '/chats',
        pageBuilder: (_, __) => const CupertinoPage(
          child: ChatListPage(),
        ),
      ),
      GoRoute(
        path: '/chat/new',
        pageBuilder: (_, __) => const CupertinoPage(
          fullscreenDialog: true,
          child: NewChatPage(),
        ),
      ),
      GoRoute(
        path: '/chat/:userId',
        pageBuilder: (_, state) {
          final userId = state.pathParameters['userId'] ?? '';
          return CupertinoPage(
            child: ChatConversationPage(otherUserId: userId),
          );
        },
      ),
      GoRoute(
        path: '/blocked',
        pageBuilder: (_, __) => const CupertinoPage(
          child: BlockedUsersPage(),
        ),
      ),
      GoRoute(
        path: '/drafts',
        builder: (_, __) => const DraftsPage(),
      ),
      GoRoute(
        path: '/saved',
        builder: (_, __) => const SavedFavoritesPage(type: CollectionType.saved),
      ),
      GoRoute(
        path: '/favorites',
        builder: (_, __) => const SavedFavoritesPage(type: CollectionType.favorites),
      ),
      GoRoute(
        path: '/bookmarks',
        pageBuilder: (_, __) =>
            const CupertinoPage(child: BookmarksPage()),
      ),
      GoRoute(
        path: '/manage-downloads',
        pageBuilder: (_, __) =>
            const CupertinoPage(child: ManageDownloadsPage()),
      ),
      GoRoute(
        path: '/reading-statistics',
        builder: (_, __) => const ReadingStatisticsPage(),
      ),
      GoRoute(
        path: '/subscription',
        builder: (_, __) => const SubscriptionPage(),
      ),
      GoRoute(
        path: '/bookshelf/new',
        builder: (_, __) => const CreateBookshelfPage(),
      ),
      GoRoute(
        path: '/bookshelf/:id',
        builder: (_, state) => ViewBookshelfPage(
          bookshelfId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/bookshelf/:id/add',
        builder: (_, state) => AddBooksToShelfPage(
          bookshelfId: state.pathParameters['id'] ?? '',
        ),
      ),
      GoRoute(
        path: '/settings-detail',
        builder: (_, __) => Scaffold(
          appBar: AppBar(
            title: const Text('Settings'),
            centerTitle: true,
          ),
          body: const SafeArea(child: SettingsPage()),
        ),
      ),
      GoRoute(
        path: '/debug/merge-log',
        builder: (_, __) => const MergeLogPage(),
      ),
      GoRoute(
        path: '/privacy-policy',
        builder: (_, __) => LegalPage.privacyPolicy(),
      ),
      GoRoute(
        path: '/terms-of-service',
        builder: (_, __) => LegalPage.termsOfService(),
      ),
    ],
  );
}

/// Deep-link loader: fetches a post by ID and shows PostDetailPage.
class _PostLoaderPage extends StatefulWidget {
  final String feedItemId;
  const _PostLoaderPage({required this.feedItemId});

  @override
  State<_PostLoaderPage> createState() => _PostLoaderPageState();
}

class _PostLoaderPageState extends State<_PostLoaderPage> {
  FeedItemModel? _item;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final item = await context.read<AuthProvider>().dataService.getFeedItem(widget.feedItemId);
      if (mounted) {
        if (item != null) {
          setState(() {
            _item = item;
            _loading = false;
          });
        } else {
          setState(() {
            _error = 'Post not found';
            _loading = false;
          });
        }
      }
    } on FeedItemMissing {
      // Card was hard-deleted server-side (the writings -> feed_items
      // FK cascaded). Prune any cached copy so a back-navigation
      // won't paint it again, then surface a clean not-found state.
      if (!mounted) return;
      context.read<FeedProvider>().dropMissingItem(widget.feedItemId);
      setState(() {
        _error = 'Post not found';
        _loading = false;
      });
    } catch (e) {
      if (mounted) setState(() {
        _error = 'Failed to load post';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: AppSpinner()),
      );
    }
    if (_item != null) {
      return PostDetailPage(item: _item!);
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Post')),
      body: Center(
        child: Text(_error ?? 'Something went wrong'),
      ),
    );
  }
}

/// NavigatorObserver that logs every route change so DevTools shows a user's
/// path through the app.
class _NavigationLogger extends NavigatorObserver {
  String _name(Route<dynamic>? route) =>
      route?.settings.name ?? route?.settings.arguments?.toString() ?? '<anon>';

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    log.i('[nav] push: ${_name(previousRoute)} → ${_name(route)}');
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    log.i('[nav] pop: ${_name(route)} → ${_name(previousRoute)}');
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    log.i('[nav] replace: ${_name(oldRoute)} → ${_name(newRoute)}');
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    log.i('[nav] remove: ${_name(route)}');
  }
}
