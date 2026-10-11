package com.fastguard.fastguard_mobile

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlin.math.sqrt

/**
 * 把手机相机的真实光学参数暴露给 Dart 侧。
 *
 * 为什么需要它：测距要用针孔模型 `距离 = 真实宽度 × 焦距(像素) / 框宽(像素)`，
 * 其中焦距(像素) 必须来自设备真实参数。Flutter 的 camera 插件只提供
 * name / lensDirection / sensorOrientation，拿不到焦距与传感器尺寸，
 * 因此这里用 Android 的 CameraCharacteristics 直接读取。
 *
 * 换算方式（避开传感器方向与图像旋转的对应问题）：
 *   cropFactor  = 43.2666 / sqrt(sensorW² + sensorH²)   // 全画幅对角线 43.2666mm
 *   focal35mmEq = focalLengthMm × cropFactor
 *   focalPx     = focal35mmEq / 36.0 × 图像宽度(px)      // 全画幅宽 36mm
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "getCameraInfo" ->
                            result.success(describeCamera(call.argument<String>("cameraId")))
                        "listCameras" -> result.success(listCameraIds())
                        else -> result.notImplemented()
                    }
                } catch (error: Exception) {
                    result.error("CAMERA_INFO_ERROR", error.message, null)
                }
            }
    }
    private fun cameraManager(): CameraManager =
        getSystemService(Context.CAMERA_SERVICE) as CameraManager

    private fun listCameraIds(): List<String> =
        try {
            cameraManager().cameraIdList.toList()
        } catch (error: Exception) {
            emptyList()
        }

    /** 读取单个相机的光学参数；读不到时返回 null（Dart 侧会退回其它测距方式）。 */
    private fun describeCamera(cameraId: String?): Map<String, Any?>? {
        val id = cameraId ?: listCameraIds().firstOrNull() ?: return null
        val characteristics = cameraManager().getCameraCharacteristics(id)

        val focalLengths = characteristics
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
            ?.map { it.toDouble() }
            ?: emptyList()
        val apertures = characteristics
            .get(CameraCharacteristics.LENS_INFO_AVAILABLE_APERTURES)
            ?.map { it.toDouble() }
            ?: emptyList()

        val physicalSize = characteristics.get(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val sensorWidthMm = physicalSize?.width?.toDouble()
        val sensorHeightMm = physicalSize?.height?.toDouble()

        val cropFactor = if (sensorWidthMm != null && sensorHeightMm != null) {
            val diagonal = sqrt(sensorWidthMm * sensorWidthMm + sensorHeightMm * sensorHeightMm)
            if (diagonal > 0.01) FULL_FRAME_DIAGONAL_MM / diagonal else null
        } else {
            null
        }

        val focalLengthMm = focalLengths.firstOrNull()
        val focalLength35mmEq = if (focalLengthMm != null && cropFactor != null) {
            focalLengthMm * cropFactor
        } else {
            null
        }

        return mapOf(
            "id" to id,
            "focalLengthsMm" to focalLengths,
            "sensorWidthMm" to sensorWidthMm,
            "sensorHeightMm" to sensorHeightMm,
            "apertures" to apertures,
            "sensorOrientation" to characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION),
            "cropFactor" to cropFactor,
            "focalLength35mmEq" to focalLength35mmEq,
        )
    }

    private companion object {
        const val CHANNEL_NAME = "fastguard/camera_info"

        /** 全画幅(35mm)对角线长度，单位毫米。 */
        const val FULL_FRAME_DIAGONAL_MM = 43.2666
    }
}
