import 'package:flutter/material.dart';

/// Base for screen view models: holds screen state and notifies safely, even
/// after the owning screen is gone.
abstract class ViewModel extends ChangeNotifier {
  bool _disposed = false;

  bool get disposed => _disposed;

  /// Notifies listeners unless already disposed, so an async callback that
  /// lands after teardown cannot throw.
  void safeNotify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Owns a view model's lifecycle and rebuilds [builder] when it changes, so the
/// screen it renders can stay a StatelessWidget.
class ViewModelProvider<T extends ViewModel> extends StatefulWidget {
  const ViewModelProvider({
    super.key,
    required this.create,
    required this.builder,
  });

  final T Function(BuildContext context) create;
  final Widget Function(BuildContext context, T viewModel) builder;

  @override
  State<ViewModelProvider<T>> createState() => _ViewModelProviderState<T>();
}

class _ViewModelProviderState<T extends ViewModel>
    extends State<ViewModelProvider<T>> {
  late final T _viewModel;

  @override
  void initState() {
    super.initState();
    _viewModel = widget.create(context);
  }

  @override
  void dispose() {
    _viewModel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _viewModel,
    builder: (context, _) => widget.builder(context, _viewModel),
  );
}
