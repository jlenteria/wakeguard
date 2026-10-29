import 'package:flutter/material.dart';

import 'theme.dart';

/// The split coral/cyan alarm-shield mark.
class WakeGuardLogo extends StatelessWidget {
  const WakeGuardLogo({super.key, this.size = 32});

  final double size;

  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/images/wakeguard_logo.png',
    width: size,
    height: size,
    filterQuality: FilterQuality.medium,
    excludeFromSemantics: true,
    errorBuilder: (_, _, _) =>
        Icon(Icons.alarm, size: size, color: WakeTokens.of(context).cta),
  );
}

/// The logo inside a soft circular plate, for onboarding and the splash.
class WakeGuardEmblem extends StatelessWidget {
  const WakeGuardEmblem({super.key, this.size = 72, this.glow = false});

  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = WakeTokens.of(context);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHigh,
        boxShadow: glow
            ? [
                BoxShadow(
                  color: tokens.cyan.withValues(alpha: 0.18),
                  blurRadius: size * 0.6,
                  spreadRadius: size * 0.05,
                ),
              ]
            : null,
      ),
      child: WakeGuardLogo(size: size * 0.66),
    );
  }
}

/// App bar with the logo, "WakeGuard" and the current section in coral caps.
class BrandAppBar extends StatelessWidget implements PreferredSizeWidget {
  const BrandAppBar({
    super.key,
    required this.section,
    this.leading,
    this.actions = const [],
  });

  final String section;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(64);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    return AppBar(
      toolbarHeight: 64,
      leading: leading,
      automaticallyImplyLeading: leading != null,
      titleSpacing: leading == null ? 20 : 0,
      elevation: 4,
      scrolledUnderElevation: 4,
      shadowColor: Colors.black.withValues(alpha: light ? 0.08 : 0.35),
      backgroundColor: theme.colorScheme.surface.withValues(alpha: 0.95),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const WakeGuardLogo(size: 32),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'WakeGuard',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(letterSpacing: -0.3),
            ),
          ),
        ],
      ),
      actions: [
        ...actions,
        Padding(
          padding: const EdgeInsets.only(left: 8, right: 20),
          child: Center(
            child: Text(
              section.toUpperCase(),
              style: theme.textTheme.labelMedium?.copyWith(
                color: light ? theme.colorScheme.primary : tokens.dawnDim,
                letterSpacing: 1.3,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A rounded obsidian card with a ghost border.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.margin = EdgeInsets.zero,
    this.color,
    this.gradient,
    this.onTap,
    this.onLongPress,
    this.radius = 28,
    this.borderColor,
    this.shadow,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final Color? color;
  final Gradient? gradient;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double radius;
  final Color? borderColor;
  final List<BoxShadow>? shadow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = WakeTokens.of(context);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: BorderSide(color: borderColor ?? tokens.ghostBorder),
    );
    final fill =
        color ??
        (theme.brightness == Brightness.light
            ? theme.colorScheme.surfaceContainerLow
            : theme.colorScheme.surfaceContainer);
    final card = Material(
      color: gradient == null ? fill : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: gradient == null
            ? null
            : ShapeDecoration(shape: shape, gradient: gradient),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    return Padding(
      padding: margin,
      child: shadow == null
          ? card
          : DecoratedBox(
              decoration: ShapeDecoration(shape: shape, shadows: shadow),
              child: card,
            ),
    );
  }
}

/// A compact rounded metadata chip: icon + label on a subtle fill.
class InfoPill extends StatelessWidget {
  const InfoPill({
    super.key,
    required this.label,
    this.icon,
    this.color,
    this.background,
    this.dense = false,
  });

  final String label;
  final IconData? icon;
  final Color? color;
  final Color? background;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = WakeTokens.of(context);
    final foreground = color ?? theme.colorScheme.onSurface;
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 10 : 14,
        vertical: dense ? 5 : 8,
      ),
      decoration: ShapeDecoration(
        color: background ?? tokens.subtle,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 14 : 18, color: foreground),
            SizedBox(width: dense ? 4 : 8),
          ],
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style:
                  (dense
                          ? theme.textTheme.labelSmall
                          : theme.textTheme.labelMedium)
                      ?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

/// A small glowing dot used in status lines ("GUARD ARMED & READY").
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: color,
      boxShadow: [
        BoxShadow(color: color.withValues(alpha: 0.5), blurRadius: 6),
      ],
    ),
  );
}

/// Section title with an optional trailing caption, e.g. "Scheduled Alarms".
class SectionHeading extends StatelessWidget {
  const SectionHeading({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(24, 28, 24, 12),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.headlineSmall),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A circular icon well used to lead list rows.
class IconWell extends StatelessWidget {
  const IconWell({
    super.key,
    required this.icon,
    this.color,
    this.background,
    this.size = 44,
  });

  final IconData icon;
  final Color? color;
  final Color? background;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: background ?? theme.colorScheme.surfaceContainerHighest,
      ),
      child: Icon(
        icon,
        size: size * 0.5,
        color: color ?? theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// The CTA colour for text/icons on the page: peach in dark, deep coral in light.
Color accentOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.brightness == Brightness.light
      ? theme.colorScheme.primary
      : WakeTokens.of(context).cta;
}
