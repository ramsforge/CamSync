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
                // VBR is universally supported across Exynos, Snapdragon, MediaTek
                setInteger(MediaFormat.KEY_BITRATE_MODE, MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR)
            } catch (_: Exception) {}

            try {
                setInteger(MediaFormat.KEY_LATENCY, 0)
                setInteger(MediaFormat.KEY_PRIORITY, 0)
            } catch (_: Exception) {}
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        mediaCodec = codec
        isEncoding = true
        startTimeMs = System.currentTimeMillis()
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
            val inputBufferIndex = codec.dequeueInputBuffer(5_000L) // 5ms timeout
            if (inputBufferIndex >= 0) {
                val inputBuffer = codec.getInputBuffer(inputBufferIndex) ?: return
                inputBuffer.clear()

                val ySize = width * height
                val totalSize = ySize * 3 / 2
                val buffer = nv12Buffer ?: ByteArray(totalSize).also { nv12Buffer = it }

                if (nv21Data.size >= totalSize) {
                    // Copy Y plane directly
                    System.arraycopy(nv21Data, 0, buffer, 0, ySize)

                    // Convert VU (NV21) to UV (NV12)
                    val uvSize = totalSize - ySize
                    for (i in 0 until uvSize step 2) {
                        buffer[ySize + i] = nv21Data[ySize + i + 1]     // U
                        buffer[ySize + i + 1] = nv21Data[ySize + i]     // V
                    }

                    val putLen = Math.min(inputBuffer.remaining(), totalSize)
                    inputBuffer.put(buffer, 0, putLen)

                    val presentationTimeUs = (System.currentTimeMillis() - startTimeMs) * 1000
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
                codec.dequeueOutputBuffer(bufferInfo, 10_000L) // 10ms timeout
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

                    onPacketEncoded(packet)
                }

                try {
                    codec.releaseOutputBuffer(outputBufferIndex, false)
                } catch (_: Exception) {}
            }
        }
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
        Log.i(TAG, "Hardware Encoder stopped.")
    }
}
