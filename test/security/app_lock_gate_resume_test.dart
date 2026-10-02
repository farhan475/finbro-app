import 'dart:async';

import 'package:finbro_app/app/theme/app_theme.dart';
import 'package:finbro_app/core/database/app_database.dart';
import 'package:finbro_app/core/providers.dart';
import 'package:finbro_app/features/security/domain/app_lock_service.dart';
import 'package:finbro_app/features/security/presentation/app_lock_gate.dart';
import 'package:finbro_app/features/security/presentation/lock_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

// Own file: the gate's relock timer is process-wide and must start on the
// mocked device clock below.
void main() {
  testWidgets('resume keeps the content covered until the device clock decides', (tester) async {
    const channel = MethodChannel('id.finbro.app/clock');
    var elapsedMs = 3 * 60 * 60 * 1000;
    Completer<void>? hold;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      final h = hold;
      if (h != null) await h.future;
      return {'elapsedRealtime': elapsedMs, 'bootCount': 7};
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final db = AppDatabase.memory();
    addTearDown(db.close);
    final pinEnabled = ValueNotifier(false);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        appLockConfigProvider.overrideWith((ref) {
          void changed() => ref.invalidateSelf();
          pinEnabled.addListener(changed);
          ref.onDispose(() => pinEnabled.removeListener(changed));
          return AppLockConfig(pinEnabled: pinEnabled.value, biometricEnabled: false, timeoutSeconds: 60);
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: const Scaffold(body: Text('home')),
        builder: (context, child) => AppLockGate(child: child!),
      ),
    ));
    // Unlocked session (no PIN at start), then a PIN is enabled.
    pinEnabled.value = true;
    await tester.pumpAndSettle();

    final cover = find.byKey(AppLockGate.pendingCoverKey);
    final content = find.text('home').hitTestable();
    Future<void> leaveAndReturn() async {
      for (final state in const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
    }

    // Away 30 s (< 60 s timeout): covered while the reading is pending, then
    // the content comes back without the lock screen.
    hold = Completer();
    await leaveAndReturn();
    expect(cover, findsOneWidget);
    expect(content, findsNothing);
    expect(find.byType(LockScreen), findsNothing);
    expect(await tester.binding.handlePopRoute(), isTrue, reason: 'back is blocked while covered');
    elapsedMs += 30 * 1000;
    hold.complete();
    hold = null;
    await tester.pumpAndSettle();
    expect(cover, findsNothing);
    expect(find.byType(LockScreen), findsNothing);
    expect(content, findsOneWidget);

    // Away 1 s on the stopwatch and wall clock, but the device slept for an
    // hour: covered, then locked; the content never shows in between.
    hold = Completer();
    await leaveAndReturn();
    expect(cover, findsOneWidget);
    expect(content, findsNothing);
    elapsedMs += 60 * 60 * 1000;
    hold.complete();
    hold = null;
    await tester.pumpAndSettle();
    expect(find.byType(LockScreen), findsOneWidget);
    expect(cover, findsNothing);
    expect(content, findsNothing);
  });
}
