import 'package:flutter/material.dart';

import '../../shared/toast.dart';
import 'history_screen_view_model.dart';

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.viewModel});

  final HistoryScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final entries = viewModel.entries;
    final scheme = Theme.of(context).colorScheme;
    final rows = <(DateTime?, Map<String, Object?>?)>[
      for (final day in viewModel.days) ...[
        (day.date, null),
        for (final entry in day.entries) (day.date, entry),
      ],
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wake-up history'),
        actions: [
          if (entries.isNotEmpty)
            IconButton(
              tooltip: 'Delete history',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _clear(context),
            ),
        ],
      ),
      backgroundColor: Theme.of(context).brightness == Brightness.light
          ? const Color(0xfffff8f8)
          : scheme.surface,
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HistorySummary(viewModel: viewModel),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Your first morning starts the story. Completed challenges, snoozes, missed alarms and check-ins will appear here.',
                      ),
                    ),
                ],
              );
            }
            final (day, entry) = rows[index - 1];
            if (entry == null) {
              return _ActivityDayHeading(day: day);
            }
            return _ActivityTimelineEntry(
              entry: entry,
              first: index == 1 || rows[index - 2].$2 == null,
              last: index == rows.length || rows[index].$2 == null,
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
          message: 'Could not refresh history',
          detail: '$error',
        );
      }
    }
  }

  Future<void> _clear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete wake-up history?'),
        content: const Text(
          'This clears your local history and streak. Your alarms and pending check-ins are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete history'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await viewModel.clearHistory();
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.success,
          message: 'History cleared',
        );
      }
    } catch (error) {
      if (context.mounted) {
        showAppToast(
          context,
          kind: ToastKind.error,
          message: 'Could not delete history',
          detail: '$error',
        );
      }
    }
  }
}

class _ActivityDayHeading extends StatelessWidget {
  const _ActivityDayHeading({required this.day});
  final DateTime? day;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final relative = day == today
        ? 'Today'
        : day == yesterday
        ? 'Yesterday'
        : null;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          Text(
            'Activity log',
            style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
          ),
          Wrap(
            spacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (relative != null) ...[
                Text(relative, style: text.labelLarge),
                Text('·', style: text.labelLarge),
              ],
              Text(
                day == null
                    ? 'Date unavailable'
                    : MaterialLocalizations.of(context).formatMediumDate(day!),
                style: text.labelLarge,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Each row remains lazy; first/last rounding forms one continuous daily card.
class _ActivityTimelineEntry extends StatelessWidget {
  const _ActivityTimelineEntry({
    required this.entry,
    required this.first,
    required this.last,
  });
  final Map<String, Object?> entry;
  final bool first;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final event = entry['event'] as String? ?? 'dismissed';
    final successful = event == 'dismissed' || event == 'confirmed';
    final failure = const {
      'missed',
      'checkin_failed',
      'checkin_expired',
      'checkin_notification_blocked',
      'checkin_notification_failed',
      'next_schedule_failed',
      'challenge_setup_required',
    }.contains(event);
    final accent = light ? const Color(0xffa64222) : scheme.primary;
    final iconColor = failure
        ? scheme.error
        : successful
        ? accent
        : scheme.onSurfaceVariant;
    final circleColor = failure
        ? scheme.errorContainer
        : successful
        ? (light ? const Color(0xffefdfd8) : scheme.primaryContainer)
        : (light ? const Color(0xfff0e8e8) : scheme.surfaceContainerHighest);
    final rawAt = entry['at'];
    final at = rawAt is num
        ? DateTime.fromMillisecondsSinceEpoch(rawAt.toInt())
        : null;
    final time = at == null ? null : TimeOfDay.fromDateTime(at).format(context);
    final date = at == null
        ? 'Date unavailable'
        : MaterialLocalizations.of(context).formatMediumDate(at);
    final detail = HistoryScreenViewModel.eventDetail(entry);
    final rawDuration = entry['durationMs'];
    final duration = rawDuration is num && rawDuration >= 0
        ? rawDuration.toInt() ~/ 1000
        : null;
    final rawSnoozes = entry['snoozes'];
    final snoozes = rawSnoozes is num && rawSnoozes >= 0
        ? rawSnoozes.toInt()
        : null;
    final method = entry['method'] as String? ?? '';
    final icon = switch (event) {
      'dismissed' => Icons.check_circle_rounded,
      'confirmed' => Icons.verified_user_rounded,
      'started' => Icons.alarm_on_outlined,
      'snoozed' => Icons.snooze_rounded,
      'checkin_scheduled' => Icons.schedule_rounded,
      'checkin_prompted' => Icons.notifications_active_outlined,
      _ => failure ? Icons.error_outline_rounded : Icons.alarm_rounded,
    };
    final title = Text(
      '${entry['label'] ?? 'Alarm'} · ${HistoryScreenViewModel.eventLabel(event)}',
      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    final timestamp = time == null
        ? null
        : Text(
            time,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.end,
          );
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: EdgeInsetsDirectional.fromSTEB(
        16,
        first ? 4 : 0,
        16,
        last ? 4 : 0,
      ),
      decoration: BoxDecoration(
        color: light ? Colors.white : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(
          top: first ? const Radius.circular(20) : Radius.zero,
          bottom: last ? const Radius.circular(20) : Radius.zero,
        ),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 88),
        child: Stack(
          children: [
            if (!first || !last)
              PositionedDirectional(
                start: 21,
                top: first ? 38 : 0,
                bottom: last ? null : 0,
                height: last ? 38 : null,
                width: 2,
                child: ColoredBox(
                  color: light
                      ? const Color(0xffeadfdf)
                      : scheme.outlineVariant,
                ),
              ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(60, 16, 0, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LayoutBuilder(
                    builder: (context, constraints) {
                      // Keep times right aligned without squeezing titles at large text sizes.
                      if (timestamp == null) return title;
                      if (constraints.maxWidth < 200 ||
                          MediaQuery.textScalerOf(context).scale(14) > 21) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            title,
                            const SizedBox(height: 4),
                            timestamp,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: title),
                          const SizedBox(width: 10),
                          timestamp,
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$date${detail.isEmpty ? '' : ' · $detail'}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (event == 'dismissed' &&
                      (duration != null ||
                          method.isNotEmpty ||
                          snoozes != null)) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (duration != null)
                          _LogChip(
                            label: '${duration ~/ 60}m ${duration % 60}s',
                            icon: Icons.timer_outlined,
                          ),
                        if (method.isNotEmpty)
                          _LogChip(
                            label: HistoryScreenViewModel.methodLabel(method),
                            icon: switch (method) {
                              'face' => Icons.face_outlined,
                              'object' => Icons.center_focus_strong_outlined,
                              'qr' => Icons.qr_code_scanner,
                              'pattern' => Icons.grid_3x3,
                              _ => Icons.touch_app_outlined,
                            },
                          ),
                        if (snoozes != null)
                          _LogChip(
                            label: '$snoozes snooze${snoozes == 1 ? '' : 's'}',
                            highlighted: true,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            PositionedDirectional(
              start: 0,
              top: 16,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: circleColor,
                  shape: BoxShape.circle,
                ),
                child: ExcludeSemantics(
                  child: Icon(icon, color: iconColor, size: 23),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LogChip extends StatelessWidget {
  const _LogChip({required this.label, this.icon, this.highlighted = false});
  final String label;
  final IconData? icon;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final light = theme.brightness == Brightness.light;
    final foreground = highlighted
        ? (light ? const Color(0xffa64222) : theme.colorScheme.primary)
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: highlighted
            ? (light
                  ? const Color(0xfff2ded6)
                  : theme.colorScheme.primaryContainer)
            : (light
                  ? const Color(0xfff4ecec)
                  : theme.colorScheme.surfaceContainerHighest),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            ExcludeSemantics(child: Icon(icon, size: 14, color: foreground)),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistorySummary extends StatelessWidget {
  const _HistorySummary({required this.viewModel});
  final HistoryScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final accent = light ? const Color(0xffa64222) : scheme.primary;
    final stats = viewModel.stats;
    return Container(
      margin: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: light
              ? const [Colors.white, Color(0xfffffaf7)]
              : [scheme.surfaceContainerLow, scheme.surfaceContainer],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: light
                      ? const Color(0xffefdfd8)
                      : scheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: ExcludeSemantics(
                  child: Icon(
                    Icons.local_fire_department_rounded,
                    color: accent,
                    size: 30,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          '${stats.streak} scheduled-day streak',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (stats.streak > 0)
                          ExcludeSemantics(
                            child: Icon(
                              Icons.verified_outlined,
                              color: accent,
                              size: 20,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Last 7 days: ${viewModel.completed} stopped · ${viewModel.missed} missed',
                      softWrap: true,
                      textAlign: TextAlign.start,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 13,
                        color: accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          _WeekProgress(days: viewModel.currentWeek, accent: accent),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: light
                  ? const Color(0xfffcf2f3)
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Your streak counts completed alarms and check-ins, not how well you slept. '
                    'Days without a scheduled alarm do not break your streak.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '${stats.totalDays} completed days in saved history',
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekProgress extends StatelessWidget {
  const _WeekProgress({required this.days, required this.accent});
  final List<HistoryWeekDay> days;
  final Color accent;
  static const _names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      decoration: BoxDecoration(
        color: light ? const Color(0xfff4eded) : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(13) / 13;
          // Seven columns normally; wrap at large text sizes instead of clipping
          // weekday labels or shrinking the user's accessibility font setting.
          final columns = (constraints.maxWidth / (28 * scale))
              .floor()
              .clamp(1, 7)
              .toInt();
          final width = constraints.maxWidth / columns;
          final diameter = (width - 4).clamp(24.0, 38.0).toDouble();
          return Wrap(
            runSpacing: 14,
            children: [
              for (var index = 0; index < days.length; index++)
                SizedBox(
                  width: width,
                  child: _WeekDayMarker(
                    day: days[index],
                    label: _names[index],
                    accent: accent,
                    diameter: diameter,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _WeekDayMarker extends StatelessWidget {
  const _WeekDayMarker({
    required this.day,
    required this.label,
    required this.accent,
    required this.diameter,
  });
  final HistoryWeekDay day;
  final String label;
  final Color accent;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    final complete = day.state == HistoryWeekState.completed;
    final activeComplete = complete && day.isToday;
    final missed = day.state == HistoryWeekState.missed;
    final waitingToday = day.isToday && !complete && !missed;
    final description = switch (day.state) {
      HistoryWeekState.completed => 'Completed',
      HistoryWeekState.missed => 'Missed alarm recorded',
      HistoryWeekState.pending => 'No completion recorded',
      HistoryWeekState.upcoming => 'Upcoming',
    };
    final semantics =
        '${MaterialLocalizations.of(context).formatFullDate(day.date)} · '
        '${day.isToday ? 'Today · ' : ''}$description';
    final color = missed ? scheme.error : accent;
    final background = activeComplete
        ? accent
        : missed
        ? scheme.errorContainer
        : complete
        ? (light ? const Color(0xffefdfd8) : scheme.primaryContainer)
        : (light ? const Color(0xffeae3e3) : scheme.surfaceContainer);
    return Tooltip(
      message: semantics,
      excludeFromSemantics: true,
      child: Semantics(
        label: semantics,
        excludeSemantics: true,
        child: Column(
          children: [
            Text(
              label,
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                color: background,
                shape: BoxShape.circle,
                border: waitingToday
                    ? Border.all(color: accent, width: 1.5)
                    : null,
              ),
              child: complete || missed
                  ? Icon(
                      activeComplete
                          ? Icons.local_fire_department_rounded
                          : missed
                          ? Icons.close_rounded
                          : Icons.check_rounded,
                      size: diameter * 0.52,
                      color: activeComplete ? scheme.onPrimary : color,
                    )
                  : Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: waitingToday
                              ? accent
                              : (light
                                    ? const Color(0xffddc2b9)
                                    : scheme.outline),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
