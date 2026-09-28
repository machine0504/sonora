import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'sonora_method_channel.dart';

/// 一次录音完成后的产物。
class SonoraRecordResult {
  const SonoraRecordResult({
    required this.path,
    required this.durationMs,
    this.peakAmplitude = 1.0,
  });

  /// 录音文件本地路径（m4a / AAC，可直接播放与上传）。
  final String path;

  /// 录音时长（毫秒）。
  final int durationMs;

  /// 整段录音的归一化峰值（0.0 ~ 1.0），由原生侧按计量采样统计。
  final double peakAmplitude;

  /// 录音时长（秒，至少 1）。
  int get durationSeconds {
    final seconds = (durationMs / 1000).round();
    return seconds < 1 ? 1 : seconds;
  }

  /// 全程几乎没有输入信号。通话中系统会把本应用的麦克风输入静音（喂全 0 数据），
  /// 录音「看起来成功」但内容是空白，据此可在发送前拦截。
  bool get isSilent => peakAmplitude < silenceThreshold;

  /// 静音判定阈值。安静环境说话也能明显高于该值，正常录音不会误判。
  static const double silenceThreshold = 0.02;

  @override
  String toString() =>
      'SonoraRecordResult(path: $path, durationMs: $durationMs, '
      'peakAmplitude: $peakAmplitude)';
}

/// 录音无法开始的原因。
enum SonoraStartFailure {
  /// 麦克风被其他应用独占（通话中、其他应用正在录音等）。
  busy,

  /// 没有麦克风权限。
  permission,

  /// 参数非法 / 编码器初始化失败等其他错误。
  unknown;

  static SonoraStartFailure fromName(String? name) {
    return SonoraStartFailure.values.firstWhere(
      (e) => e.name == name,
      orElse: () => SonoraStartFailure.unknown,
    );
  }
}

/// [SonoraPlatform.start] 的结果。
class SonoraStartResult {
  const SonoraStartResult.success()
      : ok = true,
        failure = null;

  const SonoraStartResult.failed(SonoraStartFailure this.failure) : ok = false;

  final bool ok;

  /// 仅失败时非空。
  final SonoraStartFailure? failure;

  @override
  String toString() => ok ? 'SonoraStartResult.success' : 'SonoraStartResult($failure)';
}

/// 录音过程中由原生侧主动上报的事件。收到后当次录音已作废。
enum SonoraRecorderEvent {
  /// 被系统中断：来电、其他应用抢占麦克风等。原生侧已停止并清理录音文件。
  interrupted,

  /// 音频输入被系统静音（Android 通话期间的典型表现），继续录只会得到空白。
  silenced,

  /// 编码 / 写文件出错。
  error;

  static SonoraRecorderEvent? fromName(String? name) {
    for (final value in SonoraRecorderEvent.values) {
      if (value.name == name) return value;
    }
    return null;
  }
}

/// 触感强度。原生侧映射：
/// - iOS：UIImpactFeedbackGenerator(.light/.medium/.heavy) 与 UISelectionFeedbackGenerator；
/// - Android：VibrationEffect 预设 EFFECT_TICK / EFFECT_CLICK / EFFECT_HEAVY_CLICK。
enum SonoraHaptic { light, medium, heavy, selection }

/// 平台实现接口。使用 `base` 修饰，要求平台实现「继承」而非「实现」，
/// 便于未来新增方法而不破坏既有实现。
abstract base class SonoraPlatform extends PlatformInterface {
  SonoraPlatform() : super(token: _token);

  static final Object _token = Object();

  static SonoraPlatform _instance = MethodChannelSonora();

  static SonoraPlatform get instance => _instance;

  static set instance(SonoraPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// 是否已有麦克风权限（静默查询，不弹系统框）。
  Future<bool> hasPermission() =>
      throw UnimplementedError('hasPermission() has not been implemented.');

  /// 申请麦克风权限（iOS 会弹系统框；Android 返回当前状态，申请交由宿主）。
  Future<bool> requestPermission() =>
      throw UnimplementedError('requestPermission() has not been implemented.');

  /// 麦克风当前是否被其他应用占用（通话中等），此时不应开始录音。
  Future<bool> isAudioBusy() =>
      throw UnimplementedError('isAudioBusy() has not been implemented.');

  /// 预热：提前配置音频会话 / 准备录音器，降低首帧延迟。
  Future<void> warmUp() =>
      throw UnimplementedError('warmUp() has not been implemented.');

  /// 开始录音到 [path]（m4a/AAC）。
  Future<SonoraStartResult> start({
    required String path,
    int sampleRate = 44100,
    int numChannels = 1,
    int bitRate = 128000,
  }) =>
      throw UnimplementedError('start() has not been implemented.');

  /// 停止录音，返回产物（失败返回 null）。
  Future<SonoraRecordResult?> stop() =>
      throw UnimplementedError('stop() has not been implemented.');

  /// 取消录音并删除文件。
  Future<void> cancel() =>
      throw UnimplementedError('cancel() has not been implemented.');

  /// 是否正在录音。
  Future<bool> isRecording() =>
      throw UnimplementedError('isRecording() has not been implemented.');

  /// 实时归一化振幅流（0.0 静音 ~ 1.0 最大），用于波纹动画。
  Stream<double> onAmplitude() =>
      throw UnimplementedError('onAmplitude() has not been implemented.');

  /// 录音中断 / 被静音等异常事件流。
  Stream<SonoraRecorderEvent> onEvent() =>
      throw UnimplementedError('onEvent() has not been implemented.');

  /// 预热触感发生器，首次触发不丢帧、不延迟。
  Future<void> prepareHaptics() =>
      throw UnimplementedError('prepareHaptics() has not been implemented.');

  /// 触发一次原生触感。录音过程中同样有效（iOS 已放行录音期触感）。
  /// [intensity] 仅 iOS 13+ 的 impact 生效，取值 0~1。
  Future<void> haptic(SonoraHaptic style, {double? intensity}) =>
      throw UnimplementedError('haptic() has not been implemented.');

  /// 释放原生资源。
  Future<void> dispose() =>
      throw UnimplementedError('dispose() has not been implemented.');
}
