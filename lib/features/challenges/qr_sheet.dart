import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'qr_sheet_view_model.dart';
import '../../shared/toast.dart';
import '../../shared/view_model.dart';

/// Renders [value] as a shareable QR code; plain text is shown too as a fallback.
class QrSheet extends StatelessWidget {
  const QrSheet({super.key, required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return ViewModelProvider<QrSheetViewModel>(
      create: (_) => QrSheetViewModel(value),
      builder: (context, viewModel) => QrSheetScreen(viewModel: viewModel),
    );
  }
}

class QrSheetScreen extends StatelessWidget {
  const QrSheetScreen({super.key, required this.viewModel});

  final QrSheetViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    // Apply both viewPadding (nav bar) and viewInsets (keyboard) here, with
    // SafeArea off, so the insets are applied once instead of two disagreeing ways.
    final media = MediaQuery.of(context);
    final navBar = media.viewPadding.bottom;
    final keyboard = media.viewInsets.bottom;

    final available = media.size.width - 72;
    final qrSize = available.clamp(160.0, 300.0);

    return SafeArea(
      top: false,
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + navBar + keyboard),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Scan to stop the alarm',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            RepaintBoundary(
              key: viewModel.boundaryKey,
              // Transparent background shares as a black square on dark themes; force white.
              child: ColoredBox(
                color: Colors.white,
                child: QrImageView(
                  data: viewModel.value,
                  size: qrSize,
                  backgroundColor: Colors.white,
                  // qr_flutter renders encode failures as a blank square users mistake for "will not scan".
                  errorStateBuilder: (context, error) => SizedBox(
                    width: qrSize,
                    height: qrSize,
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 32,
                          color: Colors.black87,
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Could not show this QR code.\nTry a shorter code value in the alarm editor.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(
              viewModel.value,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Print this code or show it on another device away from bed. '
              'If it will not scan, improve the lighting and keep the whole code in view.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: viewModel.saving || viewModel.printing
                        ? null
                        : () => _saveImage(context),
                    icon: viewModel.saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined),
                    label: Text(viewModel.saving ? 'Preparing…' : 'Save image'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: viewModel.printing || viewModel.saving
                        ? null
                        : () => _print(context),
                    icon: viewModel.printing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.print_outlined),
                    label: Text(viewModel.printing ? 'Preparing…' : 'Print'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImage(BuildContext context) async {
    final error = await viewModel.saveImage(origin: _shareOrigin(context));
    if (error == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not save the code',
      detail: error,
    );
  }

  Future<void> _print(BuildContext context) async {
    final error = await viewModel.printCode();
    if (error == null || !context.mounted) return;
    showAppToast(
      context,
      kind: ToastKind.error,
      message: 'Could not print the code',
      detail: error,
    );
  }

  /// iPad/macOS need a popover anchor rect, or the share sheet never appears.
  Rect? _shareOrigin(BuildContext context) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
