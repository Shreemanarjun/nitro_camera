package dev.shreeman.nitro_camera.outputs

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import dev.shreeman.nitro_camera.NitroCameraOutputs
import nitro.nitro_camera_module.EncodedOutputStats

/**
 * Hardware H.264 encoder fed through [NitroCameraOutputs]: its MediaCodec
 * input surface is drawn by the session's GL renderer. Counts the encoded
 * frames ([stats]); a publisher plugin would ship them instead.
 */
internal class EncodedOutput(private val textureId: Long, width: Int, height: Int, bitRate: Int) {
    private val thread = HandlerThread("NitroEncodedOutput").apply { start() }
    private val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    private val surface: Surface
    @Volatile private var frames = 0L
    @Volatile private var keyframes = 0L
    @Volatile private var bytes = 0L
    @Volatile private var firstPtsUs = -1L
    @Volatile private var lastPtsUs = -1L

    init {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_FRAME_RATE, 30)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
        }
        codec.setCallback(object : MediaCodec.Callback() {
            override fun onInputBufferAvailable(c: MediaCodec, index: Int) {}
            override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG == 0 && info.size > 0) {
                    frames++
                    bytes += info.size
                    if (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0) keyframes++
                    if (firstPtsUs < 0) firstPtsUs = info.presentationTimeUs
                    lastPtsUs = info.presentationTimeUs
                }
                try { c.releaseOutputBuffer(index, false) } catch (_: IllegalStateException) {}
            }
            override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                Log.e("NitroCamera", "encodedOutput[$textureId]: ${e.message}")
            }
            override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
        }, Handler(thread.looper))
        try {
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            surface = codec.createInputSurface()
            codec.start()
        } catch (e: Exception) {
            codec.release()
            thread.quitSafely()
            throw e
        }
        NitroCameraOutputs.add(textureId, surface)
    }

    fun stats() = EncodedOutputStats(frames, keyframes, bytes, firstPtsUs, lastPtsUs)

    fun stop() {
        NitroCameraOutputs.remove(textureId, surface)
        try { codec.stop() } catch (_: Exception) {}
        codec.release()
        surface.release()
        thread.quitSafely()
    }
}
