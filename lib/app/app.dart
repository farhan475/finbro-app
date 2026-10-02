import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/notifications/notification_service.dart';
import '../core/providers.dart';
import '../core/settings/app_settings_repository.dart';
import '../core/utilities/app_logger.dart';
import '../features/security/presentation/app_lock_gate.dart';
import '../features/recurring/recurring_routes.dart' show recurringInstancePath;
import 'app_wiring.dart';
import 'router.dart';
import 'routes.dart';
import 'theme/app_theme.dart';

/// Notification taps are pushed here by main() and routed by [_Bootstrap].
final notificationEvents = StreamController<NotificationEvent>.broadcast();

class FinBroApp extends ConsumerWidget {
  const FinBroApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loaded = ref.watch(appSettingsProvider.select((s) => s.hasValue));
    if (!loaded) {
      return const ColoredBox(color: Color(0xFF0B0B0B));
    }
    return MaterialApp.router(
      title: 'FinBro',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      routerConfig: ref.watch(routerProvider),
      locale: const Locale('id', 'ID'),
      supportedLocales: const [Locale('id', 'ID'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => _Bootstrap(child: AppLockGate(child: child!)),
    );
  }
}

/// Runs lifecycle tasks on start/resume and routes notification events.
class _Bootstrap extends ConsumerStatefulWidget {
  const _Bootstrap({required this.child});
  final Widget child;

  @override
  ConsumerState<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends ConsumerState<_Bootstrap> with WidgetsBindingObserver {
  StreamSubscription<NotificationEvent>? _sub;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = notificationEvents.stream.listen(_route);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _runLifecycle();
      await NotificationService.instance.initialized;
      if (!mounted) return;
      final launch = NotificationService.instance.takeLaunchEvent();
      if (launch != null) _route(launch);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _runLifecycle();
  }

  Future<void> _runLifecycle() async {
    if (_running) return;
    _running = true;
    try {
      // Scheduling and pending-request diffs need the initialized plugin.
      await NotificationService.instance.initialized;
      if (!mounted) return;
      final now = ref.read(clockProvider)();
      for (final task in ref.read(lifecycleTasksProvider)) {
        try {
          await task(now);
        } catch (e, s) {
          AppLogger.error('Lifecycle task gagal', e, s);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _route(NotificationEvent e) async {
    final router = ref.read(routerProvider);
    switch (e.kind) {
      case NotificationKind.dailyCheck:
        final day = DateTime.parse(e.data['date'] as String);
        if (e.actionId == NotificationAction.noTransaction) {
          await markNoActivity(ref.read(databaseProvider), day);
        } else if (e.actionId == NotificationAction.remindLater) {
          await scheduleRemindLater(day);
        } else {
          router.push(Routes.transactionNew());
        }
      case NotificationKind.budget:
        router.go(Routes.budget);
      case NotificationKind.recurring:
        final instanceId = e.data['instanceId'] as String?;
        router.push(instanceId == null ? Routes.recurring : recurringInstancePath(instanceId));
      case NotificationKind.monthlyReview:
        router.go(Routes.reports);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
