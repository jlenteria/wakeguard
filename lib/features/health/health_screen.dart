import 'package:flutter/material.dart';

import '../../models/health.dart';
import '../../shared/brand.dart';
import '../../shared/theme.dart';
import '../../shared/toast.dart';
import '../../shared/device_guidance.dart';
import 'health_screen_view_model.dart';

const _shadowMd = [
  BoxShadow(
    color: Color(0x1a000000),
    offset: Offset(0, 4),
    blurRadius: 6,
    spreadRadius: -1,
  ),
  BoxShadow(
    color: Color(0x1a000000),
    offset: Offset(0, 2),
    blurRadius: 4,
    spreadRadius: -2,
  ),
];

const _shadowSm = [
  BoxShadow(color: Color(0x0d000000), offset: Offset(0, 1), blurRadius: 2),
];

/// The screen addressing the core problem: alarms silently failing due to OS settings.
class HealthScreen extends StatelessWidget {
  const HealthScreen({
    super.key,
    required this.viewModel,
    this.onReturnToAlarm,
  });

  final HealthScreenViewModel viewModel;
  final VoidCallback? onReturnToAlarm;

  @override
  Widget build(BuildContext context) {
    final capabilities = viewModel.capabilities;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final failing = [...viewModel.blocking, ...viewModel.warnings];

    return Scaffold(
      appBar: const BrandAppBar(section: 'Health'),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            _ReadinessSummary(viewModel: viewModel),
            if (onReturnToAlarm != null)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: FilledButton.icon(
                  onPressed: onReturnToAlarm,
                  icon: const Icon(Icons.alarm),
                  label: const Text('Return to alarm'),
                ),
              ),
            const SizedBox(height: 24),
            SurfaceCard(
              radius: 32,
              padding: const EdgeInsets.all(16),
              borderColor: Colors.transparent,
              shadow: _shadowMd,
              color: light ? null : scheme.surfaceContainer,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Check the sound', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    DeviceGuidance.soundTest(theme.platform),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.625,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 46),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 12,
                      ),
                      iconSize: 20,
                      backgroundColor: viewModel.playing
                          ? tokens.cyan
                          : tokens.cta,
                      foregroundColor: viewModel.playing
                          ? tokens.onCyan
                          : tokens.onCta,
                      textStyle: theme.textTheme.labelLarge,
                    ),
                    icon: Icon(
                      viewModel.playing ? Icons.stop : Icons.volume_up_outlined,
                    ),
                    label: Text(
                      viewModel.playing ? 'Stop test' : 'Test alarm sound',
                    ),
                    onPressed: () => _soundTest(context),
                  ),
                ],
              ),
            ),
            for (var i = 0; i < failing.length; i++)
              Padding(
                padding: EdgeInsets.only(top: i == 0 ? 24 : 16),
                child: _HealthTile(check: failing[i], viewModel: viewModel),
              ),
            if (capabilities != null)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: _CapabilityCard(capabilities: capabilities),
              ),
            if (viewModel.passed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Theme(
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    minTileHeight: 40,
                    childrenPadding: const EdgeInsets.only(top: 8),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    iconColor: scheme.onSurfaceVariant,
                    collapsedIconColor: scheme.onSurfaceVariant,
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            'Passed checks',
                            style: theme.textTheme.titleMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 2,
                          ),
                          decoration: ShapeDecoration(
                            color: scheme.surfaceContainerHighest,
                            shape: const StadiumBorder(),
                          ),
                          child: Text(
                            '${viewModel.passed.length}',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: tokens.dawnDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                    children: [
                      for (var i = 0; i < viewModel.passed.length; i++)
                        Padding(
                          padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
                          child: _HealthTile(
                            check: viewModel.passed[i],
                            viewModel: viewModel,
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

  Future<void> _refresh(BuildContext context) async {
    final error = await viewModel.refresh();
    if (error != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not refresh checks',
        detail: error,
      );
    }
  }

  Future<void> _soundTest(BuildContext context) async {
    if (viewModel.playing) {
      await viewModel.stopTest();
      return;
    }
    final error = await viewModel.runPreflight();
    if (error != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not play sound test',
        detail: error,
      );
    }
  }
}

/// A filled circle holding an icon, sized independently of its glyph.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.icon,
    required this.diameter,
    required this.iconSize,
    required this.color,
    required this.background,
  });

  final IconData icon;
  final double diameter;
  final double iconSize;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    width: diameter,
    height: diameter,
    decoration: BoxDecoration(shape: BoxShape.circle, color: background),
    child: Icon(icon, size: iconSize, color: color),
  );
}

class _ReadinessSummary extends StatelessWidget {
  const _ReadinessSummary({required this.viewModel});
  final HealthScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final count = viewModel.blocking.length + viewModel.warnings.length;
    final unavailable =
        viewModel.capabilities == null ||
        viewModel.controller.fatalError != null;
    final title = unavailable
        ? 'Readiness unavailable'
        : count == 0
        ? 'Required checks passed'
        : '$count ${count == 1 ? 'setting needs' : 'settings need'} attention';
    final detail = unavailable
        ? 'Pull down to check your alarm settings again.'
        : viewModel.blocking.isNotEmpty
        ? 'Fix the required settings below before relying on your alarm.'
        : count > 0
        ? 'Review the warnings below, then test the sound.'
        : 'These settings look ready. Test the sound and try an alarm with your phone locked.';
    final blocking = viewModel.blocking.isNotEmpty;
    final warning = !blocking && count > 0;
    final tint = blocking
        ? scheme.error
        : warning
        ? tokens.amber
        : null;
    final icon = unavailable
        ? Icons.help_outline
        : count == 0
        ? Icons.check_circle
        : Icons.error_outline;
    final iconColor = tint ??
        (unavailable ? scheme.onSurfaceVariant : tokens.dawn);
    final iconBackground = tint?.withValues(alpha: 0.16) ??
        (unavailable
            ? scheme.surfaceContainerHighest
            : tokens.dawn.withValues(alpha: 0.2));
    return SurfaceCard(
      radius: 32,
      padding: const EdgeInsets.all(16),
      shadow: _shadowMd,
      color: tint?.withValues(alpha: 0.1) ??
          (light ? null : scheme.surfaceContainer),
      borderColor: tint?.withValues(alpha: 0.4) ?? Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: _Badge(
              icon: icon,
              diameter: 40,
              iconSize: 24,
              color: iconColor,
              background: iconBackground,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: blocking ? scheme.error : scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.625,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HealthTile extends StatelessWidget {
  const _HealthTile({required this.check, required this.viewModel});

  final HealthCheck check;
  final HealthScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final (icon, color, background) = switch (check.severity) {
      HealthSeverity.ok => (
        Icons.check,
        tokens.dawn,
        tokens.dawn.withValues(alpha: 0.2),
      ),
      HealthSeverity.warning => (
        Icons.priority_high,
        tokens.amber,
        tokens.amber.withValues(alpha: 0.16),
      ),
      HealthSeverity.blocking => (
        Icons.dangerous_outlined,
        scheme.error,
        scheme.error.withValues(alpha: 0.16),
      ),
    };
    final failing = check.severity != HealthSeverity.ok;
    final showFix = check.action != null && failing;
    return SurfaceCard(
      padding: const EdgeInsets.all(16),
      radius: 32,
      color: scheme.surfaceContainerLow,
      shadow: _shadowSm,
      borderColor: failing ? color.withValues(alpha: 0.35) : Colors.transparent,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        minVerticalPadding: 0,
        minLeadingWidth: 0,
        minTileHeight: 0,
        horizontalTitleGap: 16,
        titleAlignment: ListTileTitleAlignment.top,
        leading: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: _Badge(
            icon: icon,
            diameter: 28,
            iconSize: 18,
            color: color,
            background: background,
          ),
        ),
        title: Text(
          check.label,
          style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurface),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              check.detail,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.375,
              ),
            ),
            if (showFix) ...[
              const SizedBox(height: 12),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(88, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                onPressed: viewModel.fixingAction != null
                    ? null
                    : () async {
                        final failure = await viewModel.openFix(check.action!);
                        if (!context.mounted) return;
                        final resolved = viewModel.checks.any(
                          (c) =>
                              c.id == check.id &&
                              c.severity == HealthSeverity.ok,
                        );
                        showAppToast(
                          context,
                          kind: failure != null
                              ? ToastKind.error
                              : resolved
                              ? ToastKind.success
                              : ToastKind.info,
                          message: failure != null
                              ? 'Could not resolve setting'
                              : resolved
                              ? 'Resolved'
                              : 'Action requested',
                          detail:
                              failure ??
                              (resolved
                                  ? check.label
                                  : 'Finish changing the setting, then pull down to check again.'),
                          duration: const Duration(seconds: 5),
                        );
                      },
                child: Text(
                  viewModel.fixingAction == check.action ? 'Opening…' : 'Fix',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CapabilityCard extends StatelessWidget {
  const _CapabilityCard({required this.capabilities});

  final EngineCapabilities capabilities;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final entries = <(String, bool)>[
      (
        'Keep ringing while the app is closed',
        capabilities.canLoopWhileBackgrounded,
      ),
      (
        'Show the challenge on the lock screen',
        capabilities.canLockScreenTakeover,
      ),
      (
        'Use a camera challenge from the lock screen',
        capabilities.canUseCameraInBackground,
      ),
      ('Play alarm sounds in Silent mode', capabilities.canBypassSilentSwitch),
    ];
    final fine = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
      height: 1.625,
    );
    return SurfaceCard(
      radius: 32,
      padding: const EdgeInsets.all(16),
      borderColor: Colors.transparent,
      shadow: _shadowMd,
      color: light ? scheme.surfaceContainer : scheme.surfaceContainerHigh,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Alarm features on this device',
            style: theme.textTheme.labelLarge?.copyWith(
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          for (var i = 0; i < entries.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 10),
              child: Row(
                children: [
                  Icon(
                    entries[i].$2 ? Icons.done : Icons.remove,
                    size: 18,
                    color: entries[i].$2
                        ? tokens.dawn
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      entries[i].$1,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: entries[i].$2
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 24),
          if (capabilities.pendingSlotCap != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Your device can keep up to ${capabilities.pendingSlotCap} '
                'alarm reminders scheduled at once. Each alarm may use '
                'several reminders. WakeGuard schedules the soonest ones first.',
                style: fine,
              ),
            ),
          Text(DeviceGuidance.deliveryAdvice(theme.platform), style: fine),
        ],
      ),
    );
  }
}
