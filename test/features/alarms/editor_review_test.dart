import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wakeguard/features/alarms/alarm_editor_screen_view_model.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/platform/alarm_engine.dart';

class _PreviewEngine extends EngineUnavailable {
  Completer<void>? stopGate;
  @override
  Future<void> playAudibilitySample({
    AlarmSoundPack? soundPack,
    bool vibrate = false,
  }) async {
    throw EngineException('PREVIEW', 'Sound unavailable');
  }

  @override
  Future<void> stopAudibilitySample() async {
    await stopGate?.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'removing the last selected weekday cannot silently make an everyday alarm',
    () {
      final vm = AlarmEditorScreenViewModel(
        existing: Alarm(
          id: 'weekday',
          hour: 7,
          minute: 0,
          label: 'Monday',
          weekdays: {1},
        ),
      );
      addTearDown(vm.dispose);
      vm.toggleWeekday(1, false);
      expect(vm.weekdays, {1});
      expect(vm.validationError, isNotNull);
      vm.selectEveryDay();
      expect(vm.weekdays, isEmpty);
      expect(vm.validationError, isNull);
    },
  );

  test(
    'preview failures return feedback and release the loading state',
    () async {
      final vm = AlarmEditorScreenViewModel(engine: _PreviewEngine());
      addTearDown(vm.dispose);
      expect(
        await vm.preview(AlarmSoundPack.pulse),
        contains('Sound unavailable'),
      );
      expect(vm.previewingAny, isFalse);
    },
  );

  test(
    'repeated Save cannot return two alarms while stopping a preview',
    () async {
      final gate = Completer<void>();
      final engine = _PreviewEngine()..stopGate = gate;
      final vm = AlarmEditorScreenViewModel(engine: engine);
      addTearDown(vm.dispose);
      final first = vm.save();
      expect(await vm.save(), isNull);
      gate.complete();
      expect(await first, isNotNull);
    },
  );
}
