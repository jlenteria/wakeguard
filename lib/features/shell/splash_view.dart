import 'package:flutter/material.dart';

import '../../shared/brand.dart';
import '../../shared/theme.dart';

/// Shown while settings load: the emblem, the promise, and an offline badge.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final tokens = WakeTokens.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    // Design 'secondary-fixed-dim' (#00dce6) in dark mode.
    final cyanDim = light ? scheme.secondary : const Color(0xff00dce6);
    return Scaffold(
      backgroundColor: scheme.surface,
      body: LayoutBuilder(
        builder: (context, constraints) => Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Positioned(
              top: -128 - 80,
              left: -80 - 80,
              child: _Aura(
                color: tokens.dawn.withValues(alpha: 0.10),
                size: 480,
              ),
            ),
            Positioned(
              top: constraints.maxHeight / 3 - 88,
              right: -96 - 88,
              child: _Aura(
                color: tokens.cyan.withValues(alpha: 0.10),
                size: 528,
              ),
            ),
            Positioned(
              bottom: -96 - 96,
              left: (constraints.maxWidth - 576) / 2,
              child: _Aura(
                color: tokens.cta.withValues(alpha: 0.05),
                size: 576,
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 36, 20, 40),
                child: Column(
                  children: [
                    Opacity(
                      opacity: 0.8,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8,
                                    vertical: 4,
                                  ),
                                  decoration: ShapeDecoration(
                                    color: scheme.surfaceContainerHigh
                                        .withValues(alpha: 0.6),
                                    shape: const StadiumBorder(),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      StatusDot(color: cyanDim),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          'VIGILANCE GUARD ACTIVE',
                                          overflow: TextOverflow.ellipsis,
                                          style: text.labelSmall?.copyWith(
                                            color: cyanDim,
                                            letterSpacing: 0.55,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              Icons.shield_outlined,
                              size: 15,
                              color: scheme.tertiary,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Safe Mode',
                              style: text.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 384),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        child: Column(
                          children: [
                            Container(
                              width: 144,
                              height: 144,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: scheme.surfaceContainerHigh.withValues(
                                  alpha: 0.8,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: tokens.dawn.withValues(alpha: 0.22),
                                    offset: const Offset(-10, 10),
                                    blurRadius: 40,
                                    spreadRadius: 4,
                                  ),
                                  BoxShadow(
                                    color: tokens.cyan.withValues(alpha: 0.22),
                                    offset: const Offset(10, -10),
                                    blurRadius: 40,
                                    spreadRadius: 4,
                                  ),
                                  const BoxShadow(
                                    color: Color(0x40000000),
                                    offset: Offset(0, 25),
                                    blurRadius: 50,
                                    spreadRadius: -12,
                                  ),
                                ],
                              ),
                              child: const WakeGuardLogo(size: 120),
                            ),
                            const SizedBox(height: 24),
                            Text.rich(
                              TextSpan(
                                children: [
                                  const TextSpan(text: 'Wake'),
                                  const WidgetSpan(child: SizedBox(width: 4)),
                                  TextSpan(
                                    text: 'Guard',
                                    style: TextStyle(color: tokens.cta),
                                  ),
                                ],
                              ),
                              textAlign: TextAlign.center,
                              style: text.headlineMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.65,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Defend Your Morning',
                              textAlign: TextAlign.center,
                              style: text.titleMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 6,
                              ),
                              decoration: ShapeDecoration(
                                color: scheme.surfaceContainer.withValues(
                                  alpha: 0.7,
                                ),
                                shape: const StadiumBorder(),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.bolt, size: 16, color: cyanDim),
                                  const SizedBox(width: 4),
                                  Flexible(
                                    child: Text(
                                      'Cognitive Awakening Ready',
                                      style: text.bodySmall?.copyWith(
                                        color: scheme.onSurface,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Spacer(),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Column(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 6,
                            ),
                            decoration: ShapeDecoration(
                              color: scheme.surfaceContainerLow.withValues(
                                alpha: 0.9,
                              ),
                              shape: const StadiumBorder(),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.verified_user_outlined,
                                  size: 14,
                                  color: cyanDim,
                                ),
                                const SizedBox(width: 6),
                                Flexible(
                                  child: Text(
                                    '100% Offline • Private • Zero Accounts',
                                    style: text.labelSmall?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                      fontWeight: FontWeight.w500,
                                      letterSpacing: 0.275,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            width: 192,
                            child: Column(
                              children: [
                                Container(
                                  height: 4,
                                  decoration: ShapeDecoration(
                                    shape: const StadiumBorder(),
                                    gradient: LinearGradient(
                                      colors: [
                                        tokens.cta,
                                        scheme.tertiary,
                                        tokens.cyan,
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      'CALIBRATING',
                                      style: text.labelSmall?.copyWith(
                                        fontSize: 10,
                                        letterSpacing: 0.5,
                                        color: scheme.onSurfaceVariant
                                            .withValues(alpha: 0.7),
                                      ),
                                    ),
                                    Text(
                                      'READY',
                                      style: text.labelSmall?.copyWith(
                                        fontSize: 10,
                                        letterSpacing: 0.5,
                                        color: cyanDim,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A soft blurred light pool behind the splash content.
class _Aura extends StatelessWidget {
  const _Aura({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
      ),
    ),
  );
}
