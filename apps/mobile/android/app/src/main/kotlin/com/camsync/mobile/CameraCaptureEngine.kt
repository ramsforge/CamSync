package com.camsync.mobile

import android.content.Context
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.Camera
import android.os.Handler
import android.os.HandlerThread
import android.util.Log

@Suppress("DEPRECATION")
class CameraCaptureEngine(private val context: Context) {
    companion object {
        private const val TAG = "CamSyncCamera"
    }

    private var camera: Camera? = null
    private var dummySurfaceTexture: SurfaceTexture? = null
    private var isStreaming = false
    private var currentCameraId = 0

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null

    init {
        startBackgroundThread()
    }

    private fun startBackgroundThread() {
        backgroundThread = HandlerThread("CamSyncCameraThread").apply { start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun stopBackgroundThread() {
        backgroundThread?.quitSafely()
        try {
            backgroundThread?.join()
            backgroundThread = null
            backgroundHandler = null
        } catch (_: InterruptedException) {}
    }

    fun selectCameraId(lens: String): Int {
        val count = Camera.getNumberOfCameras()
        val info = Camera.CameraInfo()
        val backCameras = mutableListOf<Int>()
        val frontCameras = mutableListOf<Int>()

        for (i in 0 until count) {
            Camera.getCameraInfo(i, info)
            if (info.facing == Camera.CameraInfo.CAMERA_FACING_FRONT) {
                frontCameras.add(i)
            } else if (info.facing == Camera.CameraInfo.CAMERA_FACING_BACK) {
                backCameras.add(i)
            }
        }

        Log.i(TAG, "Available cameras: back=$backCameras, front=$frontCameras, requested lens=$lens")

        return when {
            lens == "front" -> {
                frontCameras.firstOrNull() ?: 0
            }
            lens == "back_ultra_wide" -> {
                if (backCameras.size >= 2) backCameras[1] else (backCameras.firstOrNull() ?: 0)
            }
            lens == "back_telephoto" -> {
                if (backCameras.size >= 3) backCameras[2] else (backCameras.firstOrNull() ?: 0)
            }
            else -> {
                backCameras.firstOrNull() ?: 0
            }
        }
    }

    fun startCapture(
        lens: String,
        requestedWidth: Int,
        requestedHeight: Int,
        requestedFps: Int,
        previewSurfaceTexture: SurfaceTexture?,
        onActualDimensions: (Int, Int, Int) -> Unit,
        onFrame: (ByteArray) -> Unit,
        onStarted: () -> Unit
    ) {
        stop()

        backgroundHandler?.post {
            currentCameraId = selectCameraId(lens)
            Log.i(TAG, "Opening Camera 1 for ID: $currentCameraId ($lens)...")

            try {
                val cam = Camera.open(currentCameraId)
                camera = cam
                val params = cam.parameters

                // Pick closest supported preview size
                val supportedSizes = params.supportedPreviewSizes ?: listOf()
                var chosenSize = supportedSizes.firstOrNull() ?: cam.Size(1280, 720)
                var minDiff = Int.MAX_VALUE

                for (size in supportedSizes) {
                    val diff = Math.abs(size.width - requestedWidth) + Math.abs(size.height - requestedHeight)
                    if (diff < minDiff) {
                        minDiff = diff
                        chosenSize = size
                    }
                }
                Log.i(TAG, "Chosen preview size: ${chosenSize.width}x${chosenSize.height}")
                params.setPreviewSize(chosenSize.width, chosenSize.height)

                // Pick FPS range
                val supportedFpsRanges = params.supportedPreviewFpsRange ?: listOf()
                var chosenFpsRange = supportedFpsRanges.firstOrNull() ?: intArrayOf(15000, 30000)
                val targetFps = requestedFps * 1000

                for (range in supportedFpsRanges) {
                    if (range[1] <= targetFps && range[1] >= chosenFpsRange[1]) {
                        chosenFpsRange = range
                    }
                }
                val actualFps = chosenFpsRange[1] / 1000
                Log.i(TAG, "Chosen FPS range: [${chosenFpsRange[0]}, ${chosenFpsRange[1]}] (max: $actualFps)")
                params.setPreviewFpsRange(chosenFpsRange[0], chosenFpsRange[1])

                // Focus mode
                val focusModes = params.supportedFocusModes ?: listOf()
                if (focusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
                    params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
                } else if (focusModes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                    params.focusMode = Camera.Parameters.FOCUS_MODE_AUTO
                }

                params.setRecordingHint(true)
                params.previewFormat = ImageFormat.NV21
                cam.parameters = params

                // Notify actual dimensions so encoder is configured
                onActualDimensions(chosenSize.width, chosenSize.height, actualFps)

                // Allocate 3 buffers for smooth pipeline
                val bufferSize = chosenSize.width * chosenSize.height * 3 / 2
                for (i in 0 until 3) {
                    cam.addCallbackBuffer(ByteArray(bufferSize))
                }

                val st = previewSurfaceTexture ?: SurfaceTexture(10).also { dummySurfaceTexture = it }
                st.setDefaultBufferSize(chosenSize.width, chosenSize.height)
                cam.setPreviewTexture(st)

                var frameCount = 0
                cam.setPreviewCallbackWithBuffer { data, activeCam ->
                    if (data != null && isStreaming) {
                        frameCount++
                        if (frameCount % 60 == 0 || frameCount <= 5) {
                            Log.d(TAG, "Camera 1 frame #$frameCount captured (${data.size} bytes)")
                        }
                        onFrame(data)
                        try {
                            activeCam.addCallbackBuffer(data)
                        } catch (_: Exception) {}
                    }
                }

                cam.startPreview()
                isStreaming = true
                Log.i(TAG, "Camera 1 preview started successfully!")
                onStarted()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start Camera 1: ${e.message}", e)
            }
        }
    }

    fun setTorch(enabled: Boolean) {
        backgroundHandler?.post {
            val cam = camera ?: return@post
            try {
                val params = cam.parameters
                val modes = params.supportedFlashModes ?: return@post
                if (enabled && modes.contains(Camera.Parameters.FLASH_MODE_TORCH)) {
                    params.flashMode = Camera.Parameters.FLASH_MODE_TORCH
                } else if (modes.contains(Camera.Parameters.FLASH_MODE_OFF)) {
                    params.flashMode = Camera.Parameters.FLASH_MODE_OFF
                }
                cam.parameters = params
            } catch (e: Exception) {
                Log.w(TAG, "setTorch error: ${e.message}")
            }
        }
    }

    fun setZoom(zoom: Float) {
        backgroundHandler?.post {
            val cam = camera ?: return@post
            try {
                val params = cam.parameters
                if (params.isZoomSupported) {
                    val ratios = params.zoomRatios
                    val targetRatio = (zoom * 100).toInt()
                    val targetIndex = if (ratios != null && ratios.isNotEmpty()) {
                        var bestIdx = 0
                        var minDiff = Int.MAX_VALUE
                        for (i in ratios.indices) {
                            val diff = Math.abs(ratios[i] - targetRatio)
                            if (diff < minDiff) {
                                minDiff = diff
                                bestIdx = i
                            }
                        }
                        bestIdx
                    } else {
                        val maxZoom = params.maxZoom
                        ((zoom - 1.0f) * (maxZoom / 4.0f)).toInt().coerceIn(0, maxZoom)
                    }
                    params.zoom = targetIndex
                    cam.parameters = params
                    Log.i(TAG, "Zoom set to $zoom (index $targetIndex / ${params.maxZoom})")
                }
            } catch (e: Exception) {
                Log.w(TAG, "setZoom error: ${e.message}")
            }
        }
    }

    fun setFocus(mode: String, distance: Float) {
        backgroundHandler?.post {
            val cam = camera ?: return@post
            try {
                val params = cam.parameters
                val modes = params.supportedFocusModes ?: return@post
                if (mode == "manual" && modes.contains(Camera.Parameters.FOCUS_MODE_FIXED)) {
                    params.focusMode = Camera.Parameters.FOCUS_MODE_FIXED
                } else if (modes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO)) {
                    params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
                }
                cam.parameters = params
            } catch (_: Exception) {}
        }
    }

    fun setExposure(mode: String, iso: Int?, shutterSpeedMs: Double?) {
        backgroundHandler?.post {
            val cam = camera ?: return@post
            try {
                val params = cam.parameters
                val minExp = params.minExposureCompensation
                val maxExp = params.maxExposureCompensation
                if (minExp != 0 || maxExp != 0) {
                    if (iso != null) {
                        val comp = ((iso - 400) / 100).coerceIn(minExp, maxExp)
                        params.exposureCompensation = comp
                        cam.parameters = params
                    }
                }
            } catch (_: Exception) {}
        }
    }

    fun setWhiteBalance(mode: String) {
        backgroundHandler?.post {
            val cam = camera ?: return@post
            try {
                val params = cam.parameters
                val wb = when (mode) {
                    "daylight" -> Camera.Parameters.WHITE_BALANCE_DAYLIGHT
                    "cloudy" -> Camera.Parameters.WHITE_BALANCE_CLOUDY_DAYLIGHT
                    "fluorescent" -> Camera.Parameters.WHITE_BALANCE_FLUORESCENT
                    "incandescent" -> Camera.Parameters.WHITE_BALANCE_INCANDESCENT
                    else -> Camera.Parameters.WHITE_BALANCE_AUTO
                }
                if (params.supportedWhiteBalance?.contains(wb) == true) {
                    params.whiteBalance = wb
                    cam.parameters = params
                }
            } catch (_: Exception) {}
        }
    }

    fun stop() {
        val cam = camera
        camera = null
        isStreaming = false

        if (cam != null) {
            try {
                cam.setPreviewCallbackWithBuffer(null)
                cam.stopPreview()
                cam.release()
            } catch (e: Exception) {
                Log.w(TAG, "Error stopping camera: ${e.message}")
            }
        }

        try {
            dummySurfaceTexture?.release()
            dummySurfaceTexture = null
        } catch (_: Exception) {}
    }
}
