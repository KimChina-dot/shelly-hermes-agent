import 'package:flutter/material.dart';

import '../tokens.dart';

/// Agent avatar with the brand blue→violet gradient and an optional soft
/// outer glow. Sizes come in named steps so every surface (top bar, chat
/// bubble, approval screen) shares one visual identity.
class GradientAvatar extends StatelessWidget {
  const GradientAvatar({
    super.key,
    this.size = AvatarSize.medium,
    this.glow = false,
  });

  final AvatarSize size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final semantic = Theme.of(context).extension<AppSemanticColors>()!;
    final double diameter = switch (size) {
      AvatarSize.small => 24,
      AvatarSize.medium => 32,
      AvatarSize.large => 44,
    };

    final avatar = Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(diameter / 2),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: AppColors.brandGradient,
        ),
      ),
      child: Center(
        child: _Glyph(diameter: diameter, textPrimary: semantic.textPrimary),
      ),
    );

    if (!glow) return avatar;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(diameter / 2),
        boxShadow: [
          BoxShadow(
            color: AppColors.brandBlue.withValues(alpha: 0.35),
            blurRadius: diameter * 0.6,
            spreadRadius: 0,
          ),
        ],
      ),
      child: avatar,
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph({required this.diameter, required this.textPrimary});

  final double diameter;
  final Color textPrimary;

  @override
  Widget build(BuildContext context) {
    if (diameter >= 40) {
      return _OrbitGlyph(color: textPrimary, size: diameter * 0.55);
    }
    return Container(
      width: diameter * 0.28,
      height: diameter * 0.28,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(diameter),
        color: textPrimary.withValues(alpha: 0.9),
      ),
    );
  }
}

/// A small orbital mark: a ring with an orbiting dot, drawn with CustomPaint.
/// Used as the Shelly logogram on large avatars and loading states.
class _OrbitGlyph extends StatelessWidget {
  const _OrbitGlyph({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.square(size), painter: _OrbitPainter(color: color));
  }
}

class _OrbitPainter extends CustomPainter {
  const _OrbitPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.32;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.07
      ..color = color;
    canvas.drawCircle(center, radius, ring);
    final dot = Paint()..color = color;
    canvas.drawCircle(
      Offset(center.dx + radius, center.dy),
      size.width * 0.10,
      dot,
    );
  }

  @override
  bool shouldRepaint(_OrbitPainter oldDelegate) => oldDelegate.color != color;
}

enum AvatarSize { small, medium, large }
