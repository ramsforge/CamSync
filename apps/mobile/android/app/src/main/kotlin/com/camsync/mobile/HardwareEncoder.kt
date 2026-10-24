package com.camsync.mobile

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.util.Log
import java.nio.ByteBuffer
import java.nio.ByteOrder

class HardwareEncoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int = 30,
    private val bitrateBps: Int = 4_000_000,
    private val onPacketEncoded: (ByteArray) -> Unit
) {
    companion object {
        private const val TAG = "CamSyncEncoder"
        private const val MAGIC = 0x43534E43 // 'CSNC'
        private const val PROTOCOL_VERSION = 1
        private const val HEADER_SIZE = 20

        private const val FRAME_TYPE_CONFIG = 1
        private const val FRAME_TYPE_KEYFRAME = 2
        private const val FRAME_TYPE_DELTA = 3
    }

    private var mediaCodec: MediaCodec? = null
    private var isEncoding = false
    private var workerThread: Thread? = null
    private var sequenceNumber = 0
    private var startTimeMs = 0L
    private var startNanoTime = 0L

    // Live telemetry tracking (rolling 1-second window)
    private var windowStartTimeMs = System.currentTimeMillis()
    private var windowBytes = 0L
    private var windowFrames = 0
    @Volatile private var currentLiveFps = 0.0
    @Volatile private var currentLiveBitrateKbps = 0

    // Preallocated buffer for NV21 -> NV12 color conversion
    private var nv12Buffer: ByteArray? = null

    fun start() {
        Log.i(TAG, "Configuring H.264 Hardware Encoder: ${width}x${height} @ ${fps}fps, ${bitrateBps / 1000} kbps")
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420SemiPlanar)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateBps)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1) // Keyframe every 1s

            try {
                // Baseline profile = NO B-frames = zero reordering latency
                setInteger(MediaFormat.KEY_PROFILE, MediaCodecInfo.CodecProfileLevel.AVCProfileBaseline)
                setInteger(MediaFormat.KEY_LEVEL, MediaCodecInfo.CodecProfileLevel.AVCLevel31)
            } catch (_: Exception) {}

            try {
                // CBR delivers frames immediately without multi-frame lookahead
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
            } catch (_: Exception) {
                try {
                    setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
                } catch (_: Exception) {}
            }

            try {
                setInteger(MediaFormat.KEY_LATENCY, 0)
                setInteger(MediaFormat.KEY_PRIORITY, 0) // Real-time priority
                setInteger("max-bframes", 0)
                setInteger("latency", 0)
                setInteger("low-latency", 1)
            } catch (_: Exception) {}
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        mediaCodec = codec
        isEncoding = true
        startTimeMs = System.currentTimeMillis()
        startNanoTime = System.nanoTime()
        sequenceNumber = 0
        nv12Buffer = ByteArray(width * height * 3 / 2)

        workerThread = Thread { runDrainLoop() }.apply {
            name = "CamSyncEncoderDrain"
            priority = Thread.MAX_PRIORITY
            start()
        }

        Log.i(TAG, "Hardware Encoder started successfully!")
    }

    fun encodeFrame(nv21Data: ByteArray) {
        val codec = mediaCodec ?: return
        if (!isEncoding) return

        try {
            val inputBufferIndex = codec.dequeueInputBuffer(2_000L) // 2ms timeout
            if (inputBufferIndex >= 0) {
                val inputBuffer = codec.getInputBuffer(inputBufferIndex) ?: return
                inputBuffer.clear()

                val ySize = width * height
                val totalSize = ySize * 3 / 2

                if (nv21Data.size >= totalSize) {
                    val putLen = Math.min(inputBuffer.remaining(), totalSize)
                    if (putLen == totalSize) {
                        // Copy Y plane directly
                        inputBuffer.put(nv21Data, 0, ySize)
                        // Convert NV21 (V, U) to NV12 (U, V)
                        var i = ySize
                        while (i < totalSize) {
                            val v = nv21Data[i]
                            val u = nv21Data[i + 1]
                            inputBuffer.put(u)
                            inputBuffer.put(v)
                            i += 2
                        }
                    } else {
                        inputBuffer.put(nv21Data, 0, putLen)
                    }

                    val presentationTimeUs = (System.nanoTime() - startNanoTime) / 1000L
                    codec.queueInputBuffer(inputBufferIndex, 0, putLen, presentationTimeUs, 0)
                } else {
                    codec.queueInputBuffer(inputBufferIndex, 0, 0, 0, 0)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error in encodeFrame: ${e.message}")
        }
    }

    private fun runDrainLoop() {
        val codec = mediaCodec ?: return
        val bufferInfo = MediaCodec.BufferInfo()
        var encodedFrames = 0

        while (isEncoding) {
            val outputBufferIndex = try {
                codec.dequeueOutputBuffer(bufferInfo, 2_000L) // 2ms timeout for instant responsiveness
            } catch (e: Exception) {
                Log.e(TAG, "dequeueOutputBuffer exception: ${e.message}")
                break
            }

            if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                Log.i(TAG, "Encoder output format changed: ${codec.outputFormat}")
                continue
            }

            if (outputBufferIndex >= 0) {
                val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                if (outputBuffer != null && bufferInfo.size > 0) {
                    outputBuffer.position(bufferInfo.offset)
                    outputBuffer.limit(bufferInfo.offset + bufferInfo.size)

                    val isConfig = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                    val isKeyFrame = (bufferInfo.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0

                    val frameType = when {
                        isConfig -> FRAME_TYPE_CONFIG
                        isKeyFrame -> FRAME_TYPE_KEYFRAME
                        else -> FRAME_TYPE_DELTA
                    }

                    val payloadSize = bufferInfo.size
                    val totalSize = HEADER_SIZE + payloadSize
                    val packet = ByteArray(totalSize)
                    val bb = ByteBuffer.wrap(packet).order(ByteOrder.BIG_ENDIAN)

                    // 20-byte CamSync header
                    bb.putInt(MAGIC)
                    bb.put(PROTOCOL_VERSION.toByte())
                    bb.put(frameType.toByte())
                    bb.putShort(0.toShort()) // Reserved
                    bb.putInt(sequenceNumber++)
                    val timestampMs = System.currentTimeMillis() - startTimeMs
                    bb.putInt(timestampMs.toInt())
                    bb.putInt(payloadSize)

                    // Payload NAL bytes
                    outputBuffer.get(packet, HEADER_SIZE, payloadSize)

                    encodedFrames++
                    if (encodedFrames % 60 == 0 || encodedFrames <= 5) {
                        Log.d(TAG, "Encoded frame #$sequenceNumber ($payloadSize bytes, type=$frameType)")
                    }

                    recordOutputFrame(totalSize)
                    onPacketEncoded(packet)
                }

                try {
                    codec.releaseOutputBuffer(outputBufferIndex, false)
                } catch (_: Exception) {}
            }
        }
    }

    private fun recordOutputFrame(byteCount: Int) {
        val now = System.currentTimeMillis()
        synchronized(this) {
            windowBytes += byteCount
            windowFrames++
            val elapsed = now - windowStartTimeMs
            if (elapsed >= 1000) {
                currentLiveFps = (windowFrames * 1000.0) / elapsed
                currentLiveBitrateKbps = ((windowBytes * 8L) / elapsed).toInt()
                windowBytes = 0L
                windowFrames = 0
                windowStartTimeMs = now
            }
        }
    }

    fun getStats(): Map<String, Any> {
        val now = System.currentTimeMillis()
        synchronized(this) {
            val elapsed = now - windowStartTimeMs
            if (elapsed >= 1000 && windowFrames > 0) {
                currentLiveFps = (windowFrames * 1000.0) / elapsed
                currentLiveBitrateKbps = ((windowBytes * 8L) / elapsed).toInt()
                windowBytes = 0L
                windowFrames = 0
                windowStartTimeMs = now
            } else if (elapsed > 2000 && windowFrames == 0) {
                currentLiveFps = 0.0
                currentLiveBitrateKbps = 0
            }
        }
        return mapOf(
            "fps" to currentLiveFps,
            "bitrateKbps" to currentLiveBitrateKbps
        )
    }

    fun stop() {
        Log.i(TAG, "Stopping Hardware Encoder...")
        isEncoding = false
        try {
            workerThread?.join(500)
        } catch (_: InterruptedException) {}
        workerThread = null

        try {
            mediaCodec?.stop()
            mediaCodec?.release()
        } catch (_: Exception) {}
        mediaCodec = null
        nv12Buffer = null

        synchronized(this) {
            windowBytes = 0L
            windowFrames = 0
            currentLiveFps = 0.0
            currentLiveBitrateKbps = 0
            windowStartTimeMs = System.currentTimeMillis()
        }
        Log.i(TAG, "Hardware Encoder stopped.")
    }
}
