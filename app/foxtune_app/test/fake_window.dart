import 'package:flutter/foundation.dart';
import 'package:foxtune_app/src/window/window_controls.dart';
import 'package:foxtune_app/src/window/window_frame.dart';

/// A window that records what is asked of it, and changes state only as a
/// test says - as the desktop would report it.
class FakeWindow implements WindowControls {
  FakeWindow({this.nativeFrameFixed, this.hasNativeTrafficLights = false});

  final calls = <String>[];

  /// The frames [applyFrame] was given, in order.
  final applied = <WindowFrame>[];

  @override
  final ValueNotifier<bool> maximized = ValueNotifier(false);

  @override
  final ValueNotifier<bool> focused = ValueNotifier(true);

  @override
  final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  @override
  final bool? nativeFrameFixed;

  @override
  final bool hasNativeTrafficLights;

  @override
  Future<void> applyFrame(WindowFrame frame) async => applied.add(frame);

  @override
  Future<void> startDragging() async => calls.add('startDragging');

  @override
  Future<void> minimize() async => calls.add('minimize');

  @override
  Future<void> toggleMaximize() async => calls.add('toggleMaximize');

  @override
  Future<void> setFullScreen(bool on) async {
    calls.add('setFullScreen($on)');
    fullScreen.value = on;
  }

  @override
  Future<void> close() async => calls.add('close');
}
