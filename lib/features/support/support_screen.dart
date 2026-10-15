import 'package:flutter/material.dart';

/// Where users can support the project straight from their wallet.
///
/// The QR is [qrAsset].
class SupportDetails {
  const SupportDetails._();

  static const qrAsset = 'docs/banks/bpi.jpg';
}

/// A no-drama way to chip in: scan, no accounts or tax forms.
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
            'WakeGuard is free, with no ads and no accounts. Every feature is '
            'available to everyone. If you would like to, you can send an '
            'optional, voluntary tip directly to the developer. It unlocks '
            'nothing and gives no rewards.',
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
                    'Scan with any QR Ph app. This is a direct person-to-person '
                    'transfer to the developer, not a purchase.',
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              'Never required. Thank you for using WakeGuard!',
              style: text.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
