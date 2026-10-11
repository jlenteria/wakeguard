import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../shared/toast.dart';

/// Where users can support the project straight from their wallet.
///
/// The QR is [qrAsset]; the copyable details below mirror it.
class SupportDetails {
  const SupportDetails._();

  static const recipient = 'Jonel Lenteria';
  static const qrAsset = 'docs/banks/palawanpay.jpg';
  static const gcash = '09278020463';
  static const bpi = '4749283675';
}

/// A no-drama way to chip in: scan or copy, no accounts or tax forms.
class SupportScreen extends StatelessWidget {
  const SupportScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Support WakeGuard')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(
            'WakeGuard is free, with no ads and no accounts. If it helps you '
            'get up, you can fuel its development:',
            style: text.bodyMedium,
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset(
                      SupportDetails.qrAsset,
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Scan with GCash, BPI, or any QR Ph app.',
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Text('Or send to', style: text.titleSmall),
          const SizedBox(height: 8),
          _CopyTile(label: 'GCash', value: SupportDetails.gcash),
          _CopyTile(label: 'BPI', value: SupportDetails.bpi),
          const SizedBox(height: 8),
          Text(
            'Recipient: ${SupportDetails.recipient}',
            style: text.bodySmall,
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Every amount helps. Thank you!',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyTile extends StatelessWidget {
  const _CopyTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: Theme.of(context).textTheme.bodySmall),
      subtitle: Text(
        value,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      trailing: IconButton(
        icon: const Icon(Icons.copy_rounded),
        tooltip: 'Copy',
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: value));
          if (context.mounted) {
            showAppToast(context,
                kind: ToastKind.success, message: 'Copied $label');
          }
        },
      ),
    );
  }
}
