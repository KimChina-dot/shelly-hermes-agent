import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the Shelly Hermes light or dark [ThemeData].
///
/// PHASE 44: light is the first-class mode — cool gray canvas, white cards
/// with soft ambient shadows, ink accent for primary actions, hairline
/// borders. Dark remains fully themed with the original deep-gray layers.
ThemeData buildShellyTheme(Brightness brightness) {
  final semantic =
      brightness == Brightness.dark ? AppSemanticColors.dark : AppSemanticColors.light;
  final isLight = brightness == Brightness.light;

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: semantic.accent,
    onPrimary: semantic.onAccent,
    secondary: AppColors.brandViolet,
    onSecondary: Colors.white,
    error: semantic.danger,
    onError: Colors.white,
    surface: semantic.card,
    onSurface: semantic.textPrimary,
    surfaceContainerHighest: semantic.floating,
    onSurfaceVariant: semantic.textSecondary,
    outline: semantic.border,
    outlineVariant: semantic.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: semantic.background,
    splashFactory: InkSparkle.splashFactory,
    fontFamily: 'sans-serif',
  );

  return base.copyWith(
    extensions: [semantic],
    appBarTheme: AppBarTheme(
      backgroundColor: semantic.background,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: semantic.textPrimary,
      ),
      iconTheme: IconThemeData(color: semantic.textPrimary),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: isLight ? semantic.card : semantic.background,
      surfaceTintColor: Colors.transparent,
      elevation: isLight ? 1 : 0,
      indicatorColor: semantic.floating,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return IconThemeData(
          size: 24,
          color: selected ? semantic.textPrimary : semantic.textTertiary,
        );
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return TextStyle(
          fontSize: 11,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected ? semantic.textPrimary : semantic.textTertiary,
        );
      }),
    ),
    cardTheme: CardThemeData(
      color: semantic.card,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: BorderSide(color: semantic.border),
      ),
      margin: EdgeInsets.zero,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: semantic.accent,
        foregroundColor: semantic.onAccent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        animationDuration: AppMotion.fast,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: semantic.textPrimary,
        side: BorderSide(color: semantic.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        animationDuration: AppMotion.fast,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: semantic.floating,
      hintStyle: TextStyle(color: semantic.textTertiary),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: semantic.textSecondary, width: 1.2),
      ),
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.disabled)) return semantic.textTertiary;
        return semantic.card;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return semantic.accent;
        return semantic.floating;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : semantic.border,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: semantic.floating,
      selectedColor: semantic.accent,
      labelStyle: TextStyle(color: semantic.textPrimary, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: semantic.onAccent, fontSize: 13),
      side: BorderSide.none,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: semantic.card,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: semantic.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      showDragHandle: true,
      dragHandleColor: semantic.border,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: semantic.card,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
    ),
    dividerTheme: DividerThemeData(color: semantic.border, thickness: 1, space: 1),
    // Ripple tint follows the brightness: ink on the light canvas,
    // white on the dark canvas (an ink ripple is invisible in dark).
    splashColor: isLight
        ? const Color(0xFF1D1D1F).withValues(alpha: 0.04)
        : Colors.white.withValues(alpha: 0.06),
    highlightColor: isLight
        ? const Color(0xFF1D1D1F).withValues(alpha: 0.03)
        : Colors.white.withValues(alpha: 0.05),
    textTheme: base.textTheme.apply(
      bodyColor: semantic.textPrimary,
      displayColor: semantic.textPrimary,
    ),
  );
}
