import 'package:flutter/material.dart';

import 'brand.dart';
import 'theme.dart';

/// How a [ChoicePill] is drawn.
enum ChoicePillStyle {
  /// A rounded tile with an icon well: coral with a check when selected.
  card,

  /// One slot of a segmented row: a raised cyan-lettered pill when selected.
  segment,
}

/// A tappable choice for short either/or settings such as snooze or check-in.
class ChoicePill extends StatelessWidget {
  const ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.style = ChoicePillStyle.card,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;
  final ChoicePillStyle style;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: style == ChoicePillStyle.segment
          ? _segment(context)
          : _card(context),
    );
  }

  /// secondary-fixed-dim in dark; the scheme's deeper cyan in light.
  static Color _cyanDim(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.light
        ? theme.colorScheme.secondary
        : const Color(0xff00dce6);
  }

  Widget _segment(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const shape = StadiumBorder();
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: selected
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 2,
                  offset: const Offset(0, 1),
                ),
              ]
            : null,
      ),
      child: Material(
        color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                color: selected ? _cyanDim(context) : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(32),
      side: light && !selected
          ? BorderSide(color: tokens.ghostBorder)
          : BorderSide.none,
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: selected
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 6,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Material(
        color: selected
            ? tokens.cta
            : (light ? scheme.surfaceContainerLow : scheme.surfaceContainer),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                if (icon != null) ...[
                  IconWell(
                    icon: selected ? Icons.check_circle_outline : icon!,
                    size: 36,
                    color: selected ? tokens.onCta : scheme.onSurfaceVariant,
                    background: selected
                        ? tokens.onCta.withValues(alpha: 0.2)
                        : scheme.surfaceContainerHigh,
                  ),
                  const SizedBox(width: 12),
                ],
                Flexible(
                  child: Text(
                    label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w600,
                      color: selected ? tokens.onCta : scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
