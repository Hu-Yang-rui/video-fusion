package com.example.video_fusion

import android.app.PictureInPictureParams
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * 平台通道：画中画。
 *
 * 项目锁定的 media_kit 1.2.6 的 NativePlayer 没有 enterPip，
 * 所以这里用 Android 原生 PictureInPictureParams 实现。
 *
 * 不支持的情况一律返回 false（不假装成功）：
 *  - Android 8.0（API 26）以下没有 PiP
 *  - ROM 禁用小窗时 enterPictureInPictureMode() 返回 false
 *
 * 另外必须把 PiP 状态回报给 Flutter：进小窗时 Activity 会走 onPause，
 * App 侧的生命周期监听会因此暂停播放，小窗里就成了静止画面。
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "enterPip" -> {
                        val w = call.argument<Number>("width")?.toInt()
                        val h = call.argument<Number>("height")?.toInt()
                        result.success(enterPip(w, h))
                    }
                    "isInPip" -> result.success(isInPictureInPictureModeSafe())
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun enterPip(width: Int?, height: Int?): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        if (packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE).not()) {
            return false
        }
        return try {
            enterPictureInPictureMode(buildParams(width, height))
        } catch (e: Exception) {
            // ROM 禁用 / 状态异常：如实返回失败
            false
        }
    }

    private fun buildParams(width: Int?, height: Int?): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder()
        // AspectRatio 必须落在 (0, 2147483647] 且系统对区间有额外限制，
        // 横屏视频给 >2 的比例会被拒。夹进 [1:2, 2:1] 并保留两位小数精度。
        if (width != null && height != null && width > 0 && height > 0) {
            val ratio = (width.toDouble() / height.toDouble()).coerceIn(0.5, 2.0)
            builder.setAspectRatio(Rational((ratio * 1000).toInt(), 1000))
        }
        return builder.build()
    }

    private fun isInPictureInPictureModeSafe(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isInPictureInPictureMode

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        notifyPipChanged(isInPictureInPictureMode)
    }

    private fun notifyPipChanged(enabled: Boolean) {
        // 进小窗前先通知 Flutter 别再暂停，退出后恢复常规生命周期行为。
        channel?.invokeMethod("onPipChanged", enabled)
    }

    companion object {
        private const val CHANNEL = "video_fusion/pip"
    }
}
