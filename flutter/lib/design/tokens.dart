import 'package:flutter/material.dart';

/// Shelly Hermes design tokens.
///
/// The palette is intentionally layered: three deep grays carry the dark UI
/// (background / card / floating), and a blue→violet brand gradient provides
/// the single accent voice used by avatars, primary actions and loading states.
abstract final class AppColors {
  // Brand gradient (identical in both modes).
  static const Color brandBlue = Color(0xFF3B82F6);
  static const Color brandViolet = Color(0xFF8B5CF6);
  static const List<Color> brandGradient = [brandBlue, brandViolet];

  // Status.
  static const Color success = Color(0xFF34D399);
  static const Color warning = Color(0xFFFBBF24);
  static const Color danger = Color(0xFFF87171);

  // Dark (first-class mode).
  static const Color darkBackground = Color(0xFF0A0A0B);
  static const Color darkCard = Color(0xFF141416);
  static const Color darkFloating = Color(0xFF1E1E21);
  static const Color darkBorder = Color(0xFF26262B);
  static const Color darkTextPrimary = Color(0xFFF2F2F7);
  static const Color darkTextSecondary = Color(0xFFA0A0AA);
  static const Color darkTextTertiary = Color(0xFF6B6B74);

  // Light.
  static const Color lightBackground = Color(0xFFFAFAFB);
  static const Color lightCard = Color(0xFFFFFFFF);
  static const Color lightFloating = Color(0xFFF1F1F4);
  static const Color lightBorder = Color(0xFFE6E6EC);
  static const Color lightTextPrimary = Color(0xFF17171C);
  static const Color lightTextSecondary = Color(0xFF5C5C66);
  static const Color lightTextTertiary = Color(0xFF9A9AA5);
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double pill = 999;
}

abstract final class AppMotion {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);
  static const Curve easeOut = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutBack;
  static const Curve standard = Curves.easeInOutCubic;
}

/// Semantic palette resolved per brightness; UI code reads colors from here
/// (via the theme extension) instead of hard-coding dark or light values.
@immutable
class AppSemanticColors extends ThemeExtension<AppSemanticColors> {
  const AppSemanticColors({
    required this.background,
    required this.card,
    required this.floating,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.brandGradient,
  });

  final Color background;
  final Color card;
  final Color floating;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;
  final List<Color> brandGradient;

  static const dark = AppSemanticColors(
    background: AppColors.darkBackground,
    card: AppColors.darkCard,
    floating: AppColors.darkFloating,
    border: AppColors.darkBorder,
    textPrimary: AppColors.darkTextPrimary,
    textSecondary: AppColors.darkTextSecondary,
    textTertiary: AppColors.darkTextTertiary,
    brandGradient: AppColors.brandGradient,
  );

  static const light = AppSemanticColors(
    background: AppColors.lightBackground,
    card: AppColors.lightCard,
    floating: AppColors.lightFloating,
    border: AppColors.lightBorder,
    textPrimary: AppColors.lightTextPrimary,
    textSecondary: AppColors.lightTextSecondary,
    textTertiary: AppColors.lightTextTertiary,
    brandGradient: AppColors.brandGradient,
  );

  @override
  AppSemanticColors copyWith({
    Color? background,
    Color? card,
    Color? floating,
    Color? border,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    List<Color>? brandGradient,
  }) {
    return AppSemanticColors(
      background: background ?? this.background,
      card: card ?? this.card,
      floating: floating ?? this.floating,
      border: border ?? this.border,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      brandGradient: brandGradient ?? this.brandGradient,
    );
  }

  @override
  AppSemanticColors lerp(ThemeExtension<AppSemanticColors>? other, double t) {
    if (other is! AppSemanticColors) return this;
    return AppSemanticColors(
      background: Color.lerp(background, other.background, t)!,
      card: Color.lerp(card, other.card, t)!,
      floating: Color.lerp(floating, other.floating, t)!,
      border: Color.lerp(border, other.border, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      brandGradient: List.generate(
        brandGradient.length,
        (i) => Color.lerp(brandGradient[i], other.brandGradient[i], t)!,
      ),
    );
  }
}
