import 'package:flutter/material.dart';

import '../../shared/brand.dart';
import '../../shared/theme.dart';
import '../../shared/toast.dart';
import 'history_screen_view_model.dart';

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

/// secondary-fixed-dim: the cyan used for passed challenges in dark mode.
const _cyanDim = Color(0xff00dce6);

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key, required this.viewModel});

  final HistoryScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final entries = viewModel.entries;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final rows = <(DateTime?, Map<String, Object?>?)>[
      for (final day in viewModel.days) ...[
        (day.date, null),
        for (final entry in day.entries) (day.date, entry),
      ],
    ];
    return Scaffold(
      appBar: const BrandAppBar(section: 'History'),
      body: RefreshIndicator(
        onRefresh: () => _refresh(context),
        child: ListView.builder(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          itemCount: rows.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Wake-up history',
                            style: theme.textTheme.headlineMedium,
                          ),
                        ),
                        if (entries.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear wake history',
                            icon: const Icon(Icons.delete_outline),
                            iconSize: 22,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 40,
                              height: 40,
                            ),
                            color: scheme.onSurfaceVariant,
                            onPressed: () => _clear(context),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _HistorySummary(viewModel: viewModel),
                  if (entries.isEmpty)
                    SurfaceCard(
                      margin: const EdgeInsets.only(top: 16),
                      radius: 32,
                      padding: const EdgeInsets.all(16),
                      color: scheme.surfaceContainerLow,
                      borderColor: Colors.transparent,
                      shadow: _shadowMd,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const ExcludeSemantics(
                            child: IconWell(
                              icon: Icons.wb_twilight_outlined,
                              size: 40,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Text(
                              'Your first morning starts the story. Completed challenges, snoozes, missed alarms and check-ins will appear here.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            }
            final (day, entry) = rows[index - 1];
            if (entry == null) {
              return _ActivityDayHeading(day: day, first: index == 1);
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
  const _ActivityDayHeading({required this.day, required this.first});
  final DateTime? day;
  final bool first;

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
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final dateStyle = text.labelMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final date = Wrap(
      spacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (relative != null) ...[
          Text(relative, style: dateStyle),
          Text(
            '•',
            style: dateStyle?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
        Text(
          day == null
              ? 'Date unavailable'
              : MaterialLocalizations.of(context).formatMediumDate(day!),
          style: dateStyle,
        ),
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(4, first ? 20 : 24, 4, 8),
      child: first
          ? Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 6,
              children: [
                Text('Activity log', style: text.headlineSmall),
                date,
              ],
            )
          : date,
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

  static const _challenges = {'face', 'object', 'qr', 'pattern'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final accent = accentOf(context);
    final event = entry['event'] as String? ?? 'dismissed';
    final failure = const {
      'missed',
      'checkin_failed',
      'checkin_expired',
      'checkin_notification_blocked',
      'checkin_notification_failed',
      'next_schedule_failed',
      'challenge_setup_required',
    }.contains(event);
    final method = entry['method'] as String? ?? '';
    final (iconColor, circleColor, glow) = failure
        ? (scheme.error, scheme.error.withValues(alpha: 0.16), null)
        : event == 'dismissed'
        ? (
            light ? scheme.secondary : _cyanDim,
            tokens.cyan.withValues(alpha: 0.2),
            tokens.cyan.withValues(alpha: 0.15),
          )
        : event == 'confirmed'
        ? (
            accent,
            tokens.cta.withValues(alpha: 0.2),
            tokens.cta.withValues(alpha: 0.25),
          )
        : (scheme.onSurfaceVariant, scheme.surfaceContainerHighest, null);
    final rawAt = entry['at'];
    final at = rawAt is num
        ? DateTime.fromMillisecondsSinceEpoch(rawAt.toInt())
        : null;
    final time = at == null ? null : TimeOfDay.fromDateTime(at).format(context);
    final date = at == null
        ? 'Date unavailable'
        : MaterialLocalizations.of(context).formatMediumDate(at);
    final rawDuration = entry['durationMs'];
    final duration = rawDuration is num && rawDuration >= 0
        ? rawDuration.toInt() ~/ 1000
        : null;
    final rawSnoozes = entry['snoozes'];
    final snoozes = rawSnoozes is num && rawSnoozes >= 0
        ? rawSnoozes.toInt()
        : null;
    final dismissed = event == 'dismissed';
    final detail = [
      date,
      HistoryScreenViewModel.eventDetail(entry),
      if (dismissed && duration != null)
        duration < 60
            ? 'Solved in $duration second${duration == 1 ? '' : 's'}'
            : 'Solved in ${duration ~/ 60}m ${duration % 60}s',
      if (dismissed && snoozes != null && snoozes > 0)
        '$snoozes snooze${snoozes == 1 ? '' : 's'}',
    ].where((part) => part.isNotEmpty).join(' • ');
    final outcome = dismissed && method.isNotEmpty
        ? _challenges.contains(method)
              ? '${HistoryScreenViewModel.methodLabel(method)} passed'
              : HistoryScreenViewModel.methodLabel(method)
        : HistoryScreenViewModel.eventLabel(event);
    final icon = switch (event) {
      'dismissed' => switch (method) {
        '' => Icons.check_circle_outline,
        'face' => Icons.sentiment_very_satisfied_outlined,
        'object' => Icons.center_focus_strong_outlined,
        'qr' => Icons.qr_code_scanner,
        'pattern' => Icons.grid_3x3,
        _ => Icons.touch_app_outlined,
      },
      'confirmed' => Icons.verified_user,
      'started' => Icons.alarm_on_outlined,
      'snoozed' => Icons.snooze_rounded,
      'checkin_scheduled' => Icons.schedule,
      'checkin_prompted' => Icons.notification_important_outlined,
      _ => failure ? Icons.error_outline_rounded : Icons.alarm_rounded,
    };
    final title = Text(
      '${entry['label'] ?? 'Alarm'} • $outcome',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.labelLarge?.copyWith(color: scheme.onSurface),
    );
    final timestamp = time == null
        ? null
        : Text(
            time,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
              fontFeatures: WakeTheme.tabular,
            ),
            textAlign: TextAlign.end,
          );
    return Container(
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.vertical(
          top: first ? const Radius.circular(32) : Radius.zero,
          bottom: last ? const Radius.circular(32) : Radius.zero,
        ),
      ),
      child: Stack(
        children: [
          if (first)
            PositionedDirectional(
              end: -32,
              top: -32,
              child: IgnorePointer(
                child: Container(
                  width: 128,
                  height: 128,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: tokens.cta.withValues(alpha: 0.05),
                        blurRadius: 40,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(
              16,
              first ? 16 : 0,
              16,
              last ? 16 : 0,
            ),
            child: Stack(
              children: [
                if (!last)
                  PositionedDirectional(
                    start: 20,
                    top: 40,
                    bottom: 0,
                    width: 2,
                    child: ColoredBox(color: scheme.surfaceContainerHighest),
                  ),
                Padding(
                  padding: EdgeInsets.only(bottom: last ? 0 : 16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: circleColor,
                            boxShadow: glow == null
                                ? null
                                : [BoxShadow(color: glow, blurRadius: 12)],
                          ),
                          child: Icon(icon, size: 20, color: iconColor),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  // Keep times right aligned without squeezing titles at large text sizes.
                                  if (timestamp == null) return title;
                                  if (constraints.maxWidth < 200 ||
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(14) >
                                          21) {
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        title,
                                        const SizedBox(height: 4),
                                        timestamp,
                                      ],
                                    );
                                  }
                                  return Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      Expanded(child: title),
                                      const SizedBox(width: 8),
                                      timestamp,
                                    ],
                                  );
                                },
                              ),
                              const SizedBox(height: 2),
                              Text(
                                detail,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
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

class _HistorySummary extends StatelessWidget {
  const _HistorySummary({required this.viewModel});
  final HistoryScreenViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final accent = accentOf(context);
    final stats = viewModel.stats;
    return SurfaceCard(
      radius: 32,
      padding: const EdgeInsets.all(16),
      color: scheme.surfaceContainerLow,
      borderColor: Colors.transparent,
      shadow: _shadowMd,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ExcludeSemantics(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: tokens.cta.withValues(alpha: 0.2),
                    boxShadow: [
                      BoxShadow(
                        color: tokens.cta.withValues(alpha: 0.2),
                        blurRadius: 16,
                      ),
                    ],
                  ),
                  child: Icon(
                    Icons.local_fire_department,
                    color: accent,
                    size: 32,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${stats.streak} scheduled-day streak',
                            style: theme.textTheme.headlineSmall,
                          ),
                        ),
                        if (stats.streak > 0) ...[
                          const SizedBox(width: 4),
                          ExcludeSemantics(
                            child: Icon(
                              Icons.verified,
                              color: tokens.dawn,
                              size: 20,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Last 7 days: ${viewModel.completed} stopped • ${viewModel.missed} missed',
                      softWrap: true,
                      textAlign: TextAlign.start,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _WeekProgress(
            days: viewModel.currentWeek,
            background: scheme.surfaceContainer,
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainer.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.info_outline,
                      size: 20,
                      color: scheme.tertiary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your streak counts completed alarms and check-ins, not how well you slept. '
                    'Days without a scheduled alarm do not break your streak.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      height: 1.625,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              '${stats.totalDays} completed days in saved history',
              style: theme.textTheme.labelSmall?.copyWith(
                color: scheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekProgress extends StatelessWidget {
  const _WeekProgress({required this.days, required this.background});
  final List<HistoryWeekDay> days;
  final Color background;
  static const _names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(11) / 11;
          // Seven columns normally; wrap at large text sizes instead of clipping
          // weekday labels or shrinking the user's accessibility font setting.
          final columns = (constraints.maxWidth / (28 * scale))
              .floor()
              .clamp(1, 7)
              .toInt();
          final width = constraints.maxWidth / columns;
          final diameter = (width - 2).clamp(24.0, 36.0).toDouble();
          return Wrap(
            runSpacing: 12,
            children: [
              for (var index = 0; index < days.length; index++)
                SizedBox(
                  width: width,
                  child: _WeekDayMarker(
                    day: days[index],
                    label: _names[index],
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
    required this.diameter,
  });
  final HistoryWeekDay day;
  final String label;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final light = theme.brightness == Brightness.light;
    final accent = accentOf(context);
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
    final background = activeComplete
        ? tokens.cta
        : missed
        ? scheme.errorContainer
        : complete
        ? tokens.onCta
        : scheme.surfaceContainerHighest;
    final foreground = activeComplete
        ? tokens.onCta
        : missed
        ? scheme.onErrorContainer
        : (light ? scheme.primaryContainer : scheme.onPrimaryContainer);
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
              style: theme.textTheme.labelSmall?.copyWith(
                color: day.isToday || complete
                    ? tokens.dawn
                    : scheme.onSurfaceVariant,
                fontWeight: day.isToday ? FontWeight.w700 : null,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              width: diameter,
              height: diameter,
              decoration: BoxDecoration(
                color: background,
                shape: BoxShape.circle,
                border: waitingToday
                    ? Border.all(color: accent, width: 1.5)
                    : null,
                boxShadow: activeComplete || waitingToday
                    ? [
                        BoxShadow(
                          color: tokens.cta.withValues(alpha: 0.45),
                          blurRadius: 12,
                        ),
                      ]
                    : null,
              ),
              child: complete || missed
                  ? Icon(
                      activeComplete
                          ? Icons.local_fire_department
                          : missed
                          ? Icons.close_rounded
                          : Icons.check_rounded,
                      size: activeComplete ? 20 : 18,
                      color: foreground,
                    )
                  : Center(
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: waitingToday ? accent : scheme.outlineVariant,
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
