package com.fastguard.fastguard_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * 把手机相机的真实光学参数、以及**长焦**并发取流暴露给 Dart 侧。
 *
 * 两个方法通道 + 一个事件通道：
 * * `fastguard/camera_info`  —— `getCameraInfo` / `listCameras`（主摄测距用，原有）；
 * * `fastguard/telephoto`    —— `listBackCameras` / `startTelephoto` / `stopTelephoto`；
 * * `fastguard/telephoto_stream` —— 长焦 YUV420 帧流（见 [TelephotoStream]）。
 *
 * 光学参数的换算集中在 [CameraInfoReader]，主摄与长焦共用同一份实现
 * （`cropFactor = 43.2666 / 传感器对角线`、`焦距(像素) = focal35mmEq / 36 × 图像宽度`）。
 */
class MainActivity : FlutterActivity() {

    private var telephoto: TelephotoStream? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getCameraInfo" ->
                            result.success(CameraInfoReader.describe(this, call.argument<String>("cameraId")))
                        "listCameras" -> result.success(CameraInfoReader.listCameraIds(this))
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("CAMERA_INFO_ERROR", error.message, null)
                }
            }

        val stream = TelephotoStream(applicationContext)
        telephoto = stream
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, TELEPHOTO_STREAM_CHANNEL)
            .setStreamHandler(stream)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TELEPHOTO_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "listBackCameras" -> result.success(CameraInfoReader.listBackCameras(this))
                        "startTelephoto" -> {
                            val cameraId = call.argument<String>("cameraId")
                            result.success(
                                if (cameraId.isNullOrEmpty()) {
                                    mapOf("ok" to false, "reason" to "未指定长焦相机")
                                } else {
                                    stream.start(cameraId)
                                }
                            )
                        }
                        "stopTelephoto" -> {
                            stream.stop()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("TELEPHOTO_ERROR", error.message, null)
                }
            }
    }

    override fun onDestroy() {
        telephoto?.dispose()
        telephoto = null
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL_NAME = "fastguard/camera_info"
        const val TELEPHOTO_CHANNEL = "fastguard/telephoto"
        const val TELEPHOTO_STREAM_CHANNEL = "fastguard/telephoto_stream"
    }
}
