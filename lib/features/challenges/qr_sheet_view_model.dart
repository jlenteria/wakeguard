import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../shared/view_model.dart';

/// Renders a wake-up code to a shareable PNG; plain text is shown as a fallback.
class QrSheetViewModel extends ViewModel {
  QrSheetViewModel(this.value);

  final String value;

  /// Captures the rendered [RepaintBoundary] for the shared image.
  final GlobalKey boundaryKey = GlobalKey();

  bool _saving = false;
  bool _printing = false;

  bool get saving => _saving;
  bool get printing => _printing;

  /// Renders the code to a PNG and shares it; deliberate over the photo library,
  /// which would need storage permission denied right when a print is wanted.
  /// Returns an error message, or null on success.
  Future<String?> saveImage({Rect? origin}) async {
    if (_saving || _printing) return null;
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

  /// Opens the system print dialog with a ready-to-pin page: the code, its
  /// text fallback, and a line of context. Returns an error message, or null.
  Future<String?> printCode() async {
    if (_printing || _saving) return null;
    _printing = true;
    safeNotify();
    try {
      await Printing.layoutPdf(
        name: 'WakeGuard alarm code',
        format: PdfPageFormat.a4,
        onLayout: (format) async {
          final doc = pw.Document();
          doc.addPage(
            pw.Page(
              pageFormat: format,
              margin: const pw.EdgeInsets.all(24),
              build: (context) => pw.Center(
                child: pw.FittedBox(
                  child: pw.Column(
                    mainAxisSize: pw.MainAxisSize.min,
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      pw.Text(
                        'WakeGuard',
                        style: pw.TextStyle(
                          fontSize: 30,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                      pw.SizedBox(height: 8),
                      pw.Text(
                        'Scan this code to stop your alarm.',
                        style: const pw.TextStyle(fontSize: 14),
                      ),
                      pw.SizedBox(height: 32),
                      pw.BarcodeWidget(
                        barcode: pw.Barcode.qrCode(),
                        data: value,
                        width: 320,
                        height: 320,
                      ),
                      pw.SizedBox(height: 24),
                      pw.Text(value, style: const pw.TextStyle(fontSize: 16)),
                      pw.SizedBox(height: 8),
                      pw.Text(
                        'If the code will not scan, type the code in instead.',
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          return doc.save();
        },
      );
      return null;
    } catch (error) {
      return '$error';
    } finally {
      _printing = false;
      safeNotify();
    }
  }
}
