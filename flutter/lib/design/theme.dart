import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds the Shelly Hermes dark or light [ThemeData].
///
/// Dark is the first-class mode: three-layer deep grays, hairline borders
/// instead of shadows, and the brand gradient reserved for accent moments.
ThemeData buildShellyTheme(Brightness brightness) {
  final semantic =
      brightness == Brightness.dark ? AppSemanticColors.dark : AppSemanticColors.light;

  final colorScheme = ColorScheme(
    brightness: brightness,
    primary: AppColors.brandBlue,
    onPrimary: Colors.white,
    secondary: AppColors.brandViolet,
    onSecondary: Colors.white,
    error: AppColors.danger,
    onError: Colors.black,
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
        fontSize: 17,
        fontWeight: FontWeight.w600,
        color: semantic.textPrimary,
      ),
      iconTheme: IconThemeData(color: semantic.textPrimary),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: semantic.background,
      surfaceTintColor: Colors.transparent,
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
    dividerTheme: DividerThemeData(color: semantic.border, thickness: 1, space: 1),
    splashColor: Colors.white.withValues(alpha: 0.04),
    highlightColor: Colors.white.withValues(alpha: 0.03),
    textTheme: base.textTheme.apply(
      bodyColor: semantic.textPrimary,
      displayColor: semantic.textPrimary,
    ),
  );
}
