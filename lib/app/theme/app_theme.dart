import 'package:flutter/material.dart';

/// Semantic palette from 06-ux-ui-spec.md. Primary stays monochrome; the
/// semantic colors are reserved for state/data.
@immutable
class FinColors extends ThemeExtension<FinColors> {
  const FinColors({
    required this.background,
    required this.surface,
    required this.surface2,
    required this.text,
    required this.muted,
    required this.border,
    required this.primary,
    required this.onPrimary,
    required this.positive,
    required this.negative,
    required this.warning,
    required this.chart,
  });

  final Color background;
  final Color surface;
  final Color surface2;
  final Color text;
  final Color muted;
  final Color border;
  final Color primary;
  final Color onPrimary;
  final Color positive;
  final Color negative;
  final Color warning;

  /// Monochrome ramp for chart series (largest share first).
  final List<Color> chart;

  static const light = FinColors(
    background: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    surface2: Color(0xFFF1F2F4),
    text: Color(0xFF111111),
    muted: Color(0xFF667085),
    border: Color(0xFFE5E7EB),
    primary: Color(0xFF111111),
    onPrimary: Color(0xFFFFFFFF),
    positive: Color(0xFF15803D),
    negative: Color(0xFFB91C1C),
    warning: Color(0xFFB45309),
    chart: [
      Color(0xFF111111),
      Color(0xFF4B5563),
      Color(0xFF9CA3AF),
      Color(0xFFD1D5DB),
      Color(0xFFE5E7EB),
    ],
  );

  static const dark = FinColors(
    background: Color(0xFF0B0B0B),
    surface: Color(0xFF141414),
    surface2: Color(0xFF1C1C1C),
    text: Color(0xFFF5F5F5),
    muted: Color(0xFFA1A1AA),
    border: Color(0xFF2A2A2A),
    primary: Color(0xFFFFFFFF),
    onPrimary: Color(0xFF0B0B0B),
    positive: Color(0xFF4ADE80),
    negative: Color(0xFFF87171),
    warning: Color(0xFFFBBF24),
    chart: [
      Color(0xFFF5F5F5),
      Color(0xFFA1A1AA),
      Color(0xFF71717A),
      Color(0xFF52525B),
      Color(0xFF3F3F46),
    ],
  );

  @override
  FinColors copyWith() => this;

  @override
  FinColors lerp(FinColors? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension FinThemeX on BuildContext {
  FinColors get fin => Theme.of(this).extension<FinColors>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

abstract final class AppRadius {
  static const card = 18.0;
  static const input = 14.0;
  static const button = 14.0;
}

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? FinColors.light : FinColors.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.primary,
    onPrimary: c.onPrimary,
    secondary: c.primary,
    onSecondary: c.onPrimary,
    error: c.negative,
    onError: c.onPrimary,
    surface: c.surface,
    onSurface: c.text,
    onSurfaceVariant: c.muted,
    outline: c.border,
    outlineVariant: c.border,
    surfaceContainerLowest: c.surface,
    surfaceContainerLow: c.surface,
    surfaceContainer: c.surface2,
    surfaceContainerHigh: c.surface2,
    surfaceContainerHighest: c.surface2,
  );

  const base = TextTheme(
    displaySmall: TextStyle(fontSize: 34, fontWeight: FontWeight.w700, letterSpacing: -0.8, height: 1.1),
    headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4),
    titleLarge: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2),
    titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    titleSmall: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    bodyLarge: TextStyle(fontSize: 16, fontWeight: FontWeight.w400),
    bodyMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
    bodySmall: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w400),
    labelLarge: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
    labelMedium: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
    labelSmall: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
  );
  final textTheme = base.apply(
    fontFamily: 'Inter',
    bodyColor: c.text,
    displayColor: c.text,
  ).copyWith(
    bodySmall: base.bodySmall!.copyWith(color: c.muted, fontFamily: 'Inter'),
    labelSmall: base.labelSmall!.copyWith(color: c.muted, fontFamily: 'Inter'),
  );

  final inputBorder = OutlineInputBorder(
    borderRadius: BorderRadius.circular(AppRadius.input),
    borderSide: BorderSide(color: c.border),
  );
  final buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(AppRadius.button),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    fontFamily: 'Inter',
    textTheme: textTheme,
    scaffoldBackgroundColor: c.background,
    extensions: [c],
    appBarTheme: AppBarTheme(
      backgroundColor: c.background,
      foregroundColor: c.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: c.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.border, thickness: 1, space: 1),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: inputBorder,
      enabledBorder: inputBorder,
      focusedBorder: inputBorder.copyWith(
        borderSide: BorderSide(color: c.primary, width: 1.5),
      ),
      errorBorder: inputBorder.copyWith(borderSide: BorderSide(color: c.negative)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      labelStyle: TextStyle(color: c.muted),
      hintStyle: TextStyle(color: c.muted),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.primary,
        foregroundColor: c.onPrimary,
        minimumSize: const Size(64, 52),
        shape: buttonShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.text,
        minimumSize: const Size(64, 52),
        side: BorderSide(color: c.border),
        shape: buttonShape,
        textStyle: textTheme.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: c.text, shape: buttonShape),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: c.primary,
      foregroundColor: c.onPrimary,
      elevation: 0,
      // Stadium = circle for the square FAB, pill for FloatingActionButton.extended.
      shape: const StadiumBorder(),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: c.surface,
      selectedColor: c.primary,
      side: BorderSide(color: c.border),
      labelStyle: textTheme.labelMedium,
      secondaryLabelStyle: textTheme.labelMedium!.copyWith(color: c.onPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      showCheckmark: false,
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: c.surface,
      indicatorColor: c.surface2,
      elevation: 0,
      height: 68,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => textTheme.labelSmall!.copyWith(
          color: s.contains(WidgetState.selected) ? c.text : c.muted,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(
          color: s.contains(WidgetState.selected) ? c.text : c.muted,
          size: 22,
        ),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.card)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.primary,
      contentTextStyle: textTheme.bodyMedium!.copyWith(color: c.onPrimary),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: c.primary,
        selectedForegroundColor: c.onPrimary,
        side: BorderSide(color: c.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.primary,
      linearTrackColor: c.surface2,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.onPrimary : c.muted,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? c.primary : c.surface2,
      ),
      trackOutlineColor: WidgetStateProperty.all(c.border),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
