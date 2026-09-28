import AVFoundation
import CallKit
import Flutter
import UIKit

/**
 * Sonora 录音插件 iOS 实现。
 *
 * 使用 AVAudioRecorder 直接录制 m4a(AAC)；warmUp 预配置 AVAudioSession 以消除首帧延迟；
 * 通过 60ms 定时器读取 averagePower 计量，经 EventChannel 推送归一化振幅（0~1）。
 *
 * 通话占用：系统电话与走 CallKit 的 VoIP 由 CXCallObserver 捕获；中国大陆区 VoIP 不走
 * CallKit（微信语音通话即属此类），改由「其他 App 正在放音 + 会话激活失败 + record()
 * 失败」三重信号兜底。录音期间被抢占则由中断通知主动作废并上报，避免 UI 停在录音态。
 */
public class SonoraPlugin: NSObject, FlutterPlugin, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var currentPath: String?
    private var startTime: Date?
    private var peakAmplitude: Double = 0.0
    private let minDb: Float = -45.0

    private let amplitudeStream = SonoraStreamHandler()
    private let eventStream = SonoraStreamHandler()

    /// 观察系统范围内的 CallKit 通话（系统电话 / 支持 CallKit 的 VoIP）。
    private let callObserver = CXCallObserver()

    /// 会话是否由本插件激活。激活后 isOtherAudioPlaying 会被我们自己的会话影响，
    /// 不能再作为「其他 App 占用麦克风」的判据。
    private var sessionActivated = false

    /// 待执行的会话释放。连录期间会被下一次开录取消，避免反复激活。
    private var pendingDeactivate: DispatchWorkItem?
    private let deactivateDelay: TimeInterval = 2.0

    private var lightGenerator: UIImpactFeedbackGenerator?
    private var mediumGenerator: UIImpactFeedbackGenerator?
    private var heavyGenerator: UIImpactFeedbackGenerator?
    private var selectionGenerator: UISelectionFeedbackGenerator?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = SonoraPlugin()
        let channel = FlutterMethodChannel(name: "sonora", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: channel)
        FlutterEventChannel(name: "sonora/amplitude", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance.amplitudeStream)
        FlutterEventChannel(name: "sonora/events", binaryMessenger: registrar.messenger())
            .setStreamHandler(instance.eventStream)
        instance.observeInterruptions()
    }

    deinit {
        pendingDeactivate?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            result(hasPermission())
        case "requestPermission":
            requestPermission { granted in result(granted) }
        case "isAudioBusy":
            result(isAudioBusy())
        case "warmUp":
            prepareSession()
            result(nil)
        case "start":
            let args = call.arguments as? [String: Any] ?? [:]
            start(args: args, result: result)
        case "stop":
            stop(result: result)
        case "cancel":
            cancel()
            result(nil)
        case "isRecording":
            result(recorder?.isRecording ?? false)
        case "prepareHaptics":
            prepareHaptics()
            result(nil)
        case "haptic":
            let args = call.arguments as? [String: Any] ?? [:]
            let style = (args["style"] as? String) ?? "medium"
            let intensity = (args["intensity"] as? NSNumber)?.doubleValue
            performHaptic(style: style, intensity: intensity)
            result(nil)
        case "dispose":
            cancel()
            releaseHaptics()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Permission

    private func hasPermission() -> Bool {
        return AVAudioSession.sharedInstance().recordPermission == .granted
    }

    private func requestPermission(_ completion: @escaping (Bool) -> Void) {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            completion(true)
        case .denied:
            completion(false)
        default:
            session.requestRecordPermission { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        }
    }

    // MARK: - Busy detection

    /// 麦克风是否被别的通话占用。宁可漏判也不误判：只在有明确通话信号时返回 true，
    /// 单纯放音乐 / 播客不算占用（此类音频本就允许被录音打断）。
    private func isAudioBusy() -> Bool {
        if hasActiveSystemCall() { return true }
        let session = AVAudioSession.sharedInstance()
        // 输入被独占时系统直接报告麦克风不可用。
        if !session.isInputAvailable { return true }
        // 会话已被我们激活时，isOtherAudioPlaying 反映的是「能否与我们混音」而非
        // 对方是否在通话，此时该信号不可用，交给 start 的真实结果兜底。
        if sessionActivated { return false }
        // 未激活时若仍有其他 App 在放音，且其音频不可被降级（通话即如此），判为占用。
        return session.isOtherAudioPlaying && session.secondaryAudioShouldBeSilencedHint
    }

    private func hasActiveSystemCall() -> Bool {
        return callObserver.calls.contains { !$0.hasEnded }
    }

    // MARK: - Session

    /// 只配置类目、不激活。激活会中断其他 App 的音频，预热阶段不应有副作用，
    /// 且提前激活会让 isOtherAudioPlaying 失去判据价值。
    private func prepareSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .default,
                options: [.defaultToSpeaker, .allowBluetooth]
            )
        } catch {
            NSLog("[sonora] prepare session failed: \(error)")
        }
        allowHapticsDuringRecording()
    }

    @discardableResult
    private func activateSession() -> Bool {
        pendingDeactivate?.cancel()
        pendingDeactivate = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: [])
            sessionActivated = true
            allowHapticsDuringRecording()
            return true
        } catch {
            NSLog("[sonora] activate session failed: \(error)")
            return false
        }
    }

    /// 释放会话，让被我们打断的其他 App（通话、音乐）自动恢复。
    ///
    /// 延后执行有两个原因：setActive(false) 本身耗时，不该挡住 stop/cancel 的结果回传；
    /// 而且连续录几条时立刻释放会让每次开录都要重新激活会话（约几十毫秒），直接拖慢
    /// 「按下到真正开始录」的响应。窗口内若又开录，[activateSession] 会取消这次释放。
    private func deactivateSession() {
        guard sessionActivated, pendingDeactivate == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.pendingDeactivate = nil
            guard self.recorder == nil, self.sessionActivated else { return }
            self.sessionActivated = false
            try? AVAudioSession.sharedInstance()
                .setActive(false, options: [.notifyOthersOnDeactivation])
        }
        pendingDeactivate = item
        DispatchQueue.main.asyncAfter(deadline: .now() + deactivateDelay, execute: item)
    }

    /// 系统默认在录音期间静音触感，且该开关会随 category 变更被重置，
    /// 因此配置会话与每次开录前都要重新放行，否则录音中（如上滑取消）震不出来。
    private func allowHapticsDuringRecording() {
        guard #available(iOS 13.0, *) else { return }
        do {
            try AVAudioSession.sharedInstance()
                .setAllowHapticsAndSystemSoundsDuringRecording(true)
        } catch {
            NSLog("[sonora] allow haptics during recording failed: \(error)")
        }
    }

    // MARK: - Interruption

    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(handleInterruption(_:)),
                           name: AVAudioSession.interruptionNotification, object: nil)
        center.addObserver(self, selector: #selector(handleMediaServicesReset(_:)),
                           name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
    }

    /// 来电 / 其他 App 抢占麦克风时，AVAudioRecorder 会被系统暂停且不会自行恢复。
    /// 直接作废本次录音并上报，让 Flutter 侧收起录音态，而不是停在「正在录音」。
    @objc private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        guard type == .began else { return }
        runOnMain {
            guard self.recorder != nil else { return }
            self.cancel()
            self.eventStream.send("interrupted")
        }
    }

    @objc private func handleMediaServicesReset(_ note: Notification) {
        runOnMain {
            self.sessionActivated = false
            guard self.recorder != nil else { return }
            self.cancel()
            self.eventStream.send("interrupted")
        }
    }

    public func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        NSLog("[sonora] encode error: \(String(describing: error))")
        runOnMain {
            guard self.recorder != nil else { return }
            self.cancel()
            self.eventStream.send("error")
        }
    }

    public func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        runOnMain {
            guard self.recorder != nil else { return }
            self.cancel()
            self.eventStream.send("interrupted")
        }
    }

    // MARK: - Record

    private func start(args: [String: Any], result: @escaping FlutterResult) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            result(["ok": false, "reason": "unknown"])
            return
        }
        guard hasPermission() else {
            result(["ok": false, "reason": "permission"])
            return
        }
        // 通话中开录只会得到静音文件，且会把对方的通话音频掐断，必须拒绝。
        if hasActiveSystemCall() {
            result(["ok": false, "reason": "busy"])
            return
        }

        let sampleRate = (args["sampleRate"] as? Int) ?? 44100
        let channels = (args["numChannels"] as? Int) ?? 1
        let bitRate = (args["bitRate"] as? Int) ?? 128000

        // 语音播放走 just_audio + audio_session，会把共享的 AVAudioSession 切到
        // .playback（纯播放，不支持录音输入），且播放结束/撤回后不会切回。若沿用该
        // 类目创建 AVAudioRecorder，record() 会直接失败（表现为「播放/撤回语音后再
        // 按住说话失败」）。因此每次开录前都强制切回 .playAndRecord 并重新激活会话，
        // 而不是依赖缓存跳过（setCategory/setActive 幂等，开销极小）。
        // 激活失败几乎只有一种原因：会话被更高优先级的通话独占。
        guard activateSession() else {
            result(["ok": false, "reason": "busy"])
            return
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ]

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            let rec = try AVAudioRecorder(url: url, settings: settings)
            rec.delegate = self
            rec.isMeteringEnabled = true
            rec.prepareToRecord()
            if !rec.record() {
                result(["ok": false, "reason": "busy"])
                return
            }
            recorder = rec
            currentPath = path
            startTime = Date()
            peakAmplitude = 0.0
            startMeterTimer()
            result(["ok": true])
        } catch {
            NSLog("[sonora] start failed: \(error)")
            result(["ok": false, "reason": "unknown"])
        }
    }

    private func stop(result: @escaping FlutterResult) {
        stopMeterTimer()
        let path = currentPath
        let peak = peakAmplitude
        var durationMs = 0
        if let start = startTime {
            durationMs = Int(Date().timeIntervalSince(start) * 1000)
        }
        recorder?.stop()
        recorder = nil
        startTime = nil
        currentPath = nil
        peakAmplitude = 0.0
        deactivateSession()
        if let p = path, FileManager.default.fileExists(atPath: p) {
            result(["path": p, "durationMs": durationMs, "peakAmplitude": peak])
        } else {
            result(nil)
        }
    }

    private func cancel() {
        stopMeterTimer()
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        if let p = currentPath {
            try? FileManager.default.removeItem(atPath: p)
        }
        currentPath = nil
        startTime = nil
        peakAmplitude = 0.0
        deactivateSession()
    }

    // MARK: - Haptics

    /// 预创建并 prepare 触感发生器，首次触发不丢、不延迟。
    private func prepareHaptics() {
        runOnMain {
            if self.lightGenerator == nil {
                self.lightGenerator = UIImpactFeedbackGenerator(style: .light)
            }
            if self.mediumGenerator == nil {
                self.mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
            }
            if self.heavyGenerator == nil {
                self.heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
            }
            if self.selectionGenerator == nil {
                self.selectionGenerator = UISelectionFeedbackGenerator()
            }
            self.lightGenerator?.prepare()
            self.mediumGenerator?.prepare()
            self.heavyGenerator?.prepare()
            self.selectionGenerator?.prepare()
        }
    }

    /// 立即触发一次触感。录音期间依赖 setAllowHapticsAndSystemSoundsDuringRecording。
    private func performHaptic(style: String, intensity: Double?) {
        runOnMain {
            self.prepareHapticsIfNeeded()
            switch style {
            case "light":
                self.impact(self.lightGenerator, intensity: intensity)
            case "heavy":
                self.impact(self.heavyGenerator, intensity: intensity)
            case "selection":
                self.selectionGenerator?.selectionChanged()
                self.selectionGenerator?.prepare()
            default:
                self.impact(self.mediumGenerator, intensity: intensity)
            }
        }
    }

    private func impact(_ generator: UIImpactFeedbackGenerator?, intensity: Double?) {
        guard let generator = generator else { return }
        if let value = intensity, #available(iOS 13.0, *) {
            generator.impactOccurred(intensity: CGFloat(max(0, min(1, value))))
        } else {
            generator.impactOccurred()
        }
        // 触发后立刻重新 prepare，连续触发之间不掉档。
        generator.prepare()
    }

    private func prepareHapticsIfNeeded() {
        if lightGenerator == nil || mediumGenerator == nil
            || heavyGenerator == nil || selectionGenerator == nil {
            lightGenerator = lightGenerator ?? UIImpactFeedbackGenerator(style: .light)
            mediumGenerator = mediumGenerator ?? UIImpactFeedbackGenerator(style: .medium)
            heavyGenerator = heavyGenerator ?? UIImpactFeedbackGenerator(style: .heavy)
            selectionGenerator = selectionGenerator ?? UISelectionFeedbackGenerator()
        }
    }

    private func releaseHaptics() {
        runOnMain {
            self.lightGenerator = nil
            self.mediumGenerator = nil
            self.heavyGenerator = nil
            self.selectionGenerator = nil
        }
    }

    private func runOnMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    // MARK: - Metering

    private func startMeterTimer() {
        stopMeterTimer()
        // 用 .common 模式，保证按住手势 / 滚动期间计量定时器仍持续触发。
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            guard let self = self, let rec = self.recorder, rec.isRecording else { return }
            rec.updateMeters()
            let db = rec.averagePower(forChannel: 0) // dBFS, <= 0
            let clamped = max(self.minDb, min(0, db))
            let norm = Double((clamped - self.minDb) / (0 - self.minDb))
            self.peakAmplitude = max(self.peakAmplitude, norm)
            self.amplitudeStream.send(norm)
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
    }
}

/// 单个 EventChannel 的 sink 持有者。振幅与异常事件各用一份，避免互相覆盖。
private class SonoraStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?

    func send(_ value: Any) {
        if Thread.isMainThread {
            sink?(value)
        } else {
            DispatchQueue.main.async { self.sink?(value) }
        }
    }

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }
}
