import 'package:flutter/material.dart';

import '../../shared/brand.dart';
import '../../shared/theme.dart';
import '../../shared/toast.dart';
import '../../shared/device_guidance.dart';
import 'onboarding_screen_view_model.dart';

/// First-run screen for the three settings that decide whether an alarm rings,
/// asked before the first alarm is saved because an empty list prompts nothing.
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.viewModel});

  final OnboardingScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    // Design 'secondary-fixed' (#6ff6ff) in dark mode.
    final secondaryFixed = light ? scheme.secondary : const Color(0xff6ff6ff);
    final playing = viewModel.playing;
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
              sliver: SliverFillRemaining(
                hasScrollBody: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 80,
                        height: 80,
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: scheme.surfaceContainerHigh,
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1a000000),
                              offset: Offset(0, 10),
                              blurRadius: 15,
                              spreadRadius: -3,
                            ),
                            BoxShadow(
                              color: Color(0x1a000000),
                              offset: Offset(0, 4),
                              blurRadius: 6,
                              spreadRadius: -4,
                            ),
                          ],
                        ),
                        child: const WakeGuardLogo(size: 72),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'WakeGuard',
                      textAlign: TextAlign.center,
                      style: text.headlineMedium?.copyWith(
                        letterSpacing: -0.65,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 320),
                        child: Text(
                          'Start your morning with an alarm and a wake-up '
                          'challenge. No ads or accounts. Let\'s '
                          'get your first alarm ready.',
                          textAlign: TextAlign.center,
                          style: text.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                            height: 1.625,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _FeaturePill(
                          icon: Icons.shield,
                          label: '100% Offline & Private',
                          color: secondaryFixed,
                        ),
                        _FeaturePill(
                          icon: Icons.no_accounts,
                          label: 'Zero Accounts or Sign-ups',
                          color: tokens.dawn,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _Step(
                      icon: Icons.notifications_outlined,
                      iconColor: accentOf(context),
                      title: 'Allow notifications',
                      isRequired: true,
                      body:
                          'Allow WakeGuard to show alarm notifications. '
                          'Sound and lock-screen behavior depend on your phone settings.',
                      button: OutlinedButton(
                        style: _stepButtonStyle(context),
                        onPressed: viewModel.requestingNotifications
                            ? null
                            : () => _requestNotifications(context),
                        child: Text(
                          viewModel.requestingNotifications
                              ? 'Opening…'
                              : 'Allow',
                        ),
                      ),
                    ),
                    if (viewModel.hasChecks) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              viewModel.ready
                                  ? Icons.check_circle_outline
                                  : Icons.info_outline,
                              size: 16,
                              color: secondaryFixed,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                viewModel.ready
                                    ? 'Alarm settings are ready.'
                                    : viewModel.pendingSummary,
                                style: text.labelSmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (viewModel.lastError != null) ...[
                      const SizedBox(height: 16),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Text(
                          viewModel.lastError!,
                          style: text.bodySmall?.copyWith(
                            color: scheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    _Step(
                      icon: Icons.volume_up_outlined,
                      iconColor: secondaryFixed,
                      title: 'Check the alarm volume',
                      isRequired: false,
                      body: DeviceGuidance.volumeSetup(theme.platform),
                      button: OutlinedButton.icon(
                        style: _stepButtonStyle(context, active: playing),
                        onPressed: playing
                            ? viewModel.stopTest
                            : viewModel.runPreflight,
                        icon: Icon(
                          playing ? Icons.stop : Icons.play_arrow_outlined,
                        ),
                        label: Text(playing ? 'Stop sound' : 'Test the sound'),
                      ),
                    ),
                    if (viewModel.hasExactAlarmCheck) ...[
                      const SizedBox(height: 16),
                      _Step(
                        icon: Icons.health_and_safety_outlined,
                        iconColor: accentOf(context),
                        title: 'Ring at the time you choose',
                        isRequired: true,
                        body:
                            'Allow WakeGuard under Alarms & reminders in your phone’s '
                            'settings. This lets alarms ring on time, even with the screen off. '
                            'You can review this in Health.',
                        button: OutlinedButton(
                          style: _stepButtonStyle(context),
                          onPressed: () => _allowExactAlarms(context),
                          child: const Text('Allow exact alarms'),
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    const Spacer(),
                    DecoratedBox(
                      decoration: const ShapeDecoration(
                        shape: StadiumBorder(),
                        shadows: [
                          BoxShadow(
                            color: Color(0x1a000000),
                            offset: Offset(0, 10),
                            blurRadius: 15,
                            spreadRadius: -3,
                          ),
                          BoxShadow(
                            color: Color(0x1a000000),
                            offset: Offset(0, 4),
                            blurRadius: 6,
                            spreadRadius: -4,
                          ),
                        ],
                      ),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: tokens.cta,
                          // Design 'on-primary' (#591d02).
                          foregroundColor: const Color(0xff591d02),
                          minimumSize: const Size.fromHeight(56),
                          textStyle: text.labelLarge,
                        ),
                        onPressed: viewModel.finishing
                            ? null
                            : () => _finish(context),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                viewModel.finishing ? 'Opening…' : 'Get started',
                              ),
                            ),
                            if (!viewModel.finishing) ...[
                              const SizedBox(width: 8),
                              const Icon(Icons.arrow_forward, size: 20),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: tokens.dawn,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        minimumSize: const Size.fromHeight(38),
                        textStyle: text.labelMedium,
                      ),
                      onPressed: viewModel.finishing
                          ? null
                          : () => _finish(context),
                      child: const Text('Skip for now'),
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

  ButtonStyle _stepButtonStyle(BuildContext context, {bool active = false}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    return OutlinedButton.styleFrom(
      backgroundColor: active ? tokens.cyan : scheme.surfaceContainerHighest,
      // Design 'on-secondary-container' (#006a6f) on the playing state.
      foregroundColor: active
          ? (light ? tokens.onCyan : const Color(0xff006a6f))
          : scheme.onSurface,
      side: BorderSide.none,
      minimumSize: const Size(0, 40),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      iconSize: 18,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelMedium,
    );
  }

  Future<void> _requestNotifications(BuildContext context) async {
    final failure = await viewModel.requestNotifications();
    if (failure == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not request notifications',
      detail: failure,
    );
  }

  Future<void> _allowExactAlarms(BuildContext context) async {
    final failure = await viewModel.allowExactAlarms();
    if (failure != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not open alarm settings',
        detail: failure,
      );
    }
  }

  Future<void> _finish(BuildContext context) async {
    final failure = await viewModel.finish();
    if (failure != null && context.mounted) {
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not complete setup',
        detail: failure,
      );
    }
  }
}

class _FeaturePill extends StatelessWidget {
  const _FeaturePill({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: ShapeDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.body,
    required this.isRequired,
    this.button,
  });

  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final bool isRequired;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final secondaryFixed = light ? scheme.secondary : const Color(0xff6ff6ff);
    return SurfaceCard(
      radius: 48,
      padding: const EdgeInsets.all(16),
      color: scheme.surfaceContainerLow,
      borderColor: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconWell(
            icon: icon,
            color: iconColor,
            background: scheme.surfaceContainerHighest,
            size: 40,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    _Badge(
                      label: isRequired ? 'Required' : 'Recommended',
                      foreground: isRequired ? scheme.error : secondaryFixed,
                      background: isRequired
                          ? scheme.errorContainer
                          : scheme.surfaceContainerHighest,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                if (button != null) ...[const SizedBox(height: 14), button!],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.foreground,
    required this.background,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: ShapeDecoration(
      color: background,
      shape: const StadiumBorder(),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: foreground,
      ),
    ),
  );
}
