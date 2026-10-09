import 'package:flutter/material.dart';

/// What a toast is telling the user; drives the icon and the palette.
enum ToastKind { success, error, info }

/// Shows a floating, rounded toast with an icon and a coloured background, so a
/// failure or a confirmation is legible at a glance instead of plain text.
void showAppToast(
  BuildContext context, {
  required ToastKind kind,
  required String message,
  String? detail,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) =>
    showToastTo(
      ScaffoldMessenger.of(context),
      Theme.of(context).colorScheme,
      kind: kind,
      message: message,
      detail: detail,
      actionLabel: actionLabel,
      onAction: onAction,
      duration: duration,
    );

/// Same as [showAppToast] for callbacks whose screen may already have unmounted,
/// such as an Undo fired from a tile that has just been dismissed: it takes the
/// messenger and colour scheme captured while the screen was still mounted, so
/// it cannot look up a dead context.
void showToastTo(
  ScaffoldMessengerState messenger,
  ColorScheme scheme, {
  required ToastKind kind,
  required String message,
  String? detail,
  String? actionLabel,
  VoidCallback? onAction,
  Duration duration = const Duration(seconds: 4),
}) {
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      backgroundColor: Colors.transparent,
      padding: EdgeInsets.zero,
      // Action snackbars persist by default; a toast must always time out.
      persist: false,
      duration: duration,
      action: actionLabel == null
          ? null
          : SnackBarAction(
              label: actionLabel,
              textColor: _foreground(kind, scheme),
              onPressed: onAction ?? () {},
            ),
      content: _ToastCard(kind: kind, message: message, detail: detail),
    ),
  );
}

Color _background(ToastKind kind, ColorScheme scheme) => switch (kind) {
      ToastKind.error => scheme.error,
      ToastKind.success => const Color(0xFF2E7D32),
      ToastKind.info => scheme.inverseSurface,
    };

Color _foreground(ToastKind kind, ColorScheme scheme) => switch (kind) {
      ToastKind.error => scheme.onError,
      ToastKind.success => Colors.white,
      ToastKind.info => scheme.onInverseSurface,
    };

class _ToastCard extends StatelessWidget {
  const _ToastCard({required this.kind, required this.message, this.detail});

  final ToastKind kind;
  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = _background(kind, scheme);
    final foreground = _foreground(kind, scheme);
    final icon = switch (kind) {
      ToastKind.error => Icons.error_rounded,
      ToastKind.success => Icons.check_circle_rounded,
      ToastKind.info => Icons.info_rounded,
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: background.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 22, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message,
                    style: TextStyle(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail!,
                      style: TextStyle(
                        color: foreground.withValues(alpha: 0.9),
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
