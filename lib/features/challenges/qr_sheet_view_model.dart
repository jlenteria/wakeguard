import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/view_model.dart';

/// Renders a wake-up code to a shareable PNG; plain text is shown as a fallback.
class QrSheetViewModel extends ViewModel {
  QrSheetViewModel(this.value);

  final String value;

  /// Captures the rendered [RepaintBoundary] for the shared image.
  final GlobalKey boundaryKey = GlobalKey();

  bool _saving = false;

  bool get saving => _saving;

  /// Renders the code to a PNG and shares it; deliberate over the photo library,
  /// which would need storage permission denied right when a print is wanted.
  /// Returns an error message, or null on success.
  Future<String?> saveImage({Rect? origin}) async {
    _saving = true;
    safeNotify();
    try {
      final boundary = boundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('the code is not on screen yet');
      }
      // 4x so a printed copy, or a photo of the screen, still resolves.
      final image = await boundary.toImage(pixelRatio: 4);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final bytes = data?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) {
        throw StateError('the code could not be encoded as an image');
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/wakeguard-qr.png');
      await file.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          subject: 'WakeGuard alarm code',
          text: 'WakeGuard QR code for the alarm: $value',
          sharePositionOrigin: origin,
        ),
      );
      return null;
    } catch (error) {
      return '$error';
    } finally {
      _saving = false;
      safeNotify();
    }
  }
}
