package com.example.sonora

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioManager
import android.media.AudioRecordingConfiguration
import android.media.MediaRecorder
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.io.File

/**
 * Sonora 录音插件 Android 实现。
 *
 * 使用 [MediaRecorder] 直接录制 m4a(AAC)，通过 [MediaRecorder.getMaxAmplitude] 轮询振幅，
 * 经 EventChannel 推送归一化振幅（0~1）用于波纹动画。权限的申请交由宿主处理。
 *
 * 通话占用：通话期间系统不会让 [MediaRecorder.start] 失败，而是给本应用喂全 0 的静音输入，
 * 表现为「能录但录不进声音」。因此开录前用 [AudioManager.getMode] 判断是否处于通话，
 * 录音中再用 [AudioManager.AudioRecordingCallback]（API 29+）监听输入被静音并主动作废。
 */
class SonoraPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var amplitudeChannel: EventChannel
    private lateinit var eventChannel: EventChannel
    private var appContext: Context? = null

    private var recorder: MediaRecorder? = null
    private var currentPath: String? = null
    private var startTimeMs: Long = 0L
    private var recording = false
    private var peakAmplitude = 0.0

    private val amplitudeStream = StreamHolder()
    private val eventStream = StreamHolder()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var amplitudeRunnable: Runnable? = null

    private companion object {
        const val AMPLITUDE_INTERVAL_MS = 60L
        const val MAX_AMPLITUDE = 32767.0

        /** 每隔多少次振幅采样查一次通话状态。getMode 是 IPC，不必每帧都问。 */
        const val BUSY_CHECK_EVERY = 8
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "sonora")
        channel.setMethodCallHandler(this)
        amplitudeChannel = EventChannel(binding.binaryMessenger, "sonora/amplitude")
        amplitudeChannel.setStreamHandler(amplitudeStream)
        eventChannel = EventChannel(binding.binaryMessenger, "sonora/events")
        eventChannel.setStreamHandler(eventStream)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopAmplitudeTimer()
        unregisterRecordingCallback()
        releaseRecorder(deleteFile = false)
        channel.setMethodCallHandler(null)
        amplitudeChannel.setStreamHandler(null)
        eventChannel.setStreamHandler(null)
        cachedVibrator = null
        appContext = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "hasPermission" -> result.success(hasPermission())
            // 申请权限需要 Activity，交由宿主（permission_handler）处理，这里返回当前状态。
            "requestPermission" -> result.success(hasPermission())
            "isAudioBusy" -> result.success(isAudioBusy())
            "warmUp" -> {
                warmUp()
                result.success(null)
            }
            "start" -> {
                val path = call.argument<String>("path")
                val sampleRate = call.argument<Int>("sampleRate") ?: 44100
                val channels = call.argument<Int>("numChannels") ?: 1
                val bitRate = call.argument<Int>("bitRate") ?: 128000
                result.success(start(path, sampleRate, channels, bitRate))
            }
            "stop" -> result.success(stop())
            "cancel" -> {
                cancel()
                result.success(null)
            }
            "isRecording" -> result.success(recording)
            "prepareHaptics" -> {
                // Android 无需预热发生器，取一次 Vibrator 缓存即可。
                vibrator()
                result.success(null)
            }
            "haptic" -> {
                performHaptic(call.argument<String>("style") ?: "medium")
                result.success(null)
            }
            "dispose" -> {
                cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun hasPermission(): Boolean {
        val ctx = appContext ?: return false
        return ContextCompat.checkSelfPermission(ctx, Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun audioManager(): AudioManager? =
        appContext?.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    /**
     * 是否处于通话（含来电响铃）。微信 / 系统电话通话期间 mode 会被切到
     * [AudioManager.MODE_IN_COMMUNICATION] 或 [AudioManager.MODE_IN_CALL]，
     * 这是本应用能拿到的、最可靠的「麦克风被占用」信号。
     */
    private fun isAudioBusy(): Boolean {
        val mode = audioManager()?.mode ?: return false
        return when (mode) {
            AudioManager.MODE_RINGTONE,
            AudioManager.MODE_IN_CALL,
            AudioManager.MODE_IN_COMMUNICATION -> true
            // MODE_CALL_SCREENING(4) / MODE_CALL_REDIRECT(5) /
            // MODE_COMMUNICATION_REDIRECT(6)：高版本新增的通话态，按数值判断以兼容低版本编译。
            else -> mode >= 4
        }
    }

    private fun warmUp() {
        // MediaRecorder 需在 start 时配置输出文件，这里仅预创建实例以减少按下时的构造开销。
        if (recorder == null && !recording) {
            recorder = try {
                createRecorder()
            } catch (e: Exception) {
                null
            }
        }
    }

    private fun createRecorder(): MediaRecorder {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            MediaRecorder(appContext!!)
        } else {
            @Suppress("DEPRECATION")
            MediaRecorder()
        }
    }

    private fun start(
        path: String?,
        sampleRate: Int,
        channels: Int,
        bitRate: Int,
    ): Map<String, Any?> {
        if (path.isNullOrEmpty()) return failure("unknown")
        if (recording) return failure("unknown")
        if (!hasPermission()) return failure("permission")
        if (isAudioBusy()) return failure("busy")

        return try {
            // warmUp 预创建的实例未配置，直接重建更稳妥。
            releaseRecorder(deleteFile = false)

            val outFile = File(path)
            outFile.parentFile?.let { if (!it.exists()) it.mkdirs() }

            val rec = createRecorder()
            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setAudioChannels(channels)
            rec.setAudioSamplingRate(sampleRate)
            rec.setAudioEncodingBitRate(bitRate)
            rec.setOutputFile(path)
            rec.prepare()
            rec.start()

            recorder = rec
            currentPath = path
            startTimeMs = System.currentTimeMillis()
            peakAmplitude = 0.0
            recording = true
            registerRecordingCallback()
            startAmplitudeTimer()
            mapOf("ok" to true)
        } catch (e: Exception) {
            releaseRecorder(deleteFile = true)
            recording = false
            // start 抛错时最常见的原因就是麦克风被其他应用（通话）独占。
            failure(if (isAudioBusy()) "busy" else "unknown")
        }
    }

    private fun failure(reason: String): Map<String, Any?> =
        mapOf("ok" to false, "reason" to reason)

    private fun stop(): Map<String, Any?>? {
        if (!recording) return null
        stopAmplitudeTimer()
        unregisterRecordingCallback()

        val path = currentPath
        val durationMs = (System.currentTimeMillis() - startTimeMs).toInt()
        val peak = peakAmplitude
        var success = true
        try {
            recorder?.stop()
        } catch (e: Exception) {
            // 录音过短或异常时 stop 会抛错，文件通常不可用。
            success = false
        }
        try {
            recorder?.reset()
            recorder?.release()
        } catch (_: Exception) {
        }
        recorder = null
        recording = false
        currentPath = null
        peakAmplitude = 0.0

        if (!success || path.isNullOrEmpty()) {
            if (!path.isNullOrEmpty()) runCatching { File(path).delete() }
            return null
        }
        return mapOf(
            "path" to path,
            "durationMs" to durationMs,
            "peakAmplitude" to peak,
        )
    }

    private fun cancel() {
        stopAmplitudeTimer()
        unregisterRecordingCallback()
        releaseRecorder(deleteFile = true)
        recording = false
        peakAmplitude = 0.0
    }

    private fun releaseRecorder(deleteFile: Boolean) {
        val path = currentPath
        try {
            if (recording) {
                runCatching { recorder?.stop() }
            }
            recorder?.reset()
            recorder?.release()
        } catch (_: Exception) {
        }
        recorder = null
        if (deleteFile && !path.isNullOrEmpty()) {
            runCatching { File(path).delete() }
        }
        if (deleteFile) currentPath = null
    }

    /** 录音被打断/静音：作废当次录音并上报，避免 UI 停留在录音态。 */
    private fun abortRecording(reason: String) {
        if (!recording) return
        cancel()
        eventStream.send(reason)
    }

    // ---- 输入被静音的检测（API 29+）----

    /** 以 [Any] 持有，避免在 minSdk 低于回调类引入版本时触碰该类型。 */
    private var recordingCallback: Any? = null

    private fun registerRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        registerSilenceCallbackQ()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun registerSilenceCallbackQ() {
        val am = audioManager() ?: return
        val callback = object : AudioManager.AudioRecordingCallback() {
            override fun onRecordingConfigChanged(configs: MutableList<AudioRecordingConfiguration>) {
                if (!recording) return
                // API 29 起本应用只能看到自己的录音配置，任一被静音即代表我们录不到声音。
                if (configs.any { it.isClientSilenced }) {
                    abortRecording("silenced")
                }
            }
        }
        runCatching { am.registerAudioRecordingCallback(callback, mainHandler) }
            .onSuccess { recordingCallback = callback }
    }

    private fun unregisterRecordingCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        unregisterSilenceCallbackQ()
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun unregisterSilenceCallbackQ() {
        val callback = recordingCallback as? AudioManager.AudioRecordingCallback ?: return
        recordingCallback = null
        runCatching { audioManager()?.unregisterAudioRecordingCallback(callback) }
    }

    // ---- 触感 ----

    private var cachedVibrator: Vibrator? = null

    private fun vibrator(): Vibrator? {
        cachedVibrator?.let { return it }
        val ctx = appContext ?: return null
        val vib = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val manager =
                ctx.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
            manager?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            ctx.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        cachedVibrator = vib
        return vib
    }

    /**
     * 触发一次系统触感。优先用 [VibrationEffect.createPredefined]，
     * 这类预设由厂商按机型调校，比自定义时长的「嗡」更接近 iOS Taptic 手感。
     */
    private fun performHaptic(style: String) {
        val vib = vibrator() ?: return
        if (!vib.hasVibrator()) return
        try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                    val effectId = when (style) {
                        "light", "selection" -> VibrationEffect.EFFECT_TICK
                        "heavy" -> VibrationEffect.EFFECT_HEAVY_CLICK
                        else -> VibrationEffect.EFFECT_CLICK
                    }
                    vib.vibrate(VibrationEffect.createPredefined(effectId))
                }
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                    val (duration, amplitude) = when (style) {
                        "light", "selection" -> 10L to 90
                        "heavy" -> 24L to 255
                        else -> 16L to 180
                    }
                    vib.vibrate(VibrationEffect.createOneShot(duration, amplitude))
                }
                else -> {
                    val duration = when (style) {
                        "light", "selection" -> 10L
                        "heavy" -> 24L
                        else -> 16L
                    }
                    @Suppress("DEPRECATION")
                    vib.vibrate(duration)
                }
            }
        } catch (_: Exception) {
        }
    }

    // ---- EventChannel: 振幅流与异常事件 ----

    /** 单个 EventChannel 的 sink 持有者，振幅与异常事件各用一份，互不覆盖。 */
    private class StreamHolder : EventChannel.StreamHandler {
        private var sink: EventChannel.EventSink? = null

        fun send(value: Any) {
            sink?.success(value)
        }

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            sink = events
        }

        override fun onCancel(arguments: Any?) {
            sink = null
        }
    }

    private fun startAmplitudeTimer() {
        stopAmplitudeTimer()
        val runnable = object : Runnable {
            private var ticks = 0

            override fun run() {
                if (!recording) return
                // 录音中途来电：mode 会切到通话态，此时继续录只会得到静音，直接作废。
                // API 29 以下没有静音回调，这条轮询是唯一的中断感知手段。
                if (ticks++ % BUSY_CHECK_EVERY == 0 && isAudioBusy()) {
                    abortRecording("interrupted")
                    return
                }
                try {
                    val amp = recorder?.maxAmplitude ?: 0
                    val norm = (amp / MAX_AMPLITUDE).coerceIn(0.0, 1.0)
                    if (norm > peakAmplitude) peakAmplitude = norm
                    amplitudeStream.send(norm)
                } catch (_: Exception) {
                }
                mainHandler.postDelayed(this, AMPLITUDE_INTERVAL_MS)
            }
        }
        amplitudeRunnable = runnable
        mainHandler.postDelayed(runnable, AMPLITUDE_INTERVAL_MS)
    }

    private fun stopAmplitudeTimer() {
        amplitudeRunnable?.let { mainHandler.removeCallbacks(it) }
        amplitudeRunnable = null
    }
}
