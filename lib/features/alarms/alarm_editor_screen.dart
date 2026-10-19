import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../../platform/alarm_engine.dart';
import 'alarm_editor_screen_view_model.dart';
import '../challenges/qr_sheet.dart';
import '../../shared/choice_pill.dart';
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
    // Use both insets; handling only the keyboard hides Save behind the nav bar.
    final media = MediaQuery.of(context);
    final bottomInset = media.viewPadding.bottom + media.viewInsets.bottom;
    return SizedBox(
      height: media.size.height * 0.85,
      child: ListView(
        padding: EdgeInsets.fromLTRB(24, 8, 24, bottomInset + 24),
        children: [
          Text(
            viewModel.isExisting
                ? 'Edit alarm'
                : 'Make tomorrow morning easier',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          if (viewModel.existing?.needsSetup == true) ...[
            const Text(
              'This alarm needs a supported challenge before it can be turned on. Choose a challenge below. For Find an object, practice scanning your chosen target first.',
            ),
            const SizedBox(height: 12),
          ],
          _sectionTitle(
            context,
            'Quick setup',
            help:
                'Presets set the challenge, snooze and check-in. You can customise everything below.',
          ),
          _card(context, [
            for (final (index, name, caption, icon) in _presets)
              _optionTile(
                context,
                icon: icon,
                title: name,
                subtitle: caption,
                selected: viewModel.preset == index,
                trailing: Icon(
                  viewModel.preset == index
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  color: viewModel.preset == index
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.outline,
                ),
                onTap: () => viewModel.applyPreset(index),
              ),
          ]),
          const SizedBox(height: 12),
          _timeCard(context),
          const SizedBox(height: 12),
          _labelCard(context),
          _sectionTitle(
            context,
            'Ways to stop the alarm',
            help:
                'Only the selected challenges can stop this alarm. Choose Find an '
                'object or QR and place the target outside the bedroom to get up.',
          ),
          _card(context, [
            for (final escape in EscapeKind.values)
              // The Face choice carries its own step setting, right under it.
              if (escape == EscapeKind.face)
                _faceChoice(context)
              else
                _optionTile(
                  context,
                  icon: _escapeIcon(escape),
                  title: escape.label,
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
          ]),
          if (viewModel.validationError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                viewModel.validationError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ),
          // Only when QR is on: an unused code field is one more thing to misread at 05:00.
          if (viewModel.showQrField) ...[
            const SizedBox(height: 12),
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
          _sectionTitle(context, 'Repeat'),
          _card(context, [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<int>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(value: 0, label: Text('Once')),
                        ButtonSegment(value: 1, label: Text('Every day')),
                        ButtonSegment(value: 2, label: Text('Custom')),
                      ],
                      selected: {
                        if (!viewModel.repeatDaily)
                          0
                        else if (viewModel.weekdays.isEmpty)
                          1
                        else
                          2,
                      },
                      onSelectionChanged: (value) {
                        switch (value.first) {
                          case 0:
                            viewModel.selectOnce();
                          case 1:
                            viewModel.selectEveryDay();
                          default:
                            viewModel.selectSelectedDays();
                        }
                      },
                    ),
                  ),
                  if (viewModel.repeatDaily &&
                      viewModel.weekdays.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _dayPicker(context),
                  ],
                ],
              ),
            ),
          ]),
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
          _card(context, [
            ListTile(
              leading: _iconBadge(context, Icons.music_note_outlined, false),
              title: const Text('Sound'),
              subtitle: Text(
                '${viewModel.hasCustomSound ? viewModel.customSoundName : 'Default alarm sound'}'
                ' · Vibration ${viewModel.vibrate ? 'on' : 'off'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: viewModel.saving ? null : () => _openSoundPage(context),
            ),
          ]),
          _sectionTitle(
            context,
            'Snooze',
            help:
                'How long this alarm can be put off. "No snooze" hides the '
                'snooze button entirely, so the alarm only ends when you stop it.',
          ),
          _card(context, [
            Padding(
              padding: const EdgeInsets.all(16),
              child: _pillGrid([
                for (final minutes in _snoozeChoices)
                  ChoicePill(
                    label: minutes == 0 ? 'No snooze' : '$minutes min',
                    icon: minutes == 0 ? Icons.block : Icons.snooze,
                    selected: viewModel.snoozeMinutes == minutes,
                    onTap: () => viewModel.setSnoozeMinutes(minutes),
                  ),
              ]),
            ),
          ]),
          if (viewModel.canCheckIn) ...[
            _sectionTitle(
              context,
              'Stay Awake check-in',
              help:
                  "After you stop the alarm, a reminder asks if you’re still up. Tap ‘I'm up’ within 1 minute to avoid another alarm. This is off unless you turn it on.",
            ),
            _card(context, [
              Padding(
                padding: const EdgeInsets.all(16),
                child: _pillGrid([
                  for (final minutes in [0, 3, 5, 10])
                    ChoicePill(
                      label: minutes == 0 ? 'Off' : '$minutes min',
                      icon: minutes == 0
                          ? Icons.notifications_off_outlined
                          : Icons.notifications_active_outlined,
                      selected: viewModel.checkInMinutes == minutes,
                      onTap: () => viewModel.setCheckInMinutes(minutes),
                    ),
                ]),
              ),
            ]),
          ],
          if (viewModel.engine != null && viewModel.canPractice)
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: viewModel.practicing || viewModel.saving
                    ? null
                    : () => _practice(context),
                icon: const Icon(Icons.play_circle_outline),
                label: Text(
                  viewModel.practicing
                      ? 'Starting practice…'
                      : 'Practice this challenge — no alarm scheduled',
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: viewModel.saving || viewModel.practicing
                ? null
                : () => _save(context),
            child: Text(viewModel.saving ? 'Saving…' : 'Save alarm'),
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
      'Find an object or scan a QR code away from bed, no snooze, with a '
          'check-in.',
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
    EscapeKind.face => Icons.face_retouching_natural_outlined,
    EscapeKind.object => Icons.center_focus_strong_outlined,
    EscapeKind.qr => Icons.qr_code_scanner,
  };

  static String _escapeHint(EscapeKind escape) => switch (escape) {
    EscapeKind.tap => 'Just tap the stop button. The easiest way.',
    EscapeKind.face => 'Show your face to the front camera.',
    EscapeKind.object => 'Find and scan a chosen object away from bed.',
    EscapeKind.qr => 'Scan a printed or on-screen code away from bed.',
  };

  /// The alarm time as a big tappable card, with a clear "tap to change" cue.
  Widget _timeCard(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final time = viewModel.time.format(context);
    return Semantics(
      button: true,
      label: 'Alarm time $time. Tap to change.',
      child: ExcludeSemantics(
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 2,
          shadowColor: Colors.black.withValues(alpha: 0.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
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
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              child: Column(
                children: [
                  Text(
                    'Alarm time',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  // Shrinks instead of wrapping when the phone's text size is huge.
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      time,
                      style: theme.textTheme.displayMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // The pill is the "this is tappable" signal.
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primaryContainer,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.edit_outlined,
                          size: 18,
                          color: scheme.onPrimaryContainer,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Tap to change time',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.onPrimaryContainer,
                              fontWeight: FontWeight.w600,
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

  /// The label as a card with an icon and a hint, instead of a bare underline.
  Widget _labelCard(BuildContext context) {
    return _card(context, [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            _iconBadge(context, Icons.label_outline, false),
            const SizedBox(width: 16),
            Expanded(
              child: TextField(
                controller: viewModel.labelController,
                onTapOutside: (_) =>
                    FocusManager.instance.primaryFocus?.unfocus(),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: 'Label',
                  hintText: 'Wake up',
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
                    borderSide: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 2,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ]);
  }

  /// Lays tiles out in two even columns, like the phone's own settings pages.
  Widget _pillGrid(List<Widget> pills) {
    final rows = <Widget>[];
    for (var i = 0; i < pills.length; i += 2) {
      if (i > 0) rows.add(const SizedBox(height: 8));
      rows.add(
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: pills[i]),
              const SizedBox(width: 8),
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

  /// A soft tinted note with an icon, for explanations and status.
  Widget _infoBox(
    BuildContext context,
    IconData icon,
    String text, {
    bool positive = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: positive
            ? scheme.primaryContainer.withValues(alpha: 0.6)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: positive ? scheme.primary : null),
          const SizedBox(width: 10),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }

  /// A bold heading with optional help text, above a card.
  Widget _sectionTitle(BuildContext context, String title, {String? help}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          if (help != null) ...[
            const SizedBox(height: 4),
            Text(
              help,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// White rounded card with a soft shadow; rows get thin dividers.
  Widget _card(BuildContext context, List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(const Divider(height: 1, indent: 72, endIndent: 16));
      }
      children.add(rows[i]);
    }
    // The app's standard Card colour, so every card looks the same.
    return Card(
      margin: EdgeInsets.zero,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

  Widget _iconBadge(BuildContext context, IconData icon, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    return CircleAvatar(
      backgroundColor: selected
          ? scheme.primary
          : scheme.surfaceContainerHighest,
      foregroundColor: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
      child: Icon(icon, size: 22),
    );
  }

  /// The Face row with its step setting tucked underneath when it is on.
  Widget _faceChoice(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = viewModel.escapes.contains(EscapeKind.face);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _optionTile(
          context,
          icon: _escapeIcon(EscapeKind.face),
          title: EscapeKind.face.label,
          subtitle: _escapeHint(EscapeKind.face),
          selected: enabled,
          trailing: Switch(
            value: enabled,
            onChanged: (selected) =>
                viewModel.toggleEscape(EscapeKind.face, selected),
          ),
          onTap: () => viewModel.toggleEscape(EscapeKind.face, !enabled),
        ),
        if (enabled)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Face challenge steps',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ChallengeDifficulty>(
                    showSelectedIcon: false,
                    segments: [
                      for (final difficulty in ChallengeDifficulty.values)
                        ButtonSegment(
                          value: difficulty,
                          label: Text(
                            '${difficulty.label} (${difficulty.stepCount})',
                          ),
                        ),
                    ],
                    selected: {viewModel.difficulty},
                    onSelectionChanged: (value) =>
                        viewModel.setDifficulty(value.first),
                  ),
                ),
              ],
            ),
          ),
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
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      // Selection is shown by the badge and the check/switch only: no tinted
      // row background, so the card keeps one even colour.
      selected: selected,
      selectedColor: scheme.onSurface,
      selectedTileColor: Colors.transparent,
      leading: _iconBadge(context, icon, selected),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(subtitle),
      trailing: trailing,
      onTap: onTap,
    );
  }

  /// Seven round day buttons that always fit the row, whatever the width.
  Widget _dayPicker(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 6.0;
        final size = ((constraints.maxWidth - gap * 6) / 7)
            .clamp(30.0, 46.0)
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
                        ? scheme.primary
                        : scheme.surfaceContainerHighest,
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
                            style: TextStyle(
                              fontWeight: FontWeight.w600,
                              color: viewModel.weekdays.contains(day)
                                  ? scheme.onPrimary
                                  : scheme.onSurface,
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
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// The app's standard Card with thin dividers between its rows.
  Widget _toneCard(BuildContext context, List<Widget> rows) {
    final children = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      if (i > 0) {
        children.add(const Divider(height: 1, indent: 16, endIndent: 16));
      }
      children.add(rows[i]);
    }
    return Card(
      margin: EdgeInsets.zero,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }

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
