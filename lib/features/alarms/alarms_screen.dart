import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../../shared/brand.dart';
import '../../shared/theme.dart';
import '../../shared/toast.dart';
import 'alarms_screen_view_model.dart';
import 'tone_names.dart';

/// The home tab: readiness, the next armed trigger, and every saved alarm.
class AlarmsScreen extends StatelessWidget {
  const AlarmsScreen({
    super.key,
    required this.viewModel,
    required this.onOpen,
    this.onOpenHealth,
    this.onAdd,
    this.editorOpen,
  });

  final AlarmsScreenViewModel viewModel;

  /// Opens the editor for an existing alarm; row taps previously only toggled the switch.
  final Future<void> Function(Alarm alarm) onOpen;
  final VoidCallback? onOpenHealth;

  /// Opens the editor for a new alarm from the "Add New Alarm" pill.
  final VoidCallback? onAdd;

  /// While true the editor is already showing, so the add pill is disabled.
  final ValueListenable<bool>? editorOpen;

  static const _margin = EdgeInsets.symmetric(horizontal: 20);

  @override
  Widget build(BuildContext context) {
    if (viewModel.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final dropped = viewModel.dropped;
    final soonest = viewModel.nextTrigger;
    final theme = Theme.of(context);
    final addButton = Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: _AddAlarmButton(onAdd: onAdd, editorOpen: editorOpen),
    );
    return Scaffold(
      appBar: const BrandAppBar(section: 'Alarms'),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: viewModel.isEmpty
            ? CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  if (viewModel.lastError != null)
                    SliverToBoxAdapter(
                      child: _ErrorBar(
                        message: viewModel.lastError!,
                        onDismiss: viewModel.clearError,
                      ),
                    ),
                  if (!_isReady(viewModel))
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                        child: _ReadinessIssues(
                          viewModel: viewModel,
                          onOpenHealth: onOpenHealth,
                        ),
                      ),
                    ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Column(
                      children: [
                        const Expanded(child: _EmptyState()),
                        addButton,
                      ],
                    ),
                  ),
                ],
              )
            : ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.only(top: 16),
                itemCount: viewModel.alarms.length + 2,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    final count = viewModel.alarms.length;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (viewModel.lastError != null)
                          _ErrorBar(
                            message: viewModel.lastError!,
                            onDismiss: viewModel.clearError,
                          ),
                        _HeroCard(
                          viewModel: viewModel,
                          triggerAt: soonest,
                          onOpenHealth: onOpenHealth,
                        ),
                        if (dropped.isNotEmpty)
                          _SlotWarning(count: dropped.length),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Scheduled Alarms',
                                  style: theme.textTheme.titleMedium,
                                ),
                              ),
                              Text(
                                '$count configured',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }
                  if (index == viewModel.alarms.length + 1) return addButton;
                  final alarm = viewModel.alarms[index - 1];
                  return Padding(
                    padding: _margin.add(const EdgeInsets.only(bottom: 16)),
                    child: _AlarmTile(
                      alarm: alarm,
                      busy: viewModel.isBusy(alarm.id),
                      plannedAt: viewModel.fireTime(alarm.id),
                      onOpen: onOpen,
                      onToggle: (value) async {
                        try {
                          final cameraMissing = await viewModel.toggle(
                            alarm,
                            value,
                          );
                          if (cameraMissing) onOpenHealth?.call();
                        } catch (error) {
                          if (context.mounted) {
                            showAppToast(
                              context,
                              kind: ToastKind.error,
                              message: 'Could not update alarm',
                              detail: '$error',
                            );
                          }
                        }
                      },
                      onDelete: () => viewModel.delete(alarm),
                      onRestore: () => viewModel.restore(alarm),
                      onDuplicate: () => viewModel.duplicate(alarm),
                      onSkip: () => viewModel.toggleSkip(alarm),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _refresh(BuildContext context) async {
    try {
      await viewModel.refresh();
    } catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.error,
          message: 'Could not refresh alarms',
          detail: '$error',
        );
      }
    }
  }
}

/// The full-width sunrise pill under the list.
class _AddAlarmButton extends StatelessWidget {
  const _AddAlarmButton({this.onAdd, this.editorOpen});

  final VoidCallback? onAdd;
  final ValueListenable<bool>? editorOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = WakeTokens.of(context);
    Widget button(bool open) => DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        shadows: [
          BoxShadow(
            color: tokens.ctaGlow,
            blurRadius: 24,
            spreadRadius: -2,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: FilledButton(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
        ),
        onPressed: open || onAdd == null ? null : onAdd,
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle, size: 24),
            SizedBox(width: 8),
            Flexible(
              child: Text('Add New Alarm', textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
    final listenable = editorOpen;
    if (listenable == null) return button(false);
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (_, open, _) => button(open),
    );
  }
}

bool _isReady(AlarmsScreenViewModel viewModel) =>
    viewModel.unresolvedChecks.isEmpty &&
    viewModel.warnings.isEmpty &&
    viewModel.readinessKnown;

/// Display name, icon and order for each way out of a ring.
String _challengeLabel(EscapeKind escape) => switch (escape) {
  EscapeKind.face => 'Face Check',
  _ => escape.label,
};

IconData _challengeIcon(EscapeKind escape) => switch (escape) {
  EscapeKind.tap => Icons.touch_app_outlined,
  EscapeKind.face => Icons.face_retouching_natural,
  EscapeKind.object => Icons.center_focus_strong_outlined,
  EscapeKind.qr => Icons.qr_code_scanner,
};

/// Selected challenges only; legacy labels remain in History, not this list.
List<EscapeKind> _challenges(Alarm alarm) =>
    EscapeKind.values.where(alarm.escapes.contains).toList();

/// Splits a time into its digits and an AM/PM suffix (none in 24-hour mode).
(String, String?) _timeParts(BuildContext context, TimeOfDay time) {
  final localizations = MaterialLocalizations.of(context);
  if (MediaQuery.alwaysUse24HourFormatOf(context)) {
    return (
      localizations.formatTimeOfDay(time, alwaysUse24HourFormat: true),
      null,
    );
  }
  final hour = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
  return (
    '$hour:${time.minute.toString().padLeft(2, '0')}',
    time.period == DayPeriod.am
        ? localizations.anteMeridiemAbbreviation
        : localizations.postMeridiemAbbreviation,
  );
}

/// A large time with a smaller AM/PM suffix, shrinking to fit narrow screens.
class _TimeReadout extends StatelessWidget {
  const _TimeReadout({
    required this.time,
    required this.style,
    required this.suffixStyle,
  });

  final TimeOfDay time;
  final TextStyle style;
  final TextStyle suffixStyle;

  @override
  Widget build(BuildContext context) {
    final (digits, suffix) = _timeParts(context, time);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.centerLeft,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text(digits, style: style),
          if (suffix != null) ...[
            const SizedBox(width: 8),
            Text(suffix, style: suffixStyle),
          ],
        ],
      ),
    );
  }
}

/// The dashboard hero: guard status, the next ring and its countdown.
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.viewModel,
    required this.triggerAt,
    this.onOpenHealth,
  });

  final AlarmsScreenViewModel viewModel;
  final DateTime? triggerAt;
  final VoidCallback? onOpenHealth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final localizations = MaterialLocalizations.of(context);
    final ready = _isReady(viewModel);
    final alarm = viewModel.nextAlarm;
    final when = triggerAt;
    final primary = alarm == null ? null : _challenges(alarm).firstOrNull;
    final armed = light ? scheme.secondary : const Color(0xff6ff6ff);

    final Color statusColor;
    final String statusText;
    if (!ready) {
      statusColor = viewModel.unresolvedChecks.isNotEmpty
          ? scheme.error
          : tokens.amber;
      statusText = 'Needs attention';
    } else if (when == null) {
      statusColor = scheme.outline;
      statusText = 'Guard standing by';
    } else {
      statusColor = armed;
      statusText = 'Guard armed & ready';
    }

    Widget glow(Color color) => Container(
      width: 176,
      height: 176,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: 0.14), color.withValues(alpha: 0)],
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(32),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: light ? 0.08 : 0.35),
              blurRadius: 25,
              offset: const Offset(0, 20),
              spreadRadius: -5,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(32),
          child: ColoredBox(
            color: light ? scheme.surfaceContainerLow : scheme.surfaceContainerHigh,
            child: Stack(
              children: [
                Positioned(right: -48, top: -48, child: glow(tokens.cta)),
                Positioned(left: -48, bottom: -48, child: glow(tokens.cyan)),
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          StatusDot(color: statusColor, size: 10),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              statusText.toUpperCase(),
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: statusColor,
                                letterSpacing: 0.9,
                              ),
                            ),
                          ),
                          if (primary != null) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: InfoPill(
                                dense: true,
                                icon: primary == EscapeKind.face
                                    ? Icons.visibility_outlined
                                    : _challengeIcon(primary),
                                label: _challengeLabel(primary),
                                color: scheme.tertiary,
                                background: scheme.surfaceContainerHighest,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (!ready) ...[
                        const SizedBox(height: 16),
                        _ReadinessIssues(
                          viewModel: viewModel,
                          onOpenHealth: onOpenHealth,
                        ),
                      ],
                      const SizedBox(height: 16),
                      if (when != null) ...[
                        KeyedSubtree(
                          key: const ValueKey('next-alarm-caption'),
                          child: _RingsIn(
                            when: when,
                            prefix: 'Next alarm ',
                            textOf: (relative, now) {
                              if (relative == 'now') {
                                return 'Next alarm ringing now';
                              }
                              return 'Next alarm '
                                  '${_dayPhrase(localizations, when, now)} '
                                  '$relative';
                            },
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        _TimeReadout(
                          time: TimeOfDay.fromDateTime(when),
                          style: theme.textTheme.displayMedium!.copyWith(
                            color: tokens.dawn,
                            fontFeatures: WakeTheme.tabular,
                          ),
                          suffixStyle: theme.textTheme.headlineSmall!.copyWith(
                            color: tokens.dawnDim,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Row(
                          children: [
                            Icon(
                              Icons.wb_twilight,
                              size: 18,
                              color: scheme.tertiary,
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                'Wake-up guarantee active',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else
                        Text(
                          viewModel.hasEnabledAlarms
                              ? 'No upcoming alarm scheduled. Check Health for details.'
                              : 'No alarms enabled. Switch one on to schedule your next wake-up.',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "today", "tomorrow" or "on `date`" for the hero caption.
  static String _dayPhrase(
    MaterialLocalizations localizations,
    DateTime when,
    DateTime now,
  ) {
    final days =
        (DateTime(when.year, when.month, when.day)
                    .difference(DateTime(now.year, now.month, now.day))
                    .inHours /
                24)
            .round();
    if (days <= 0) return 'today';
    if (days == 1) return 'tomorrow';
    return 'on ${localizations.formatMediumDate(when)}';
  }
}

/// What stands between the user and a reliable alarm; opens Health on tap.
class _ReadinessIssues extends StatelessWidget {
  const _ReadinessIssues({required this.viewModel, this.onOpenHealth});

  final AlarmsScreenViewModel viewModel;
  final VoidCallback? onOpenHealth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final blocking = viewModel.unresolvedChecks;
    final warnings = viewModel.warnings;
    final color = blocking.isNotEmpty ? scheme.error : tokens.amber;
    return SurfaceCard(
      radius: 20,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      color: Color.alphaBlend(
        color.withValues(alpha: 0.12),
        scheme.surfaceContainerHigh,
      ),
      borderColor: color.withValues(alpha: 0.35),
      onTap: onOpenHealth,
      child: Row(
        children: [
          Icon(Icons.error_outline, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  !viewModel.readinessKnown
                      ? 'Readiness unavailable'
                      : 'Your alarm needs attention',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  !viewModel.readinessKnown
                      ? 'Open Health to check your settings.'
                      : [
                          ...blocking,
                          ...warnings,
                        ].map((c) => c.label).join(', '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
      radius: 20,
      color: scheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.error_outline, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: scheme.onErrorContainer),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, color: scheme.onErrorContainer),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

class _SlotWarning extends StatelessWidget {
  const _SlotWarning({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SurfaceCard(
      margin: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      padding: const EdgeInsets.all(18),
      radius: 24,
      color: scheme.errorContainer,
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: scheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$count ${count == 1 ? 'alarm cannot' : 'alarms cannot'} be scheduled '
              'because your device’s reminder limit has been reached. '
              'Turn off or delete some alarms to make room.',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _AlarmTile extends StatelessWidget {
  const _AlarmTile({
    required this.alarm,
    required this.onOpen,
    required this.onToggle,
    required this.onDelete,
    required this.onRestore,
    required this.onDuplicate,
    required this.onSkip,
    this.plannedAt,
    required this.busy,
  });

  final Alarm alarm;
  final Future<void> Function(Alarm alarm) onOpen;
  final Future<void> Function(bool) onToggle;
  final Future<bool> Function() onDelete;
  final Future<void> Function() onRestore;
  final Future<void> Function() onDuplicate;
  final Future<void> Function() onSkip;
  final DateTime? plannedAt;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay(hour: alarm.hour, minute: alarm.minute);
    final timeLabel = time.format(context);
    final messenger = ScaffoldMessenger.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final on = alarm.enabled;
    final skipped =
        alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch;
    final sound = _soundName(alarm);
    final chipFill = on ? scheme.surfaceContainerHigh : scheme.surfaceContainer;
    const radius = BorderRadius.all(Radius.circular(32));
    return Dismissible(
      key: ValueKey(alarm.id),
      direction: busy ? DismissDirection.none : DismissDirection.endToStart,
      confirmDismiss: (_) async {
        final deleted = await onDelete();
        if (!deleted) return false;
        // Captured before the await: the tile unmounts, so a later lookup would throw.
        messenger.clearSnackBars();
        showToastTo(
          messenger,
          scheme,
          kind: ToastKind.success,
          message: 'Deleted the $timeLabel alarm',
          duration: const Duration(seconds: 10),
          actionLabel: 'Undo',
          onAction: () => unawaited(
            onRestore().catchError((Object error) {
              showToastTo(
                messenger,
                scheme,
                kind: ToastKind.error,
                message: 'Could not restore alarm',
                detail: '$error',
              );
            }),
          ),
        );
        return true;
      },
      background: Container(
        decoration: BoxDecoration(color: scheme.error, borderRadius: radius),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 28),
        child: Icon(Icons.delete_outline, color: scheme.onError),
      ),
      child: Opacity(
        opacity: on ? 1 : 0.75,
        child: SurfaceCard(
          radius: 32,
          padding: const EdgeInsets.all(20),
          color: light
              ? (on ? Colors.white : scheme.surfaceContainerLow)
              : (on ? scheme.surfaceContainer : scheme.surfaceContainerLow),
          borderColor: on ? null : Colors.transparent,
          shadow: on
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: light ? 0.06 : 0.25),
                    blurRadius: 6,
                    offset: const Offset(0, 4),
                    spreadRadius: -1,
                  ),
                ]
              : null,
          onTap: busy ? null : () => onOpen(alarm),
          onLongPress: busy ? null : () => _showActions(context, skipped),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _TimeReadout(
                          time: time,
                          style: theme.textTheme.displayMedium!.copyWith(
                            color: on
                                ? scheme.onSurface
                                : scheme.onSurfaceVariant,
                            fontFeatures: WakeTheme.tabular,
                          ),
                          suffixStyle: theme.textTheme.headlineSmall!.copyWith(
                            color: on ? tokens.dawn : scheme.outline,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                                alarm.label.isEmpty ? 'Alarm' : alarm.label,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyLarge?.copyWith(
                                  fontWeight: on
                                      ? FontWeight.w600
                                      : FontWeight.w500,
                                  color: on
                                      ? scheme.onSurface
                                      : scheme.onSurfaceVariant,
                                ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                              ),
                              child: Container(
                                width: 6,
                                height: 6,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: on
                                      ? scheme.outline
                                      : scheme.outlineVariant,
                                ),
                              ),
                            ),
                            Text(
                              _repeatSummary(alarm),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: on
                                    ? scheme.onSurfaceVariant
                                    : scheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (busy)
                    const Padding(
                      padding: EdgeInsets.only(top: 8, right: 8),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  Switch(
                    value: alarm.enabled,
                    onChanged: busy || alarm.needsSetup
                        ? null
                        : (value) => onToggle(value),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              _WeekdayRow(alarm: alarm),
              const SizedBox(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (alarm.needsSetup)
                    InfoPill(
                      icon: Icons.build_circle_outlined,
                      label: 'Setup required',
                      color: tokens.amber,
                      background: chipFill,
                    ),
                  for (final escape in _challenges(alarm))
                    InfoPill(
                      icon: _challengeIcon(escape),
                      label: _challengeLabel(escape),
                      color: on ? scheme.tertiary : scheme.onSurfaceVariant,
                      background: chipFill,
                    ),
                  InfoPill(
                    icon: Icons.snooze,
                    label: alarm.snoozeMinutes == 0
                        ? 'No snooze'
                        : '${alarm.snoozeMinutes} min snooze',
                    color: on ? scheme.onSurfaceVariant : scheme.outline,
                    background: chipFill,
                  ),
                  if (alarm.checkInMinutes > 0)
                    InfoPill(
                      icon: Icons.directions_walk,
                      label: '${alarm.checkInMinutes} min check-in',
                      color: on ? scheme.onSurfaceVariant : scheme.outline,
                      background: chipFill,
                    ),
                  if (skipped)
                    InfoPill(
                      icon: Icons.skip_next,
                      label: 'Next alarm skipped',
                      color: tokens.amber,
                      background: chipFill,
                    ),
                  if (sound != null && on)
                    InfoPill(
                      icon: Icons.music_note,
                      label: sound,
                      color: light ? scheme.secondary : const Color(0xff00dce6),
                      background: chipFill,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Duplicate / skip live behind a long-press so the card matches the design.
  Future<void> _showActions(BuildContext context, bool skipped) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('Duplicate'),
              onTap: () => Navigator.pop(sheet, 'duplicate'),
            ),
            if (alarm.enabled && alarm.isRepeating)
              ListTile(
                leading: const Icon(Icons.skip_next_outlined),
                title: Text(skipped ? 'Undo skip' : 'Skip next alarm'),
                onTap: () => Navigator.pop(sheet, 'skip'),
              ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
    if (action == null || !context.mounted) return;
    try {
      if (action == 'duplicate') await onDuplicate();
      if (action == 'skip') await onSkip();
      if (!context.mounted) return;
      showAppToast(
        context,
        kind: ToastKind.success,
        message: action == 'duplicate'
            ? 'Alarm duplicated, switched off.'
            : 'Schedule updated.',
        detail: action == 'duplicate' ? 'Edit it to choose a time.' : null,
      );
    } catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.error,
          message: 'Could not update alarm',
          detail: '$error',
        );
      }
    }
  }

  /// The tone's readable name, or null when it has no Latin-script title.
  static String? _soundName(Alarm alarm) {
    if (alarm.hasCustomSound) return englishToneName(alarm.customSoundName);
    return alarm.soundPack.label.split(' (').first;
  }

  /// "Every day", "Mon - Fri", "Sat, Sun" or "Once": runs of three or more
  /// consecutive days collapse into a range.
  static String _repeatSummary(Alarm alarm) {
    if (!alarm.isRepeating) return 'Once';
    if (alarm.weekdays.isEmpty || alarm.weekdays.length == 7) {
      return 'Every day';
    }
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final ordered = alarm.weekdays.toList()..sort();
    final parts = <String>[];
    var i = 0;
    while (i < ordered.length) {
      var j = i;
      while (j + 1 < ordered.length && ordered[j + 1] == ordered[j] + 1) {
        j++;
      }
      if (j - i >= 2) {
        parts.add('${names[ordered[i] - 1]} - ${names[ordered[j] - 1]}');
      } else {
        for (var k = i; k <= j; k++) {
          parts.add(names[ordered[k] - 1]);
        }
      }
      i = j + 1;
    }
    return parts.join(', ');
  }
}

/// Seven 28px day badges, filled on the days this alarm rings.
class _WeekdayRow extends StatelessWidget {
  const _WeekdayRow({required this.alarm});

  final Alarm alarm;

  static const _letters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final on = alarm.enabled;
    bool active(int day) =>
        alarm.isRepeating &&
        (alarm.weekdays.isEmpty || alarm.weekdays.contains(day));
    // The repeat summary above already reads this out.
    return ExcludeSemantics(
      child: Row(
        children: [
          for (var day = 1; day <= 7; day++) ...[
            if (day > 1) const SizedBox(width: 6),
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: !active(day)
                    ? scheme.surfaceContainerHighest
                    : on
                    ? tokens.cta
                    : scheme.surfaceBright,
              ),
              child: Text(
                _letters[day - 1],
                style: theme.textTheme.labelSmall?.copyWith(
                  color: !active(day)
                      ? (on ? scheme.outline : scheme.outlineVariant)
                      : on
                      ? tokens.onCta
                      : scheme.onSurface,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Time until [when], counted in clock minutes so it agrees with the status bar:
/// at 4:04:30 an alarm for 4:05 is "in 1m", and "now" only once 4:05 arrives.
@visibleForTesting
String ringsIn(DateTime when, DateTime now) {
  DateTime minuteOf(DateTime t) =>
      DateTime(t.year, t.month, t.day, t.hour, t.minute);
  final minutes = minuteOf(when).difference(minuteOf(now)).inMinutes;
  if (minutes <= 0) return 'now';
  if (minutes < 60) return 'in ${minutes}m';
  final hours = minutes ~/ 60;
  if (hours < 24) return 'in ${hours}h ${minutes % 60}m';
  return 'in ${hours ~/ 24}d ${hours % 24}h';
}

/// "Rings in 5m" text that re-evaluates each time the clock minute changes.
class _RingsIn extends StatefulWidget {
  const _RingsIn({
    required this.when,
    required this.prefix,
    this.style,
    this.textOf,
  });

  final DateTime when;
  final String prefix;
  final TextStyle? style;

  /// Builds the full text from the relative time; defaults to [prefix] + it.
  final String Function(String relative, DateTime now)? textOf;

  @override
  State<_RingsIn> createState() => _RingsInState();
}

class _RingsInState extends State<_RingsIn> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scheduleTick();
  }

  void _scheduleTick() {
    final now = DateTime.now();
    // Land just after the next minute boundary so the text flips with the clock.
    final intoMinute = now.second * 1000 + now.millisecond;
    _timer = Timer(Duration(milliseconds: 60000 - intoMinute + 50), () {
      if (!mounted) return;
      setState(() {});
      _scheduleTick();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final relative = ringsIn(widget.when, now);
    return Text(
      widget.textOf?.call(relative, now) ?? '${widget.prefix}$relative',
      style: widget.style,
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const WakeGuardEmblem(size: 96, glow: true),
            const SizedBox(height: 24),
            Text(
              'Make tomorrow morning easier.\nAdd an alarm, choose a preset, '
              'and practice your challenge.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
