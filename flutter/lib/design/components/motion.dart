import 'package:flutter/material.dart';

import '../tokens.dart';

/// Generic entrance: fade + 8px rise over [AppMotion.normal] with the
/// emphasized curve. Wrap any widget that should announce its arrival —
/// messages, cards, section blocks.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.offset = 8,
  });

  final Widget child;
  final Duration delay;

  /// Vertical offset the child starts from (px).
  final double offset;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
  );
  late final Animation<double> _fade =
      CurvedAnimation(parent: _controller, curve: AppMotion.easeOut);
  late final Animation<double> _slide = Tween<double>(
    begin: widget.offset,
    end: 0,
  ).animate(CurvedAnimation(parent: _controller, curve: AppMotion.emphasized));

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: AnimatedBuilder(
        animation: _slide,
        builder: (context, child) =>
            Transform.translate(offset: Offset(0, _slide.value), child: child),
        child: widget.child,
      ),
    );
  }
}

/// List cascade entrance: wraps [FadeSlideIn] with the 40ms stagger token.
/// Pass the item's index; items beyond [AppMotion.staggerMaxItems] enter
/// without extra delay so long lists don't feel sluggish.
class StaggerIn extends StatelessWidget {
  const StaggerIn({super.key, required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final slot = index.clamp(0, AppMotion.staggerMaxItems - 1);
    return FadeSlideIn(
      delay: AppMotion.staggerInterval * slot,
      child: child,
    );
  }
}

/// "Thinking" indicator: three dots pulsing in sequence. The only looping
/// animation allowed by the motion discipline — it conveys active state,
/// not decoration.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key, this.color, this.dotSize = 6});

  final Color? color;
  final double dotSize;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        widget.color ?? Theme.of(context).extension<AppSemanticColors>()!.textTertiary;
    Widget dot(int index) {
      final delay = index * 0.18;
      return FadeTransition(
        opacity: TweenSequence<double>([
          TweenSequenceItem(
            tween: Tween(begin: 0.35, end: 1.0)
                .chain(CurveTransformer(curve: Curves.easeOut)),
            weight: 33,
          ),
          TweenSequenceItem(
            tween: Tween(begin: 1.0, end: 0.35)
                .chain(CurveTransformer(curve: Curves.easeIn)),
            weight: 67,
          ),
        ]).animate(
          CurvedAnimation(
            parent: _controller,
            curve: Interval(delay, (delay + 0.5).clamp(0.0, 1.0)),
          ),
        ),
        child: Container(
          width: widget.dotSize,
          height: widget.dotSize,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [dot(0), dot(1), dot(2)],
    );
  }
}

/// Curve adapter so [TweenSequence] items can apply easing.
class CurveTransformer extends Animatable<double> {
  CurveTransformer({this.curve = Curves.linear});

  final Curve curve;

  @override
  double transform(double t) => curve.transform(t.clamp(0.0, 1.0));
}
