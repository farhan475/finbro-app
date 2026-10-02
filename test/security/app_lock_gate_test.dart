import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/features/security/domain/app_lock_service.dart';
import 'package:finbro_app/features/security/presentation/app_lock_gate.dart';
import 'package:finbro_app/features/security/presentation/lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('relocking on resume blocks focus and the back button beneath the lock', (tester) async {
    final db = AppDatabase.memory();
    addTearDown(db.close);
    final pinEnabled = ValueNotifier(false);
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('home'))),
      GoRoute(path: '/form', builder: (_, _) => const Scaffold(body: TextField(autofocus: true))),
    ]);
    addTearDown(router.dispose);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appLockConfigProvider.overrideWith((ref) {
          void changed() => ref.invalidateSelf();
          pinEnabled.addListener(changed);
          ref.onDispose(() => pinEnabled.removeListener(changed));
          return AppLockConfig(pinEnabled: pinEnabled.value, biometricEnabled: false, timeoutSeconds: 0);
        }),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light),
        routerConfig: router,
        builder: (context, child) => AppLockGate(child: child!),
      ),
    ));
    // No PIN yet: the session is unlocked and back navigates normally.
    router.push('/form');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);

    // Enabling a PIN keeps the session unlocked.
    pinEnabled.value = true;
    router.push('/form');
    await tester.pumpAndSettle();
    final field = tester.widget<EditableText>(find.byType(EditableText));
    expect(field.focusNode.hasFocus, isTrue);
    expect(find.byType(LockScreen), findsNothing);

    // Background and resume with a zero timeout: the app locks.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pump();
    expect(find.byType(LockScreen), findsOneWidget);
    expect(field.focusNode.hasFocus, isFalse);
    expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNull);

    // Back while locked must not pop the form hidden under the lock screen.
    expect(await tester.binding.handlePopRoute(), isTrue);
    await tester.pumpAndSettle();
    expect(router.state.matchedLocation, '/form');
    expect(find.byType(LockScreen), findsOneWidget);
  });
}
