package com.fastguard.fastguard_mobile

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.os.Build
import kotlin.math.abs
import kotlin.math.sqrt

/**
 * 读取相机光学参数（主摄与**长焦**共用同一份换算）。
 *
 * 为什么需要它：测距要用针孔模型 `距离 = 真实尺寸 × 焦距(像素) / 目标像素尺寸`，
 * 其中焦距(像素) 必须来自设备真实参数。Flutter 的 camera 插件只提供
 * name / lensDirection / sensorOrientation，拿不到焦距与传感器尺寸，
 * 因此这里用 Android 的 CameraCharacteristics 直接读取。
 *
 * 换算方式（避开传感器方向与图像旋转的对应问题）：
 *   cropFactor  = 43.2666 / sqrt(sensorW² + sensorH²)   // 全画幅对角线 43.2666mm
 *   focal35mmEq = focalLengthMm × cropFactor
 *   focalPx     = focal35mmEq / 36.0 × 图像宽度(px)      // 全画幅宽 36mm
 *
 * **长焦必须用长焦自己的焦距**：同一像素尺寸在长焦下对应的实际距离远得多。
 */
object CameraInfoReader {

    /** 全画幅(35mm)对角线长度，单位毫米。 */
    private const val FULL_FRAME_DIAGONAL_MM = 43.2666

    fun manager(context: Context): CameraManager =
        context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    fun listCameraIds(context: Context): List<String> =
        try {
            manager(context).cameraIdList.toList()
        } catch (error: Exception) {
            emptyList()
        }

    /** 读取单个相机的光学参数；读不到时返回 null（Dart 侧会退回其它测距方式）。 */
    fun describe(context: Context, cameraId: String?): Map<String, Any?>? {
        val id = cameraId ?: listCameraIds(context).firstOrNull() ?: return null
        return try {
            val characteristics = manager(context).getCameraCharacteristics(id)
            val result = opticsOf(characteristics).toMutableMap()
            result["id"] = id
            result["isLogicalMultiCamera"] = isLogicalMultiCamera(characteristics)
            result
        } catch (error: Exception) {
            null
        }
    }

    /**
     * 列出**后置**相机（含逻辑多摄与物理子摄），每项带 [concurrentSupported] 标记。
     *
     * `concurrentSupported` 的含义是"该镜头出现在至少一组可并发打开的相机组合里"
     * （Android 11+ 的 `getConcurrentCameraIds()`）。只有为 true 的镜头才可能与主摄
     * 同时取流，因此 Dart 侧只从中挑长焦（见 `core/telephoto_channel.dart`）。
     */
    fun listBackCameras(context: Context): List<Map<String, Any?>> {
        val result = mutableListOf<Map<String, Any?>>()
        val concurrentIds = concurrentCameraIds(context)
        for (id in listCameraIds(context)) {
            try {
                val characteristics = manager(context).getCameraCharacteristics(id)
                val facing = characteristics.get(CameraCharacteristics.LENS_FACING)
                if (facing != CameraMetadata.LENS_FACING_BACK) {
                    continue
                }
                val item = opticsOf(characteristics).toMutableMap()
                item["id"] = id
                item["lensFacing"] = facing
                item["isLogicalMultiCamera"] = isLogicalMultiCamera(characteristics)
                item["concurrentSupported"] = concurrentIds.contains(id)
                result.add(item)
            } catch (error: Exception) {
                // 单个相机读取失败不影响其它相机
            }
        }
        return result
    }

    /** 出现在任何一组可并发相机组合里的相机 id。 */
    private fun concurrentCameraIds(context: Context): Set<String> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return emptySet()
        }
        return try {
            val combinations = manager(context).concurrentCameraIds
            val ids = mutableSetOf<String>()
            for (combination in combinations) {
                ids.addAll(combination)
            }
            ids
        } catch (error: Exception) {
            emptySet()
        }
    }

    private fun isLogicalMultiCamera(characteristics: CameraCharacteristics): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
            return false
        }
        return try {
            characteristics.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)
                ?.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_LOGICAL_MULTI_CAMERA)
                ?: false
        } catch (error: Exception) {
            false
        }
    }

    /** 焦距 / 传感器 / 等效焦距等（不含 id 与能力位，便于两处复用）。 */
    private fun opticsOf(characteristics: CameraCharacteristics): Map<String, Any?> {
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
            "focalLengthsMm" to focalLengths,
            "sensorWidthMm" to sensorWidthMm,
            "sensorHeightMm" to sensorHeightMm,
            "apertures" to apertures,
            "sensorOrientation" to characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION),
            "cropFactor" to cropFactor,
            "focalLength35mmEq" to focalLength35mmEq,
        )
    }

    /**
     * 为长焦挑一个合适的输出尺寸：优先 640×480，其次不大于 1280×720 的最大尺寸，
     * 最后取面积最接近 640×480 者。分辨率先小后大：长焦只是低频辅助通道。
     */
    fun pickOutputSize(
        sizes: Array<android.util.Size>?,
        preferWidth: Int = 640,
        preferHeight: Int = 480,
    ): android.util.Size? {
        if (sizes == null || sizes.isEmpty()) {
            return null
        }
        sizes.firstOrNull { it.width == preferWidth && it.height == preferHeight }?.let { return it }
        val bounded = sizes
            .filter { it.width <= 1280 && it.height <= 720 && it.width >= preferWidth }
            .maxByOrNull { it.width.toLong() * it.height }
        if (bounded != null) {
            return bounded
        }
        return sizes.minByOrNull {
            abs(it.width - preferWidth) + abs(it.height - preferHeight)
        }
    }
}
