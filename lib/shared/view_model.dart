import 'package:flutter/foundation.dart';

/// Shared lifecycle handling for screen state, including late async callbacks.
abstract class ViewModel extends ChangeNotifier {
  bool _disposed = false;

  bool get disposed => _disposed;

  void safeNotify() => notifyListeners();

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
