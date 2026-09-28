/// Sonora —— 低延迟原生录音插件（类似 record），支持 iOS / Android。
///
/// 纯录音能力，不含任何 UI：
/// ```dart
/// final recorder = SonoraRecorder();
/// await recorder.warmUp();                 // 页面 initState 预热
/// if (await recorder.hasPermission() && !await recorder.isAudioBusy()) {
///   final started = await recorder.start(path: '/xxx/voice.m4a');
///   if (!started.ok) { /* started.failure 区分「通话占用」等原因 */ }
///   final sub = recorder.onAmplitude().listen((a) { /* 驱动波纹 */ });
///   // ...
///   final result = await recorder.stop();  // result.path / result.durationSeconds
///   await sub.cancel();
/// }
/// ```
library sonora;

import 'sonora_platform_interface.dart';

export 'sonora_platform_interface.dart'
    show
        SonoraHaptic,
        SonoraRecordResult,
        SonoraRecorderEvent,
        SonoraStartFailure,
        SonoraStartResult;

/// 录音门面（单例）。所有调用转发到平台实现。
class SonoraRecorder {
  SonoraRecorder._();

  static final SonoraRecorder instance = SonoraRecorder._();

  factory SonoraRecorder() => instance;

  SonoraPlatform get _platform => SonoraPlatform.instance;

  /// 是否已有麦克风权限（静默查询）。
  Future<bool> hasPermission() => _platform.hasPermission();

  /// 申请麦克风权限。
  Future<bool> requestPermission() => _platform.requestPermission();

  /// 麦克风是否正被其他应用占用（微信 / 系统通话等）。
  ///
  /// 通话期间强行开录：iOS 会激活会话失败或录到静音，Android 系统会把输入静音，
  /// 都属于「看起来在录、实际录不到」，应在按下时就拦掉。
  Future<bool> isAudioBusy() => _platform.isAudioBusy();

  /// 预热：提前配置音频会话 / 准备录音器，降低首帧延迟。
  Future<void> warmUp() => _platform.warmUp();

  /// 开始录音到 [path]（建议以 .m4a 结尾）。
  Future<SonoraStartResult> start({
    required String path,
    int sampleRate = 44100,
    int numChannels = 1,
    int bitRate = 128000,
  }) =>
      _platform.start(
        path: path,
        sampleRate: sampleRate,
        numChannels: numChannels,
        bitRate: bitRate,
      );

  /// 停止录音，返回产物。
  Future<SonoraRecordResult?> stop() => _platform.stop();

  /// 取消录音并删除文件。
  Future<void> cancel() => _platform.cancel();

  /// 是否正在录音。
  Future<bool> isRecording() => _platform.isRecording();

  /// 实时归一化振幅流（0.0 ~ 1.0）。
  Stream<double> onAmplitude() => _platform.onAmplitude();

  /// 录音被中断 / 被静音等异常事件流，收到即代表当次录音作废。
  Stream<SonoraRecorderEvent> onEvent() => _platform.onEvent();

  /// 预热触感发生器（建议在 initState 与 [warmUp] 一起调用）。
  Future<void> prepareHaptics() => _platform.prepareHaptics();

  /// 触发一次原生触感，录音过程中同样有效。
  Future<void> haptic(SonoraHaptic style, {double? intensity}) =>
      _platform.haptic(style, intensity: intensity);

  /// 释放原生资源。
  Future<void> dispose() => _platform.dispose();
}
