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
}) => showToastTo(
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
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      elevation: 0,
      backgroundColor: Colors.transparent,
      padding: EdgeInsets.zero,
      // Action snackbars persist by default; a toast must always time out.
      persist: false,
      duration: duration,
      content: _ToastCard(
        scheme: scheme,
        kind: kind,
        message: message,
        detail: detail,
        actionLabel: actionLabel,
        onAction: () {
          messenger.hideCurrentSnackBar();
          onAction?.call();
        },
      ),
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
  const _ToastCard({
    required this.scheme,
    required this.kind,
    required this.message,
    this.detail,
    this.actionLabel,
    this.onAction,
  });

  final ToastKind kind;
  final ColorScheme scheme;
  final String message;
  final String? detail;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final background = _background(kind, scheme);
    final foreground = _foreground(kind, scheme);
    final icon = switch (kind) {
      ToastKind.error => Icons.error_rounded,
      ToastKind.success => Icons.check_circle_rounded,
      ToastKind.info => Icons.info_rounded,
    };
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: foreground.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: background.withValues(alpha: 0.35),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: foreground.withValues(alpha: 0.14),
              ),
              child: Icon(icon, size: 20, color: foreground),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    message,
                    style: (text.titleSmall ?? const TextStyle()).copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      detail!,
                      style: (text.bodySmall ?? const TextStyle()).copyWith(
                        color: foreground.withValues(alpha: 0.9),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (actionLabel != null) ...[
              const SizedBox(width: 8),
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: foreground,
                  backgroundColor: foreground.withValues(alpha: 0.12),
                  shape: const StadiumBorder(),
                ),
                onPressed: onAction,
                child: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
