import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A running analog clock: dark face, numerals, white hour and minute hands and
/// a thin blue second hand, like the phone's own Clock app.
class AnalogClock extends StatefulWidget {
  const AnalogClock({super.key, this.now, this.maxSize = 300});

  /// The time source; tests pass a fixed time.
  final DateTime Function()? now;

  /// The clock never grows past this many logical pixels.
  final double maxSize;

  @override
  State<AnalogClock> createState() => _AnalogClockState();
}

class _AnalogClockState extends State<AnalogClock> {
  Timer? _timer;
  late DateTime _time;

  DateTime _read() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _time = _read();
    _scheduleTick();
  }

  /// Lands just after the next second boundary so the hand moves with the clock.
  void _scheduleTick() {
    final wait = 1000 - _time.millisecond + 5;
    _timer = Timer(Duration(milliseconds: wait), () {
      if (!mounted) return;
      setState(() => _time = _read());
      _scheduleTick();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _label {
    final hour = _time.hour % 12 == 0 ? 12 : _time.hour % 12;
    final minute = _time.minute.toString().padLeft(2, '0');
    return 'Current time $hour:$minute ${_time.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth.isFinite
            ? constraints.maxWidth * 0.72
            : widget.maxSize;
        final size = math.min(available, widget.maxSize);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Center(
            // Announce the minute, not every second.
            child: Semantics(
              label: _label,
              child: ExcludeSemantics(
                child: RepaintBoundary(
                  child: CustomPaint(
                    size: Size.square(size),
                    painter: _ClockPainter(time: _time),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ClockPainter extends CustomPainter {
  _ClockPainter({required this.time});

  final DateTime time;

  static const _face = Color(0xFF181818);
  static const _bezel = Color(0xFF8C8C90);
  static const _accent = Color(0xFF2F6BFF);

  /// Offset on the circle: 0 is 12 o'clock, clockwise.
  static Offset _polar(Offset center, double radius, double angle) => Offset(
    center.dx + radius * math.sin(angle),
    center.dy - radius * math.cos(angle),
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final r = size.width / 2;

    // Soft drop shadow, bezel, then the dark face.
    canvas.drawCircle(
      center.translate(0, r * 0.03),
      r,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.28)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.07),
    );
    canvas.drawCircle(center, r, Paint()..color = _bezel);
    canvas.drawCircle(center, r * 0.985, Paint()..color = _face);

    _paintTicks(canvas, center, r);
    _paintNumerals(canvas, center, r);

    final seconds = time.second + time.millisecond / 1000;
    final minutes = time.minute + seconds / 60;
    final hours = (time.hour % 12) + minutes / 60;

    _hand(canvas, center, hours * math.pi / 6, r * 0.5, r * 0.07, r * 0.058);
    _hand(canvas, center, minutes * math.pi / 30, r * 0.78, r * 0.1, r * 0.04);
    _paintSecondHand(canvas, center, r, seconds * math.pi / 30);

    // Hub: blue ring with a dark centre.
    canvas.drawCircle(center, r * 0.04, Paint()..color = _accent);
    canvas.drawCircle(center, r * 0.018, Paint()..color = _face);
  }

  void _paintTicks(Canvas canvas, Offset center, double r) {
    for (var i = 0; i < 60; i++) {
      final angle = i * math.pi / 30;
      final isHour = i % 5 == 0;
      final isQuarter = i % 15 == 0;
      final length = isQuarter ? r * 0.1 : (isHour ? r * 0.075 : r * 0.04);
      final paint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = isHour ? r * 0.018 : r * 0.007
        ..color = isQuarter
            ? Colors.white.withValues(alpha: 0.9)
            : (isHour
                  ? const Color(0xFFB8B8BC)
                  : const Color(0xFF8A8A8E).withValues(alpha: 0.7));
      canvas.drawLine(
        _polar(center, r * 0.93 - length, angle),
        _polar(center, r * 0.93, angle),
        paint,
      );
    }
  }

  void _paintNumerals(Canvas canvas, Offset center, double r) {
    final style = TextStyle(
      color: Colors.white,
      fontSize: r * 0.17,
      fontWeight: FontWeight.w300,
    );
    for (var n = 1; n <= 12; n++) {
      final painter = TextPainter(
        text: TextSpan(text: '$n', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final at = _polar(center, r * 0.7, n * math.pi / 6);
      painter.paint(canvas, at - Offset(painter.width / 2, painter.height / 2));
    }
  }

  /// A rounded white hand reaching [length] out and [tail] behind the hub.
  void _hand(
    Canvas canvas,
    Offset center,
    double angle,
    double length,
    double tail,
    double width,
  ) {
    canvas.drawLine(
      _polar(center, -tail, angle),
      _polar(center, length, angle),
      Paint()
        ..color = Colors.white
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width,
    );
  }

  void _paintSecondHand(Canvas canvas, Offset center, double r, double angle) {
    final from = _polar(center, -r * 0.16, angle);
    final to = _polar(center, r * 0.84, angle);
    // A faint wide stroke underneath gives the hand its glow.
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = _accent.withValues(alpha: 0.55)
        ..strokeWidth = r * 0.03
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, r * 0.025),
    );
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = _accent
        ..strokeWidth = r * 0.014
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ClockPainter old) => old.time != time;
}
