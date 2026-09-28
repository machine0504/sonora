import 'package:flutter/services.dart';

import 'sonora_platform_interface.dart';

/// 基于 MethodChannel + EventChannel 的平台实现。
final class MethodChannelSonora extends SonoraPlatform {
  final MethodChannel _channel = const MethodChannel('sonora');
  final EventChannel _amplitudeChannel = const EventChannel('sonora/amplitude');
  final EventChannel _eventChannel = const EventChannel('sonora/events');

  Stream<double>? _amplitudeStream;
  Stream<SonoraRecorderEvent>? _eventStream;

  @override
  Future<bool> hasPermission() async =>
      await _channel.invokeMethod<bool>('hasPermission') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestPermission') ?? false;

  @override
  Future<bool> isAudioBusy() async {
    try {
      return await _channel.invokeMethod<bool>('isAudioBusy') ?? false;
    } on PlatformException {
      // 查询失败时不拦截录音，交由 start 的真实结果兜底。
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> warmUp() async {
    await _channel.invokeMethod<void>('warmUp');
  }

  @override
  Future<SonoraStartResult> start({
    required String path,
    int sampleRate = 44100,
    int numChannels = 1,
    int bitRate = 128000,
  }) async {
    final res = await _channel.invokeMapMethod<String, dynamic>('start', {
      'path': path,
      'sampleRate': sampleRate,
      'numChannels': numChannels,
      'bitRate': bitRate,
    });
    if (res == null) {
      return const SonoraStartResult.failed(SonoraStartFailure.unknown);
    }
    if (res['ok'] == true) return const SonoraStartResult.success();
    return SonoraStartResult.failed(
      SonoraStartFailure.fromName(res['reason'] as String?),
    );
  }

  @override
  Future<SonoraRecordResult?> stop() async {
    final res = await _channel.invokeMapMethod<String, dynamic>('stop');
    if (res == null) return null;
    final path = res['path'] as String?;
    if (path == null || path.isEmpty) return null;
    final durationMs = (res['durationMs'] as num?)?.toInt() ?? 0;
    final peak = (res['peakAmplitude'] as num?)?.toDouble() ?? 1.0;
    return SonoraRecordResult(
      path: path,
      durationMs: durationMs,
      peakAmplitude: peak.clamp(0.0, 1.0),
    );
  }

  @override
  Future<void> cancel() async {
    await _channel.invokeMethod<void>('cancel');
  }

  @override
  Future<bool> isRecording() async =>
      await _channel.invokeMethod<bool>('isRecording') ?? false;

  @override
  Stream<double> onAmplitude() {
    _amplitudeStream ??= _amplitudeChannel.receiveBroadcastStream().map<double>(
          (event) => event is num ? event.toDouble().clamp(0.0, 1.0) : 0.0,
        );
    return _amplitudeStream!;
  }

  @override
  Stream<SonoraRecorderEvent> onEvent() {
    _eventStream ??= _eventChannel
        .receiveBroadcastStream()
        .map<SonoraRecorderEvent?>(
          (event) => SonoraRecorderEvent.fromName(event as String?),
        )
        .where((event) => event != null)
        .cast<SonoraRecorderEvent>();
    return _eventStream!;
  }

  @override
  Future<void> prepareHaptics() async {
    await _channel.invokeMethod<void>('prepareHaptics');
  }

  @override
  Future<void> haptic(SonoraHaptic style, {double? intensity}) async {
    await _channel.invokeMethod<void>('haptic', {
      'style': style.name,
      if (intensity != null) 'intensity': intensity,
    });
  }

  @override
  Future<void> dispose() async {
    await _channel.invokeMethod<void>('dispose');
  }
}
