import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../../platform/alarm_engine.dart';
import 'alarm_editor_screen_view_model.dart';
import '../challenges/qr_sheet.dart';
import '../../shared/brand.dart';
import '../../shared/choice_pill.dart';
import '../../shared/theme.dart';
import '../../shared/toast.dart';
import 'package:provider/provider.dart';

/// Public entry for creating or editing an alarm. Stateless: it only wires the
/// view model lifecycle to [AlarmEditorScreen].
class AlarmEditor extends StatelessWidget {
  const AlarmEditor({
    super.key,
    this.existing,
    this.engine,
    this.defaultSnoozeMinutes,
    this.canCheckIn = true,
    this.canPractice = true,
    this.sharedQrValue,
  });

  final Alarm? existing;

  /// Enables tone preview only; null disables it, keeping the editor usable in tests.
  final AlarmEngine? engine;
  final int? defaultSnoozeMinutes;
  final bool canCheckIn;
  final bool canPractice;
  final String? sharedQrValue;

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AlarmEditorScreenViewModel>(
      create: (_) => AlarmEditorScreenViewModel(
        engine: engine,
        existing: existing,
        defaultSnoozeMinutes: defaultSnoozeMinutes,
        canCheckIn: canCheckIn,
        canPractice: canPractice,
        sharedQrValue: sharedQrValue,
      ),
      // The page messenger paints below the modal route. Host editor toasts
      // inside the sheet so validation and preview failures stay visible.
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.85,
        child: ScaffoldMessenger(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // Shrink above the keyboard so a focused field (the label, the QR
            // value) is scrolled into view instead of hiding behind it.
            resizeToAvoidBottomInset: true,
            body: Consumer<AlarmEditorScreenViewModel>(
              builder: (context, viewModel, _) =>
                  AlarmEditorScreen(viewModel: viewModel),
            ),
          ),
        ),
      ),
    );
  }
}

class AlarmEditorScreen extends StatelessWidget {
  const AlarmEditorScreen({super.key, required this.viewModel});

  final AlarmEditorScreenViewModel viewModel;

  /// Snooze lengths offered; zero means no snooze, the point of a strict alarm.
  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    // Use both insets; handling only the keyboard hides Save behind the nav bar.
    final media = MediaQuery.of(context);
    final bottomInset = media.viewPadding.bottom + media.viewInsets.bottom;
    return SizedBox(
      height: media.size.height * 0.85,
      child: ListView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset + 40),
        children: [
          _header(context),
          const SizedBox(height: 4),
          Text(
            'Make tomorrow morning easier',
            style: theme.textTheme.headlineMedium?.copyWith(
              letterSpacing: -0.025 * 26,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Choose a preset or customize a fail-safe awakening routine to '
            'beat morning fatigue.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.625,
            ),
          ),
          if (viewModel.existing?.needsSetup == true) ...[
            const SizedBox(height: 16),
            _infoBox(
              context,
              Icons.warning_amber_rounded,
              'This alarm needs a supported challenge before it can be turned on. Choose a challenge below. For Find an object, practice scanning your chosen target first.',
              iconColor: tokens.amber,
            ),
          ],
          _sectionTitle(
            context,
            'Quick setup',
            trailing: _badge(context, 'Fast presets', tokens.cyan),
          ),
          _panel(
            context,
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                for (final (index, name, caption, icon) in _presets) ...[
                  if (index > 0) const SizedBox(height: 6),
                  _presetTile(context, index, name, caption, icon),
                ],
              ],
            ),
          ),
          const SizedBox(height: 24),
          _timeCard(context),
          const SizedBox(height: 24),
          _labelCard(context),
          _sectionTitle(
            context,
            'Ways to stop the alarm',
            large: true,
            help:
                'Only active challenges can silence this alarm. Choose your '
                'morning wake threshold.',
            helpGap: 4,
            helpHeight: 1.5,
          ),
          _panel(
            context,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final escape in EscapeKind.values) ...[
                  if (escape.index > 0) ...[
                    const SizedBox(height: 16),
                    _rule(context),
                    const SizedBox(height: 16),
                  ],
                  // The Face choice carries its own step setting, right under it.
                  if (escape == EscapeKind.face)
                    _faceChoice(context)
                  else
                    Padding(
                      padding: EdgeInsets.only(
                        bottom: escape == EscapeKind.tap ? 12 : 0,
                      ),
                      child: _optionTile(
                        context,
                        icon: _escapeIcon(escape),
                        title: _escapeTitle(escape),
                        subtitle: _escapeHint(escape),
                        selected: viewModel.escapes.contains(escape),
                        trailing: Switch(
                          value: viewModel.escapes.contains(escape),
                          onChanged: (selected) =>
                              viewModel.toggleEscape(escape, selected),
                        ),
                        onTap: () => viewModel.toggleEscape(
                          escape,
                          !viewModel.escapes.contains(escape),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
          if (viewModel.validationError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
              child: Text(
                viewModel.validationError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          // Only when QR is on: an unused code field is one more thing to misread at 05:00.
          if (viewModel.showQrField) ...[
            const SizedBox(height: 16),
            _card(context, [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: viewModel.qrController,
                      onTapOutside: (_) =>
                          FocusManager.instance.primaryFocus?.unfocus(),
                      decoration: InputDecoration(
                        labelText: 'QR code value',
                        helperText: viewModel.qrController.text.isEmpty
                            ? 'Create a code, then print it or show it on another device away from bed.'
                            : viewModel.usesSharedQr
                            ? 'Your shared wake-up QR. Print once for all alarms using it.'
                            : 'Custom code for this alarm. Existing printed codes still work.',
                        helperMaxLines: 3,
                        suffixIcon: IconButton(
                          icon: const Icon(Icons.qr_code_2_outlined),
                          tooltip: 'Generate a custom code for this alarm',
                          onPressed: viewModel.generateCustomQrSecret,
                        ),
                      ),
                      onChanged: (_) => viewModel.clearValidation(),
                    ),
                    if (viewModel.hasQrValue)
                      TextButton.icon(
                        icon: const Icon(Icons.qr_code_scanner_outlined),
                        label: Text(
                          viewModel.usesSharedQr
                              ? 'Show wake-up QR'
                              : 'Show QR code',
                        ),
                        onPressed: () =>
                            _showQrSheet(context, viewModel.trimmedQr),
                      ),
                    if (viewModel.sharedQrValue != null &&
                        !viewModel.usesSharedQr)
                      TextButton.icon(
                        icon: const Icon(Icons.link),
                        label: const Text('Use shared wake-up QR'),
                        onPressed: viewModel.useSharedQr,
                      ),
                  ],
                ),
              ),
            ]),
          ],
          _sectionTitle(context, 'Repeat', gap: 10),
          _panel(
            context,
            padding: const EdgeInsets.all(8),
            child: Column(
              children: [
                _segmented<int>(
                  context,
                  verticalPadding: 10,
                  options: const [(0, 'Once'), (1, 'Every day'), (2, 'Custom')],
                  selected: !viewModel.repeatDaily
                      ? 0
                      : viewModel.weekdays.isEmpty
                      ? 1
                      : 2,
                  onSelected: (value) {
                    switch (value) {
                      case 0:
                        viewModel.selectOnce();
                      case 1:
                        viewModel.selectEveryDay();
                      default:
                        viewModel.selectSelectedDays();
                    }
                  },
                ),
                if (viewModel.repeatDaily && viewModel.weekdays.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    child: _dayPicker(context),
                  ),
                ],
              ],
            ),
          ),
          if (viewModel.escapes.contains(EscapeKind.object)) ...[
            _sectionTitle(context, 'Your wake-up object'),
            _card(context, [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _pillGrid([
                      for (final target in WakeObject.values)
                        ChoicePill(
                          label: target.label,
                          icon: target == WakeObject.sink
                              ? Icons.water_drop_outlined
                              : Icons.local_cafe_outlined,
                          selected: viewModel.objectTarget == target,
                          onTap: () => viewModel.setObjectTarget(target),
                        ),
                    ]),
                    const SizedBox(height: 12),
                    _infoBox(
                      context,
                      Icons.info_outline,
                      viewModel.objectTarget.description,
                    ),
                    const SizedBox(height: 8),
                    _infoBox(
                      context,
                      viewModel.objectVerified
                          ? Icons.check_circle_outline
                          : Icons.photo_camera_outlined,
                      viewModel.objectVerified
                          ? 'Practice verified on this device. Keep the target well lit and outside the bedroom.'
                          : 'Tap Practice below, choose Find an object, and point the rear camera at your target for 3 seconds. Scan it successfully once before turning this alarm on.',
                      positive: viewModel.objectVerified,
                    ),
                  ],
                ),
              ),
            ]),
          ],
          const SizedBox(height: 24),
          _panel(
            context,
            child: ListTile(
              contentPadding: const EdgeInsets.all(14),
              minVerticalPadding: 0,
              minTileHeight: 44,
              horizontalTitleGap: 14,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(32),
              ),
              leading: _well(
                context,
                Icons.music_note_outlined,
                color: _cyanDim(context),
              ),
              title: Text(
                'Sound',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '${viewModel.hasCustomSound ? viewModel.customSoundName : 'Default alarm sound'}'
                  ' · Vibration ${viewModel.vibrate ? 'on' : 'off'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              trailing: Icon(
                Icons.chevron_right,
                size: 22,
                color: scheme.onSurfaceVariant,
              ),
              onTap: viewModel.saving ? null : () => _openSoundPage(context),
            ),
          ),
          _sectionTitle(
            context,
            'Snooze duration',
            help:
                'How long alarm pauses. "No snooze" locks out excuses until '
                'solved.',
            gap: 10,
          ),
          _pillGrid([
            for (final minutes in _snoozeChoices)
              ChoicePill(
                label: minutes == 0 ? 'No snooze' : '$minutes min',
                icon: minutes == 0 ? Icons.block : Icons.snooze,
                selected: viewModel.snoozeMinutes == minutes,
                onTap: () => viewModel.setSnoozeMinutes(minutes),
              ),
          ]),
          if (viewModel.canCheckIn) ...[
            _sectionTitle(
              context,
              'Stay Awake check-in',
              titleIcon: Icon(
                Icons.verified_outlined,
                size: 18,
                color: _cyanDim(context),
              ),
              help:
                  'A push prompt tests your alertness shortly after shutdown. '
                  'Unresponsive check-ins trigger full emergency ringing.',
              helpHeight: 1.375,
              gap: 10,
            ),
            _panel(
              context,
              padding: const EdgeInsets.all(8),
              child: _pillRow([
                for (final minutes in [0, 3, 5, 10])
                  ChoicePill(
                    label: minutes == 0 ? 'Off' : '$minutes min',
                    style: ChoicePillStyle.segment,
                    selected: viewModel.checkInMinutes == minutes,
                    onTap: () => viewModel.setCheckInMinutes(minutes),
                  ),
              ]),
            ),
          ],
          if (viewModel.engine != null && viewModel.canPractice) ...[
            const SizedBox(height: 28),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  foregroundColor: _cyanDim(context),
                  backgroundColor: scheme.surfaceContainerHigh,
                  minimumSize: const Size(0, 52),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  iconSize: 20,
                  textStyle: theme.textTheme.labelLarge,
                ),
                onPressed: viewModel.practicing || viewModel.saving
                    ? null
                    : () => _practice(context),
                icon: const Icon(Icons.science_outlined),
                label: Text(
                  viewModel.practicing
                      ? 'Starting practice…'
                      : 'Practice this challenge — no alarm scheduled',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
          const SizedBox(height: 36),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 58),
                elevation: 10,
                shadowColor: Colors.black.withValues(
                  alpha: theme.brightness == Brightness.light ? 0.2 : 0.5,
                ),
                iconSize: 22,
                textStyle: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              onPressed: viewModel.saving || viewModel.practicing
                  ? null
                  : () => _save(context),
              icon: const Icon(Icons.alarm_on_outlined),
              label: Text(viewModel.saving ? 'Saving…' : 'Save alarm'),
            ),
          ),
        ],
      ),
    );
  }

  static const _presets = [
    (0, 'Simple', 'Tap to stop, with a 9 minute snooze.', Icons.alarm),
    (1, 'Challenge', 'Face check, no snooze.', Icons.psychology_outlined),
    (
      2,
      'Get out of bed',
      'Scan object away from bed, no snooze.',
      Icons.directions_walk,
    ),
  ];

  static const _weekdayLetters = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
  static const _weekdayFull = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];

  static IconData _escapeIcon(EscapeKind escape) => switch (escape) {
    EscapeKind.tap => Icons.touch_app_outlined,
    EscapeKind.face => Icons.face_outlined,
    EscapeKind.object => Icons.filter_center_focus,
    EscapeKind.qr => Icons.qr_code_scanner,
  };

  static String _escapeTitle(EscapeKind escape) => switch (escape) {
    EscapeKind.face => 'Face check',
    _ => escape.label,
  };

  static String _escapeHint(EscapeKind escape) => switch (escape) {
    EscapeKind.tap => 'Just tap the stop button. The easiest way.',
    EscapeKind.face => 'Show your face to the front camera.',
    EscapeKind.object => 'Find and scan a chosen household item.',
    EscapeKind.qr => 'Scan a code placed away from your bed.',
  };

  /// secondary-fixed-dim in dark; the scheme's deeper cyan in light.
  static Color _cyanDim(BuildContext context) {
    final theme = Theme.of(context);
    return theme.brightness == Brightness.light
        ? theme.colorScheme.secondary
        : const Color(0xff00dce6);
  }

  /// Back arrow, the mark and whether this is a new or an existing alarm.
  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      height: 64,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            iconSize: 20,
            tooltip: 'Close',
            style: IconButton.styleFrom(
              fixedSize: const Size(44, 44),
              minimumSize: const Size(44, 44),
              backgroundColor: scheme.surfaceContainerHigh.withValues(
                alpha: 0.6,
              ),
              foregroundColor: scheme.onSurface,
            ),
            // Closing returns nothing, exactly like dragging the sheet away.
            onPressed: () => Navigator.maybePop(context),
          ),
          const SizedBox(width: 8),
          const WakeGuardLogo(size: 28),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              viewModel.isExisting ? 'Edit Alarm' : 'New alarm',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium?.copyWith(
                letterSpacing: -0.025 * 18,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// A small caps badge, e.g. "FAST PRESETS" beside a section title.
  Widget _badge(BuildContext context, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: ShapeDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        shape: const StadiumBorder(),
      ),
      child: Text(
        text.toUpperCase(),
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: color,
          letterSpacing: 0.05 * 11,
        ),
      ),
    );
  }

  /// A radio-like circle that turns into a coral check when chosen.
  Widget _radioMark(BuildContext context, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = WakeTokens.of(context);
    return Container(
      width: 24,
      height: 24,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? tokens.cta : scheme.surfaceContainerHighest,
      ),
      child: selected ? Icon(Icons.check, size: 16, color: tokens.onCta) : null,
    );
  }

  /// One Quick setup row: a fixed-accent icon well, name, caption and radio.
  Widget _presetTile(
    BuildContext context,
    int index,
    String name,
    String caption,
    IconData icon,
  ) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final selected = viewModel.preset == index;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(32),
    );
    final well = switch (index) {
      1 => _well(
        context,
        icon,
        color: accentOf(context),
        background: tokens.cta.withValues(alpha: 0.2),
      ),
      2 => _well(context, icon, color: _cyanDim(context)),
      _ => _well(context, icon),
    };
    // The chosen row is lifted by its own fill; the tile itself stays untinted.
    return Material(
      color: selected
          ? scheme.surfaceContainerHigh.withValues(alpha: 0.8)
          : Colors.transparent,
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        selected: selected,
        selectedColor: scheme.onSurface,
        selectedTileColor: Colors.transparent,
        shape: shape,
        contentPadding: const EdgeInsets.all(14),
        minVerticalPadding: 0,
        minTileHeight: 44,
        horizontalTitleGap: 14,
        leading: well,
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelLarge,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            caption,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        trailing: _radioMark(context, selected),
        onTap: () => viewModel.applyPreset(index),
      ),
    );
  }

  /// A circular icon well: surface-container-high with a muted icon by default.
  Widget _well(
    BuildContext context,
    IconData icon, {
    Color? color,
    Color? background,
    double size = 44,
    double iconSize = 22,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: background ?? scheme.surfaceContainerHigh,
      ),
      child: Icon(
        icon,
        size: iconSize,
        color: color ?? scheme.onSurfaceVariant,
      ),
    );
  }

  /// The design's borderless rounded-lg (32) surface-container panel.
  Widget _panel(
    BuildContext context, {
    required Widget child,
    EdgeInsetsGeometry padding = EdgeInsets.zero,
  }) {
    final light = Theme.of(context).brightness == Brightness.light;
    return SurfaceCard(
      radius: 32,
      padding: padding,
      // Dark panels are borderless; light keeps the ghost edge on white.
      borderColor: light ? null : Colors.transparent,
      child: child,
    );
  }

  /// A 1px surface-container-highest rule between challenge rows.
  Widget _rule(BuildContext context) => Container(
    height: 1,
    color: Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
  );

  /// A pill track of equal segments; the chosen one is raised in coral text.
  Widget _segmented<T>(
    BuildContext context, {
    required List<(T, String)> options,
    required T selected,
    required ValueChanged<T> onSelected,
    double verticalPadding = 8,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final light = theme.brightness == Brightness.light;
    const shape = StadiumBorder();
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: ShapeDecoration(
        color: scheme.surfaceContainerHigh,
        shape: shape,
      ),
      child: Row(
        children: [
          for (final (i, (value, label)) in options.indexed) ...[
            if (i > 0) const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                button: true,
                selected: value == selected,
                inMutuallyExclusiveGroup: true,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: shape,
                    shadows: value == selected
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
                    color: value == selected
                        ? (light ? scheme.surface : scheme.surfaceContainer)
                        : Colors.transparent,
                    shape: shape,
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      customBorder: shape,
                      onTap: () => onSelected(value),
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: verticalPadding,
                        ),
                        child: Text(
                          label,
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: value == selected
                                ? accentOf(context)
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// "Ringing in 7 hours 42 minutes", counted in clock minutes from now.
  String _ringingIn() {
    final now = DateTime.now();
    final draft = Alarm(
      id: '',
      hour: viewModel.time.hour,
      minute: viewModel.time.minute,
      label: '',
      repeatDaily: viewModel.repeatDaily,
      weekdays: viewModel.repeatDaily ? viewModel.weekdays : const {},
    );
    DateTime minuteOf(DateTime t) =>
        DateTime(t.year, t.month, t.day, t.hour, t.minute);
    final minutes = minuteOf(
      draft.nextOccurrence(now),
    ).difference(minuteOf(now)).inMinutes;
    if (minutes <= 0) return 'Ringing in under a minute';
    String unit(int n, String word) => '$n $word${n == 1 ? '' : 's'}';
    final days = minutes ~/ (24 * 60);
    final hours = (minutes % (24 * 60)) ~/ 60;
    final mins = minutes % 60;
    return 'Ringing in ${[if (days > 0) unit(days, 'day'), if (hours > 0) unit(hours, 'hour'), if (days == 0 && mins > 0) unit(mins, 'minute')].join(' ')}';
  }

  /// The alarm time as a big tappable hero card, with a clear "tap to change" cue.
  Widget _timeCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    final accent = accentOf(context);
    final localizations = MaterialLocalizations.of(context);
    final time = viewModel.time.format(context);
    final use24 = MediaQuery.alwaysUse24HourFormatOf(context);
    final clock = use24
        ? localizations.formatTimeOfDay(
            viewModel.time,
            alwaysUse24HourFormat: true,
          )
        : '${localizations.formatHour(viewModel.time)}:'
              '${localizations.formatMinute(viewModel.time)}';
    final period = use24
        ? null
        : viewModel.time.period == DayPeriod.am
        ? localizations.anteMeridiemAbbreviation
        : localizations.postMeridiemAbbreviation;
    final cyanDim = _cyanDim(context);
    final light = theme.brightness == Brightness.light;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(32),
      side: light ? BorderSide(color: tokens.ghostBorder) : BorderSide.none,
    );
    // The two soft corner glows: dawn at top right, cyan at bottom left.
    Widget glow(Color color) => ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: Container(
        width: 128,
        height: 128,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color.withValues(alpha: 0.1),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: 'Alarm time $time. Tap to change.',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: shape,
            shadows: [
              BoxShadow(
                color: Colors.black.withValues(alpha: light ? 0.06 : 0.25),
                blurRadius: 15,
                spreadRadius: -3,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            color: light ? scheme.surfaceContainerLow : scheme.surfaceContainer,
            shape: shape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: viewModel.saving
                  ? null
                  : () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: viewModel.time,
                      );
                      if (picked != null) viewModel.setTime(picked);
                    },
              child: Stack(
                children: [
                  Positioned(top: -48, right: -48, child: glow(tokens.dawn)),
                  Positioned(bottom: -48, left: -48, child: glow(tokens.cyan)),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'ALARM TIME',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            letterSpacing: 0.05 * 11,
                          ),
                        ),
                        const SizedBox(height: 8),
                        // Shrinks instead of wrapping when the text size is huge.
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              Text(
                                clock,
                                style: theme.textTheme.displayMedium?.copyWith(
                                  letterSpacing: -0.05 * 56,
                                  fontFeatures: WakeTheme.tabular,
                                ),
                              ),
                              if (period != null) ...[
                                const SizedBox(width: 8),
                                Text(
                                  period,
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: accent,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.bedtime_outlined,
                              size: 15,
                              color: cyanDim,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                _ringingIn(),
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: cyanDim,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // The pill is the "this is tappable" signal.
                        Center(
                          child: Container(
                            // 13 + 18 + 13: the design's 44px-high pill.
                            padding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 13,
                            ),
                            decoration: ShapeDecoration(
                              color: scheme.surfaceContainerHigh,
                              shape: const StadiumBorder(),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.edit_outlined,
                                  size: 18,
                                  color: accent,
                                ),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    'Tap to change time',
                                    textAlign: TextAlign.center,
                                    style: theme.textTheme.labelMedium
                                        ?.copyWith(color: scheme.onSurface),
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
          ),
        ),
      ),
    );
  }

  /// The label as a card with an icon and a caption, instead of a bare underline.
  Widget _labelCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return _panel(
      context,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _well(context, Icons.label_outline, iconSize: 20),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: viewModel.labelController,
              onTapOutside: (_) =>
                  FocusManager.instance.primaryFocus?.unfocus(),
              textCapitalization: TextCapitalization.sentences,
              style: theme.textTheme.titleMedium,
              decoration: InputDecoration(
                labelText: 'Label',
                hintText: 'Wake up',
                hintStyle: theme.textTheme.titleMedium?.copyWith(
                  color: scheme.outlineVariant,
                ),
                filled: false,
                isDense: true,
                contentPadding: const EdgeInsets.fromLTRB(8, 10, 8, 6),
                floatingLabelBehavior: FloatingLabelBehavior.always,
                labelStyle: labelStyle,
                floatingLabelStyle: labelStyle,
                // No outline at rest; a clear rounded ring once it is focused.
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide(color: accentOf(context), width: 2),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ExcludeSemantics(
            child: Icon(
              Icons.edit_note,
              size: 20,
              color: scheme.outlineVariant,
            ),
          ),
        ],
      ),
    );
  }

  /// Lays tiles out in two even columns, like the phone's own settings pages.
  Widget _pillGrid(List<Widget> pills) {
    final rows = <Widget>[];
    for (var i = 0; i < pills.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 10));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: pills[i]),
              const SizedBox(width: 10),
              Expanded(
                child: i + 1 < pills.length ? pills[i + 1] : const SizedBox(),
              ),
            ],
          ),
        ),
      );
    }
    return Column(children: rows);
  }

  /// Short choices side by side in one even row, like a segmented pill.
  Widget _pillRow(List<Widget> pills) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < pills.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(child: pills[i]),
          ],
        ],
      ),
    );
  }

  /// A soft tinted note with an icon, for explanations and status.
  Widget _infoBox(
    BuildContext context,
    IconData icon,
    String text, {
    bool positive = false,
    Color? iconColor,
  }) {
    final theme = Theme.of(context);
    final tokens = WakeTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: positive ? tokens.cyan.withValues(alpha: 0.10) : tokens.subtle,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: tokens.ghostBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 20,
            color:
                iconColor ??
                (positive ? tokens.cyan : theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }

  /// A section heading (label-lg, or headline-sm when [large]) with optional
  /// help text, an inline icon and a trailing badge, above its content.
  Widget _sectionTitle(
    BuildContext context,
    String title, {
    String? help,
    Widget? trailing,
    Widget? titleIcon,
    bool large = false,
    double gap = 12,
    double helpGap = 2,
    double? helpHeight,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(top: 24, bottom: gap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: large
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.labelLarge,
                    ),
                  ),
                  if (titleIcon != null) ...[
                    const SizedBox(width: 8),
                    titleIcon,
                  ],
                ],
              ),
              ?trailing,
            ],
          ),
          if (help != null) ...[
            SizedBox(height: helpGap),
            Text(
              help,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: helpHeight,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A rounded panel card; rows get thin dividers.
  Widget _card(BuildContext context, List<Widget> rows, {double indent = 76}) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(Divider(height: 1, indent: indent, endIndent: 16));
      }
      children.add(rows[i]);
    }
    return _panel(
      context,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: children),
    );
  }

  /// Circular icon well: coral-tinted while its row is on.
  Widget _iconWell(BuildContext context, IconData icon, bool selected) {
    return _well(
      context,
      icon,
      color: selected ? accentOf(context) : null,
      background: selected
          ? WakeTokens.of(context).cta.withValues(alpha: 0.2)
          : null,
    );
  }

  /// The Face row with its step setting tucked underneath when it is on.
  Widget _faceChoice(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = viewModel.escapes.contains(EscapeKind.face);
    final steps = viewModel.difficulty.stepCount;
    final small = theme.textTheme.labelSmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _optionTile(
          context,
          icon: _escapeIcon(EscapeKind.face),
          title: _escapeTitle(EscapeKind.face),
          subtitle: _escapeHint(EscapeKind.face),
          selected: enabled,
          trailing: Switch(
            value: enabled,
            onChanged: (selected) =>
                viewModel.toggleEscape(EscapeKind.face, selected),
          ),
          onTap: () => viewModel.toggleEscape(EscapeKind.face, !enabled),
        ),
        if (enabled) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.brightness == Brightness.light
                  ? scheme.surfaceContainer
                  : scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(32),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    Text(
                      'Face challenge steps',
                      style: small?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    Text(
                      '$steps ${steps == 1 ? 'step' : 'steps'} required',
                      style: small?.copyWith(color: accentOf(context)),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _segmented<ChallengeDifficulty>(
                  context,
                  options: [
                    for (final difficulty in ChallengeDifficulty.values)
                      (
                        difficulty,
                        '${difficulty.label} (${difficulty.stepCount})',
                      ),
                  ],
                  selected: viewModel.difficulty,
                  onSelected: viewModel.setDifficulty,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _optionTile(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required Widget trailing,
    required VoidCallback onTap,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      // Selection is shown by the well and the check/switch only: no tinted
      // row background, so the card keeps one even colour.
      selected: selected,
      selectedColor: scheme.onSurface,
      selectedTileColor: Colors.transparent,
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 0,
      minTileHeight: 44,
      horizontalTitleGap: 14,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      leading: _iconWell(context, icon, selected),
      title: Text(title, style: theme.textTheme.labelLarge),
      subtitle: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          subtitle,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.375,
          ),
        ),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }

  /// Seven round day buttons that always fit the row, whatever the width.
  Widget _dayPicker(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = WakeTokens.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 4.0;
        final size = ((constraints.maxWidth - gap * 6) / 7)
            .clamp(28.0, 36.0)
            .toDouble();
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            for (var day = 1; day <= 7; day++)
              Semantics(
                button: true,
                selected: viewModel.weekdays.contains(day),
                label: _weekdayFull[day - 1],
                child: ExcludeSemantics(
                  child: Material(
                    color: viewModel.weekdays.contains(day)
                        ? tokens.cta
                        : scheme.surfaceContainerHigh,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: () => viewModel.toggleWeekday(
                        day,
                        !viewModel.weekdays.contains(day),
                      ),
                      child: SizedBox(
                        width: size,
                        height: size,
                        child: Center(
                          child: Text(
                            _weekdayLetters[day - 1],
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: viewModel.weekdays.contains(day)
                                  ? tokens.onCta
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Future<void> _practice(BuildContext context) async {
    final error = await viewModel.practice();
    if (error == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not start practice',
      detail: error,
    );
  }

  static const _uploadValue = '__upload__';
  static const _defaultValue = '__default__';

  /// Opens a full-page tone list, like the phone's own "Alarm tone" screen.
  /// The phone's tones are only fetched now, on tap.
  Future<void> _openSoundPage(BuildContext context) async {
    if (viewModel.canUseCustomSound) viewModel.loadSystemSounds();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        // A page-level messenger keeps toasts visible above this route.
        builder: (_) => ScaffoldMessenger(
          child: ListenableBuilder(
            listenable: viewModel,
            builder: (pageContext, _) => _soundPage(pageContext),
          ),
        ),
      ),
    );
    // Do not leave a preview playing after leaving the page.
    viewModel.engine?.stopAudibilitySample().catchError((_) {});
  }

  Widget _soundPage(BuildContext context) {
    final busy =
        viewModel.importingUri.isNotEmpty ||
        viewModel.pickingSound ||
        viewModel.saving;
    // Device tones are matched by name (it survives reload); an uploaded file
    // is the choice when nothing matches one of them.
    final chosenDevice = viewModel.systemSounds
        .where((sound) => viewModel.isSoundSelected(sound.name))
        .firstOrNull;
    final groupValue =
        chosenDevice?.id ??
        (viewModel.hasCustomSound ? _uploadValue : _defaultValue);
    final uploadChosen = groupValue == _uploadValue;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Alarm tone'),
        backgroundColor: Colors.transparent,
        scrolledUnderElevation: 0,
      ),
      body: ListView(
        // Clear the Android navigation bar / gesture area at the bottom.
        padding: EdgeInsets.fromLTRB(
          16,
          0,
          16,
          32 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          _sectionHeader(context, 'Vibration'),
          _toneCard(context, [
            SwitchListTile(
              title: const Text('Vibration'),
              subtitle: const Text(
                'The phone also vibrates while this alarm rings.',
              ),
              value: viewModel.vibrate,
              onChanged: viewModel.saving ? null : viewModel.setVibrate,
            ),
          ]),
          if (viewModel.canUseCustomSound)
            RadioGroup<String>(
              groupValue: groupValue,
              onChanged: (value) => _chooseTone(context, value, busy),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionHeader(context, 'Default'),
                  _toneCard(context, [
                    _toneRow(
                      context,
                      value: _defaultValue,
                      title: 'Default alarm sound',
                      busy: busy,
                    ),
                  ]),
                  if (viewModel.systemSoundsLoading &&
                      viewModel.systemSounds.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    ),
                  if (viewModel.systemSoundsError != null &&
                      viewModel.systemSounds.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(viewModel.systemSoundsError!),
                    ),
                  if (viewModel.systemSounds.isNotEmpty) ...[
                    _sectionHeader(context, 'Alarm tones'),
                    _toneCard(context, [
                      for (final sound in viewModel.systemSounds)
                        _toneRow(
                          context,
                          value: sound.id,
                          title: sound.name,
                          loading: viewModel.importingUri == sound.id,
                          busy: busy,
                        ),
                    ]),
                  ],
                  _sectionHeader(context, 'Your own sound'),
                  _toneCard(context, [
                    _toneRow(
                      context,
                      value: _uploadValue,
                      title: 'Upload your own sound',
                      subtitle: uploadChosen
                          ? viewModel.customSoundName
                          : 'MP3, M4A, WAV or OGG, up to 25 MB.',
                      loading: viewModel.pickingSound,
                      busy: busy,
                    ),
                    if (uploadChosen)
                      ListTile(
                        leading: const Icon(Icons.volume_up_outlined),
                        title: const Text('Play chosen sound'),
                        onTap: viewModel.previewingAny
                            ? null
                            : () => _previewCustom(context),
                      ),
                  ]),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _sectionHeader(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        text.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  /// The editor's standard card with thin dividers between its rows.
  Widget _toneCard(BuildContext context, List<Widget> rows) =>
      _card(context, rows, indent: 16);

  /// A name on the left and a radio on the right; tapping anywhere selects it.
  Widget _toneRow(
    BuildContext context, {
    required String value,
    required String title,
    String? subtitle,
    bool loading = false,
    required bool busy,
  }) {
    return ListTile(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: loading
          ? const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Radio<String>(value: value),
      onTap: () => _chooseTone(context, value, busy),
    );
  }

  /// Selecting a tone also plays it, so what is heard is what will ring.
  Future<void> _chooseTone(
    BuildContext context,
    String? value,
    bool busy,
  ) async {
    if (busy || value == null) return;
    if (value == _uploadValue) {
      await _pickSound(context);
      return;
    }
    if (value == _defaultValue) {
      viewModel.removeCustomSound();
      await viewModel.preview(viewModel.soundPack);
      return;
    }
    final sound = viewModel.systemSounds
        .where((sound) => sound.id == value)
        .firstOrNull;
    if (sound == null) return;
    // Import-then-preview so the preview is exactly what will ring.
    final error = await viewModel.selectSystemSound(sound);
    if (error != null) {
      if (!context.mounted) return;
      showAppToast(
        context,
        kind: ToastKind.error,
        message: 'Could not use that sound',
        detail: error,
      );
      return;
    }
    if (!context.mounted) return;
    await _previewCustom(context);
  }

  Future<void> _pickSound(BuildContext context) async {
    final error = await viewModel.pickCustomSound();
    if (error == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not use that sound',
      detail: error,
    );
  }

  Future<void> _previewCustom(BuildContext context) async {
    final error = await viewModel.previewCustom();
    if (error == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not play your sound',
      detail: error,
    );
  }

  Future<void> _save(BuildContext context) async {
    final alarm = await viewModel.save();
    if (!context.mounted) return;
    if (alarm == null) {
      final error = viewModel.validationError;
      if (error != null) {
        viewModel.clearValidation();
        showAppToast(
          context,
          kind: ToastKind.error,
          message: 'Alarm not saved',
          detail: error,
        );
      }
      return;
    }
    Navigator.pop(context, alarm);
  }

  void _showQrSheet(BuildContext context, String value) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Without this the sheet caps at 9/16 screen, clipping the code and labels.
      isScrollControlled: true,
      builder: (_) => QrSheet(value: value),
    );
  }
}
