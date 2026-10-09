import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../challenges/wake_up_qr.dart';
import '../alarms/alarm_editor_screen.dart';
import '../alarms/alarms_screen.dart';
import '../alarms/alarms_screen_view_model.dart';
import '../health/health_screen.dart';
import '../health/health_screen_view_model.dart';
import '../history/history_screen.dart';
import '../history/history_screen_view_model.dart';
import '../onboarding/onboarding_screen.dart';
import '../onboarding/onboarding_screen_view_model.dart';
import '../settings/settings_screen.dart';
import '../settings/settings_screen_view_model.dart';
import 'shell_screen_view_model.dart';
import '../../shared/toast.dart';
import '../../shared/view_model.dart';

/// The signed-in shell: onboarding gate, the four tabs, and the alarm editor
/// flow that can bounce through Health when camera access is missing.
class ShellScreen extends StatelessWidget {
  const ShellScreen({super.key, required this.viewModel});

  final ShellScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    if (!viewModel.settings.loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!viewModel.settings.settings.onboardingDone) {
      return ViewModelProvider<OnboardingScreenViewModel>(
        create: (_) => OnboardingScreenViewModel(
          viewModel.controller,
          onDone: () async {
            // Entering the shell: silence any sound test onboarding left running.
            await viewModel.controller.stopAudibilitySample();
            await viewModel.settings.update((s) => s.copyWith(onboardingDone: true));
          },
        ),
        builder: (_, vm) => OnboardingScreen(viewModel: vm),
      );
    }

    final fatalError = viewModel.controller.fatalError;
    return Scaffold(
      body: fatalError != null
          ? _FatalErrorView(message: fatalError, onRetry: viewModel.controller.retry)
          : IndexedStack(
              index: viewModel.tab,
              children: [
                ViewModelProvider<AlarmsScreenViewModel>(
                  create: (_) => AlarmsScreenViewModel(viewModel.controller),
                  builder: (_, vm) => AlarmsScreen(
                    viewModel: vm,
                    onOpenHealth: viewModel.openHealth,
                    onOpen: (alarm) => _openEditor(context, viewModel, existing: alarm),
                  ),
                ),
                ViewModelProvider<HealthScreenViewModel>(
                  create: (_) => HealthScreenViewModel(viewModel.controller),
                  builder: (_, vm) => HealthScreen(
                    viewModel: vm,
                    // Shown whenever Health was reached from the alarm flow, even
                    // without a draft: the user should be able to get back.
                    onReturnToAlarm:
                        viewModel.pendingCameraDraft == null && !viewModel.cameFromAlarm
                            ? null
                            : () {
                                final draft = viewModel.pendingCameraDraft;
                                if (draft == null) {
                                  viewModel.selectTab(0);
                                } else {
                                  unawaited(_openEditor(context, viewModel, existing: draft));
                                }
                              },
                  ),
                ),
                ViewModelProvider<HistoryScreenViewModel>(
                  create: (_) => HistoryScreenViewModel(viewModel.controller),
                  builder: (_, vm) => HistoryScreen(viewModel: vm),
                ),
                ViewModelProvider<SettingsScreenViewModel>(
                  create: (_) =>
                      SettingsScreenViewModel(viewModel.controller, viewModel.settings),
                  builder: (_, vm) => SettingsScreen(viewModel: vm),
                ),
              ],
            ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: viewModel.tab,
        onDestinationSelected: viewModel.selectTab,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.alarm_outlined),
            selectedIcon: Icon(Icons.alarm),
            label: 'Alarms',
          ),
          NavigationDestination(
            icon: Icon(Icons.health_and_safety_outlined),
            selectedIcon: Icon(Icons.health_and_safety),
            label: 'Health',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: 'History',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
      floatingActionButton: viewModel.tab == 0
          ? FloatingActionButton.extended(
              onPressed: () => _openEditor(context, viewModel),
              icon: const Icon(Icons.alarm_add),
              label: const Text('Add alarm'),
            )
          : null,
    );
  }

  Future<void> _openEditor(
    BuildContext context,
    ShellScreenViewModel viewModel, {
    Alarm? existing,
  }) async {
    final controller = viewModel.controller;
    String sharedQr;
    try {
      final codes =
          controller.alarms.map((a) => a.qrValue.trim()).where((code) => code.isNotEmpty);
      sharedQr = await WakeUpQrRepository()
          .getOrCreate(preferredValue: codes.isEmpty ? null : codes.first);
    } catch (error) {
      if (context.mounted) {
        showAppToast(context,
            kind: ToastKind.error, message: 'Could not load wake-up QR', detail: '$error');
      }
      return;
    }
    if (!context.mounted) return;
    final draft = await showModalBottomSheet<Alarm>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AlarmEditor(
        engine: viewModel.engine,
        sharedQrValue: sharedQr,
        existing: existing,
        defaultSnoozeMinutes: viewModel.settings.settings.defaultSnoozeMinutes,
        canCheckIn: controller.capabilities?.canCheckIn ?? false,
        canPractice: controller.capabilities?.canPractice ?? false,
      ),
    );
    if (draft == null || !context.mounted) return;

    // Re-check right now: the user may have just fixed (or revoked) something.
    await controller.refreshHealth();
    if (!context.mounted) return;
    if (controller.cameraPermissionMissingFor(draft)) {
      viewModel.setPendingCameraDraft(draft);
      viewModel.openHealth();
      showAppToast(context,
          kind: ToastKind.error,
          message: 'Alarm not saved',
          detail: 'Enable Camera in Health, then tap Return to alarm to save your draft.');
      return;
    }
    final unresolved = controller.unresolvedChecks;
    if (unresolved.isNotEmpty) {
      // Keep the draft (stored off until checks pass): discarding an alarm is worse.
      await controller.upsert(draft.copyWith(enabled: false));
      if (!context.mounted) return;
      viewModel.openHealth();
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Saved, but switched off',
        detail: '${unresolved.map((c) => c.label).join(', ')} must be fixed first. '
            'Turn the alarm on once the Health tab is clear.',
        duration: const Duration(seconds: 8),
      );
      return;
    }
    await controller.upsert(draft);
    if (!context.mounted) return;
    final error = controller.lastError;
    if (error == null) viewModel.setPendingCameraDraft(null);
    final at = controller.nextFireTime(draft.id);
    final message = error ??
        (!draft.enabled
            ? 'Saved, switched off.'
            : at == null
                ? 'Saved. Check alarm readiness.'
                : 'Next alarm: ${MaterialLocalizations.of(context).formatMediumDate(at)} at ${TimeOfDay.fromDateTime(at).format(context)}');
    showAppToast(context,
        kind: error == null ? ToastKind.success : ToastKind.error, message: message);
  }
}

class _FatalErrorView extends StatelessWidget {
  const _FatalErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
                onPressed: () => unawaited(onRetry()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
