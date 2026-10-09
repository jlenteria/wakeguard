import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/core/alarm.dart';
import 'package:wakeguard/core/alarm_controller.dart';
import 'package:wakeguard/core/alarm_repository.dart';
import 'package:wakeguard/platform/alarm_engine.dart';

/// In-memory engine, so the tests exercise the controller's queueing and
/// reconciliation rather than a platform channel.
class _FakeEngine implements AlarmEngine {
  @override
  Future<void> practice(Alarm alarm) async {}
  @override
  Future<void> clearHistory() async {}
  final List<Alarm> store = [];
  final List<String> log = [];
  bool failSchedule = false;
  bool failStopAudibility = false;
  Completer<void>? scheduleGate;

  @override
  Future<EngineCapabilities> capabilities() async => const EngineCapabilities(
        canLoopWhileBackgrounded: true,
        canLockScreenTakeover: true,
        canUseCameraInBackground: true,
        canBypassSilentSwitch: false,
        pendingSlotCap: null,
      );

  @override
  Future<void> schedule(Alarm alarm, DateTime triggerAt) async {
    log.add('schedule:${alarm.id}');
    await scheduleGate?.future;
    if (failSchedule) {
      throw EngineException('schedule', 'boom');
    }
    store.removeWhere((a) => a.id == alarm.id);
    store.add(alarm);
  }

  @override
  Future<void> cancel(String alarmId) async {
    log.add('cancel:$alarmId');
    store.removeWhere((a) => a.id == alarmId);
  }

  @override
  Future<List<Alarm>> nativeAlarms() async {
    log.add('read');
    return List.of(store);
  }

  @override
  Future<List<Map<String, Object?>>> history() async => const [];

  @override
  Future<void> dismiss(String alarmId, {required String method}) async {}

  @override
  Future<List<HealthCheck>> health() async => const [];

  @override
  Future<List<String>> notificationsReady() async => const [];

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<void> playAudibilitySample({AlarmSoundPack? soundPack}) async {}

  @override
  Future<void> stopAudibilitySample() async {
    log.add('stopAudibility');
    if (failStopAudibility) {
      throw EngineException('MISSING_PLUGIN', 'no engine');
    }
  }

  @override
  Future<String?> openFixAction(String action) async => null;

  @override
  Future<Map<String, Object?>> launchDetails() async => const {};
}

Alarm _alarm(String id, {int hour = 7, bool enabled = true}) =>
    Alarm(id: id, hour: hour, minute: 0, label: id, enabled: enabled);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeEngine engine;
  late AlarmController controller;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    engine = _FakeEngine();
    controller = AlarmController(
      engine: engine,
      repository: AlarmRepository(),
    );
    await controller.attach();
  });

  tearDown(() => controller.dispose());

  test('starts empty with no fatal error', () {
    expect(controller.alarms, isEmpty);
    expect(controller.fatalError, isNull);
    expect(controller.loading, isFalse);
  });

  test('upsert saves to the mirror and arms the platform', () async {
    await controller.upsert(_alarm('a'));

    expect(controller.alarms.map((a) => a.id), ['a']);
    expect(engine.log, contains('schedule:a'));
    expect(engine.store.single.enabled, isTrue);
  });

  test('rapid delete-then-undo keeps the alarm (mutations are queued)',
      () async {
    await controller.upsert(_alarm('a'));
    engine.log.clear();

    // Fired without awaiting, exactly like a user tapping Undo.
    final deleting = controller.delete(controller.alarms.single);
    final undoing = controller.upsert(_alarm('a'));
    await Future.wait([deleting, undoing]);

    expect(controller.alarms.map((a) => a.id), ['a']);
    expect(engine.store.map((a) => a.id), ['a']);
  });

  test('rapid upsert-then-delete ends with the alarm gone', () async {
    await controller.upsert(_alarm('a'));

    final saving = controller.upsert(_alarm('a', hour: 8));
    final deleting = controller.delete(_alarm('a'));
    await Future.wait([saving, deleting]);

    expect(controller.alarms, isEmpty);
    expect(engine.store, isEmpty);
  });

  test('a platform store that retired the alarm corrects the mirror',
      () async {
    await controller.upsert(_alarm('a'));
    engine.store.clear(); // e.g. fired while the app was closed
    engine.store.add(_alarm('a', enabled: false));

    await controller.reload();

    expect(controller.alarms.single.enabled, isFalse);
    expect(controller.unresolvedChecks, isEmpty);
  });

  test('an alarm missing natively is re-armed rather than dropped',
      () async {
    await controller.upsert(_alarm('a'));
    engine.store.clear();

    await controller.reload();

    expect(controller.alarms.map((a) => a.id), ['a']);
    expect(engine.store.map((a) => a.id), ['a']);
  });

  test('a scheduling failure surfaces as an error and keeps the list',
      () async {
    engine.failSchedule = true;

    await controller.upsert(_alarm('a'));

    expect(controller.lastError, contains('schedule'));
    expect(controller.alarms.map((a) => a.id), ['a']);
  });

  test('delete clears a scheduling error', () async {
    engine.failSchedule = true;
    await controller.upsert(_alarm('a'));
    engine.failSchedule = false;

    await controller.delete(controller.alarms.single);

    expect(controller.lastError, isNull);
    expect(controller.alarms, isEmpty);
  });

  test('resume reconciliation waits for an in-flight edit', () async {
    await controller.upsert(_alarm('a'));
    engine.log.clear();
    engine.scheduleGate = Completer<void>();
    final editing = controller.upsert(_alarm('a', hour: 9));
    final resuming = controller.reload();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(engine.log, ['schedule:a']);
    engine.scheduleGate!.complete();
    await Future.wait([editing, resuming]);
    expect(controller.alarms.single.hour, 9);
    expect(engine.store.single.hour, 9);
  });

  test('duplicate is independent and disabled until the user enables it', () async {
    await controller.upsert(_alarm('a'));
    await controller.duplicate(controller.alarms.single);
    expect(controller.alarms.length, 2);
    final copy = controller.alarms.firstWhere((a) => a.id != 'a');
    expect(copy.enabled, isFalse);
    expect(copy.label, 'a (copy)');
    expect(controller.droppedAlarms, isEmpty);
  });

  test('stopping the audibility sample is best effort', () async {
    await controller.stopAudibilitySample();
    expect(engine.log, contains('stopAudibility'));
    expect(controller.lastError, isNull);

    engine.log.clear();
    engine.failStopAudibility = true;
    await controller.stopAudibilitySample();
    expect(controller.lastError, isNull);
  });
}
