package com.fastguard.fastguard_mobile

import android.content.Context
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.CameraCharacteristics
import android.media.Image
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import kotlin.math.max

/**
 * 后置**长焦**并发取流。
 *
 * 为什么放在原生：Flutter 的 `camera` 插件一次只开一路图像流，而"主摄 + 长焦同时拍摄"
 * 需要两个 `CameraDevice` 并发会话，只能自己用 Camera2 开第二路（是否可用取决于设备 HAL，
 * 由 `CameraInfoReader.listBackCameras` 的 `concurrentSupported` 预先判断）。
 *
 * 帧通过 `EventChannel("fastguard/telephoto_stream")` 送给 Dart 侧，
 * 结构与本文件同目录的 camera 插件回调一致（YUV420 三平面 + rowStride/pixelStride），
 * 因此 Dart 侧可以复用主摄的 YUV→RGB 转换。
 *
 * 三处刻意的约束：
 * 1. **不做任何可能崩溃的强假设**：任何一步失败都返回 `ok=false` + `reason`，
 *    Dart 侧据此关闭远距模式，主摄链路完全不受影响；
 * 2. 原生按 [MIN_FRAME_INTERVAL_MS] 限流（长焦只是低频辅助通道），Dart 侧再做 2:1 节流；
 * 3. 没有监听者（Dart 还没订阅/已取消）时**不发送**帧，避免无谓的跨语言拷贝。
 */
class TelephotoStream(private val context: Context) : EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var reader: ImageReader? = null

    private var activeCameraId: String? = null
    private var lastFrameAtMs = 0L

    /** EventSink 必须在主线程调用，复用同一个 Handler。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Dart 是否已订阅（未订阅时不发送帧）。 */
    @Volatile
    private var listening = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        listening = true
    }

    override fun onCancel(arguments: Any?) {
        listening = false
        sink = null
    }

    /**
     * 打开指定长焦相机并开始送帧。
     *
     * @return `mapOf("ok" to true, "size" to "640x480")`，或 `mapOf("ok" to false, "reason" to ...)`。
     */
    fun start(cameraId: String): Map<String, Any?> {
        stop()
        return try {
            val manager = CameraInfoReader.manager(context)
            val characteristics = manager.getCameraCharacteristics(cameraId)
            val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            val size = CameraInfoReader.pickOutputSize(map?.getOutputSizes(ImageFormat.YUV_420_888))
                ?: return fail("长焦不支持 YUV420 输出（远距模式不可用）")

            val backgroundThread = HandlerThread("fastguard-telephoto").also { it.start() }
            thread = backgroundThread
            val backgroundHandler = Handler(backgroundThread.looper)
            handler = backgroundHandler

            val imageReader = ImageReader.newInstance(size.width, size.height, ImageFormat.YUV_420_888, 2)
            reader = imageReader
            imageReader.setOnImageAvailableListener({ onImageAvailable(it) }, backgroundHandler)

            lastFrameAtMs = 0L
            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    device = camera
                    try {
                        @Suppress("DEPRECATION")
                        camera.createCaptureSession(
                            listOf(imageReader.surface),
                            object : CameraCaptureSession.StateCallback() {
                                override fun onConfigured(configured: CameraCaptureSession) {
                                    session = configured
                                    try {
                                        val request = camera.createCaptureRequest(
                                            CameraDevice.TEMPLATE_PREVIEW
                                        )
                                        request.addTarget(imageReader.surface)
                                        request.set(
                                            CaptureRequest.CONTROL_AF_MODE,
                                            CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
                                        )
                                        @Suppress("DEPRECATION")
                                        configured.setRepeatingRequest(
                                            request.build(),
                                            null,
                                            backgroundHandler
                                        )
                                        activeCameraId = cameraId
                                        Log.i(TAG, "长焦已开始: $cameraId ${size.width}x${size.height}")
                                    } catch (error: Exception) {
                                        Log.w(TAG, "长焦重复请求失败", error)
                                    }
                                }

                                override fun onConfigureFailed(configured: CameraCaptureSession) {
                                    Log.w(TAG, "长焦会话配置失败")
                                }
                            },
                            backgroundHandler
                        )
                    } catch (error: Exception) {
                        Log.w(TAG, "长焦会话创建失败", error)
                    }
                }

                override fun onDisconnected(camera: CameraDevice) {
                    camera.close()
                    if (device === camera) {
                        device = null
                    }
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    Log.w(TAG, "长焦相机错误: $error")
                    camera.close()
                    if (device === camera) {
                        device = null
                    }
                }
            }, backgroundHandler)

            mapOf(
                "ok" to true,
                "size" to "${size.width}x${size.height}",
            )
        } catch (error: SecurityException) {
            fail("缺少相机权限（远距模式不可用）")
        } catch (error: Exception) {
            fail("长焦启动异常：${error.message ?: error.javaClass.simpleName}")
        }
    }

    /** 关闭长焦会话（幂等）。 */
    fun stop() {
        try {
            session?.close()
        } catch (error: Exception) {
            // 忽略：可能已经断开
        }
        session = null
        try {
            device?.close()
        } catch (error: Exception) {
            // 忽略
        }
        device = null
        try {
            reader?.close()
        } catch (error: Exception) {
            // 忽略
        }
        reader = null
        thread?.quitSafely()
        thread = null
        handler = null
        activeCameraId = null
        lastFrameAtMs = 0L
    }

    /** 供 Activity 销毁时调用。 */
    fun dispose() {
        stop()
        listening = false
        sink = null
    }

    val currentCameraId: String?
        get() = activeCameraId

    private fun fail(reason: String): Map<String, Any?> {
        stop()
        Log.w(TAG, reason)
        return mapOf("ok" to false, "reason" to reason)
    }

    private fun onImageAvailable(source: ImageReader) {
        val image = try {
            source.acquireLatestImage()
        } catch (error: Exception) {
            null
        } ?: return

        try {
            if (!listening) {
                return
            }
            val now = System.currentTimeMillis()
            if (now - lastFrameAtMs < MIN_FRAME_INTERVAL_MS) {
                return // 低频辅助通道：不追求满帧率
            }
            lastFrameAtMs = now

            val width = image.width
            val height = image.height
            val planes = image.planes
            if (planes.size < 3) {
                return
            }
            val payload = mapOf(
                "width" to width,
                "height" to height,
                "timestampNs" to image.timestamp,
                "planes" to listOf(
                    planeMap(planes[0], width, height, 1),
                    planeMap(planes[1], width / 2, height / 2, 2),
                    planeMap(planes[2], width / 2, height / 2, 2),
                ),
            )
            val target = sink
            if (target != null) {
                mainHandler.post { target.success(payload) }
            }
        } catch (error: Exception) {
            Log.w(TAG, "长焦帧转换失败", error)
        } finally {
            try {
                image.close()
            } catch (error: Exception) {
                // 忽略
            }
        }
    }

    /** 把一个平面拷成"行距对齐的紧凑缓冲区"，与 Dart 侧的索引方式一致。 */
    private fun planeMap(plane: Image.Plane, planeWidth: Int, planeHeight: Int, pixelStride: Int) =
        mapOf(
            "bytes" to copyPlane(plane, planeWidth, planeHeight, pixelStride),
            "bytesPerRow" to plane.rowStride,
            "bytesPerPixel" to plane.pixelStride,
        )

    private fun copyPlane(
        plane: Image.Plane,
        planeWidth: Int,
        planeHeight: Int,
        pixelStride: Int,
    ): ByteArray {
        val rowStride = max(plane.rowStride, 1)
        val effectiveStride = if (plane.pixelStride > 1) plane.pixelStride else pixelStride
        val rowLength = if (effectiveStride == 1) {
            planeWidth
        } else {
            (planeWidth - 1).coerceAtLeast(0) * effectiveStride + 1
        }
        val output = ByteArray(rowStride * planeHeight)
        if (rowLength <= 0) {
            return output
        }
        val buffer = plane.buffer.duplicate()
        val row = ByteArray(rowLength)
        buffer.rewind()
        var offset = 0
        for (rowIndex in 0 until planeHeight) {
            if (buffer.remaining() < rowLength) {
                break
            }
            buffer.get(row, 0, rowLength)
            System.arraycopy(row, 0, output, offset, minOf(rowLength, output.size - offset))
            offset += rowStride
            val skip = rowStride - rowLength
            if (skip > 0 && buffer.remaining() >= skip) {
                buffer.position(buffer.position() + skip)
            }
        }
        return output
    }

    private companion object {
        const val TAG = "FastGuard"

        /** 原生侧最小送帧间隔：长焦是低频辅助通道，约 6.7 fps 上限。 */
        const val MIN_FRAME_INTERVAL_MS = 150L
    }
}
