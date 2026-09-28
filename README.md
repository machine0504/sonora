# Sonora

iOS 与 Android 的低延迟录音插件。只录音，不做语音识别，也不带界面。

适合「按住说话」：开始录音、实时振幅、静音或被通话打断时收到事件，停止后拿到 m4a 路径和时长。

## 环境

- Flutter 3.10+
- iOS / Android

## 接入

`pubspec.yaml`：

```yaml
dependencies:
  sonora:
    git:
      url: https://github.com/machine0504/sonora.git
```

```dart
import 'package:sonora/sonora.dart';

final recorder = SonoraRecorder();
await recorder.warmUp();
if (await recorder.hasPermission() && !await recorder.isAudioBusy()) {
  final started = await recorder.start(path: '/path/to/voice.m4a');
  if (!started.ok) {
    // started.failure 区分通话占用等原因
  }
  final sub = recorder.onAmplitude().listen((level) {});
  final result = await recorder.stop();
  await sub.cancel();
}
```

iOS 需要在宿主 `Info.plist` 增加麦克风用途说明 `NSMicrophoneUsageDescription`。Android 需要录音权限。

## 不包含

语音转文字、上传、聊天界面都不在这个包里。
