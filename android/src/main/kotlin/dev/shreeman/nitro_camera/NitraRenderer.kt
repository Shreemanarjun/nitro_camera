package dev.shreeman.nitro_camera

import android.graphics.SurfaceTexture
import android.opengl.*
import android.opengl.GLUtils
import android.util.Log
import android.view.Surface
import dev.shreeman.nitro_camera.utils.NitraFrameTransform
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * High-performance GPU-accelerated OpenGL Renderer for the Nitro Camera pipeline.
 * Implements a programmable video filter chain using GLSL Shaders.
 *
 * Flow: Camera (OES Texture) -> OpenGL Shader -> Output Surface (Flutter Texture)
 *
 * vision-camera analogue: none — RN renders through a CameraX PreviewView /
 * their FrameRenderer view; Flutter needs this GL pipeline to feed the engine
 * texture (plus platform-view and recorder surfaces) from one OES source.
 */
class NitraRenderer(private val width: Int, private val height: Int) {
    private var sensorOrientation: Int = 90
    private var isFrontCamera: Boolean = false

    /** Current device/display rotation in degrees (0/90/180/270). Written from the
     *  main thread (DisplayListener), read on the GL thread — hence @Volatile. */
    @Volatile
    var displayRotationDegrees: Int = 0

    // Lens-undistortion params (see UNDISTORT_GLSL). Set once per session from the
    // camera calibration; 0,0,0 => passthrough (main/tele lenses).
    @Volatile private var distK1 = 0f
    @Volatile private var distK2 = 0f
    @Volatile private var distK3 = 0f
    @Volatile private var distFocal = 0.5f

    /** Configure barrel-undistortion. [focalNorm] = focal length / buffer width. */
    fun setDistortion(k1: Float, k2: Float, k3: Float, focalNorm: Float) {
        distK1 = k1
        distK2 = k2
        distK3 = k3
        distFocal = if (focalNorm > 0.01f) focalNorm else 0.5f
    }

    fun setSensorOrientation(orientation: Int) {
        this.sensorOrientation = orientation
    }

    fun setIsFrontCamera(isFront: Boolean) {
        this.isFrontCamera = isFront
    }

    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var platformEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var recorderEglSurface: EGLSurface = EGL14.EGL_NO_SURFACE
    private var eglConfig: EGLConfig? = null

    private var program: Int = 0
    private var textureId: Int = -1
    var inputSurfaceTexture: SurfaceTexture? = null
    var inputSurface: Surface? = null
    private var platformSurface: Surface? = null
    private var outputSurface: Surface? = null

    private var vertexBuffer: FloatBuffer
    private var texCoordBuffer: FloatBuffer

    private var isFirstFrame = true
    private var frameConsumed = false
    private var lastDimLog = ""
    private var transformMatrix = FloatArray(16)
    private val vertexShader = "attribute vec4 position;\n" +
            "attribute vec4 texCoord;\n" +
            "varying vec2 vTextureCoord;\n" +
            "uniform mat4 uSTMatrix;\n" +
            "uniform mat4 uProjection;\n" +
            "void main() {\n" +
            "    gl_Position = uProjection * position;\n" +
            "    vTextureCoord = (uSTMatrix * texCoord).xy;\n" +
            "}\n"

    // Lens (barrel) undistortion applied at the sampling step. For each output
    // (undistorted) texel we sample the SOURCE at the distorted position — the
    // forward Brown radial model r' = r·(1 + k1·r² + k2·r⁴ + k3·r⁶). Isotropic +
    // centred at 0.5, so it's invariant to our rotation / crop / OES V-flip. A
    // zero K vector is an exact passthrough (used by the main/tele lenses).
    private val UNDISTORT_GLSL =
        "uniform vec3 uDistK;\n" +      // k1, k2, k3 (0,0,0 => disabled)
        "uniform float uDistFocal;\n" + // focal length / buffer width (isotropic)
        "vec2 undistort(vec2 tc) {\n" +
        "    if (uDistK.x == 0.0 && uDistK.y == 0.0 && uDistK.z == 0.0) return tc;\n" +
        "    vec2 n = (tc - 0.5) / uDistFocal;\n" +
        "    float r2 = dot(n, n);\n" +
        "    float f = 1.0 + uDistK.x*r2 + uDistK.y*r2*r2 + uDistK.z*r2*r2*r2;\n" +
        "    return (n * f) * uDistFocal + 0.5;\n" +
        "}\n"

    private val PASSTHROUGH_FS =
        "#extension GL_OES_EGL_image_external : require\n" +
        "precision highp float;\n" +
        "varying vec2 vTextureCoord;\n" +
        "uniform samplerExternalOES sTexture;\n" +
        UNDISTORT_GLSL +
        "void main() {\n" +
        "    gl_FragColor = texture2D(sTexture, undistort(vTextureCoord));\n" +
        "}\n"

    private var fragmentShader = PASSTHROUGH_FS

    init {
        val vords = floatArrayOf(
            -1f, -1f,  1f, -1f,  -1f, 1f,   1f, 1f
        )
        val tords = floatArrayOf(
            0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f
        )
        vertexBuffer = ByteBuffer.allocateDirect(vords.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(vords); position(0) }
        texCoordBuffer = ByteBuffer.allocateDirect(tords.size * 4).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(tords); position(0) }
    }

    fun setup(surface: Surface) {
        outputSurface = surface
        try {
            initEGL()
            initGL()
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraRenderer.setup Critical Error: ${e.message}")
            release()
        }
    }

    private fun initEGL() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(eglDisplay, version, 0, version, 1)

        val configSpec = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8, 
            EGLExt.EGL_RECORDABLE_ANDROID, 1,
            EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configSpec, 0, configs, 0, 1, numConfigs, 0)
        eglConfig = configs[0]

        val attribList = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT, attribList, 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) throw RuntimeException("eglCreateContext failed")

        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)

        // Safety: Attempt to create surface. If it fails, the native window might be busy.
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, outputSurface, surfaceAttribs, 0)
        if (eglSurface == EGL14.EGL_NO_SURFACE) {
            val err = EGL14.eglGetError()
            throw RuntimeException("eglCreateWindowSurface failed: 0x${Integer.toHexString(err)}")
        }

        if (!EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)) {
            throw RuntimeException("eglMakeCurrent failed")
        }
    }

    private fun initGL() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return

        setupProgram()

        val textures = IntArray(1)
        GLES20.glGenTextures(1, textures, 0)
        textureId = textures[0]
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR.toFloat())
        GLES20.glTexParameterf(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR.toFloat())
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
        GLES20.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)

        inputSurfaceTexture = SurfaceTexture(textureId).apply {
            setDefaultBufferSize(width, height)
        }
        inputSurface = Surface(inputSurfaceTexture)

        // IMPORTANT: Unbind EGL from this setup thread.
        // Rendering should only happen on drawFrame thread.
        EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
    }

    private fun setupProgram() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return

        program = createProgram(vertexShader, fragmentShader)

        // Graceful Fallback: if custom shader fails, use passthrough
        if (program == 0 && fragmentShader != PASSTHROUGH_FS) {
            Log.w("NitroCamera", "NitraRenderer: Custom shader failed, falling back to passthrough")
            program = createProgram(vertexShader, PASSTHROUGH_FS)
        }

        if (program == 0) {
            Log.e("NitroCamera", "NitraRenderer: GPU Pipeline Critical Failure")
            return
        }

        phLoc = GLES20.glGetAttribLocation(program, "position")
        thLoc = GLES20.glGetAttribLocation(program, "texCoord")
        mhLoc = GLES20.glGetUniformLocation(program, "uSTMatrix")
        upLoc = GLES20.glGetUniformLocation(program, "uProjection")
    }

    private var phLoc: Int = -1
    private var thLoc: Int = -1
    private var mhLoc: Int = -1
    private var upLoc: Int = -1
    private var projectionMatrix = FloatArray(16)

    fun setPlatformSurface(surface: Surface?) {
        this.platformSurface = surface
        val display = eglDisplay
        val config = eglConfig
        if (display == EGL14.EGL_NO_DISPLAY || config == null) return

        if (platformEglSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(display, platformEglSurface)
            platformEglSurface = EGL14.EGL_NO_SURFACE
        }

        if (surface != null && surface.isValid) {
            platformEglSurface = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
        }
    }

    /**
     * Detaches the platform surface immediately.
     * This must be called when the native View is destroyed to avoid rendering into an abandoned buffer.
     */
    fun detachPlatformSurface() {
        val display = eglDisplay
        if (display == EGL14.EGL_NO_DISPLAY) return
        
        if (platformEglSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(display, platformEglSurface)
            platformEglSurface = EGL14.EGL_NO_SURFACE
            platformSurface = null
            Log.d("NitroCamera", "NitraRenderer: Platform surface detached.")
        }
    }

    /**
     * Rebinds the Flutter-texture output to a new producer [surface] (Flutter
     * recreates it on rotation/layout). Call on the GL thread. This must NOT
     * restart the camera — the camera writes to our input SurfaceTexture, not to
     * this surface; only the EGL window binding needs to change.
     */
    fun setFlutterSurface(surface: Surface?) {
        val display = eglDisplay
        val config = eglConfig
        if (display == EGL14.EGL_NO_DISPLAY || config == null) return

        if (eglSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(display, eglSurface)
            eglSurface = EGL14.EGL_NO_SURFACE
        }
        if (surface != null && surface.isValid) {
            eglSurface = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
            if (eglSurface == EGL14.EGL_NO_SURFACE) {
                Log.e("NitroCamera", "NitraRenderer: Failed to rebind Flutter surface: 0x${Integer.toHexString(EGL14.eglGetError())}")
            }
        }
    }

    fun setRecordingSurface(surface: android.view.Surface?) {
        val display = eglDisplay
        val config = eglConfig
        if (display == EGL14.EGL_NO_DISPLAY || config == null) return

        // Run on GL thread via signal or direct if we are on it
        // Note: This is called by the camera session thread, so we'll destroy on next draw.
        if (recorderEglSurface != EGL14.EGL_NO_SURFACE) {
            EGL14.eglDestroySurface(display, recorderEglSurface)
            recorderEglSurface = EGL14.EGL_NO_SURFACE
        }

        if (surface != null && surface.isValid) {
            recorderEglSurface = EGL14.eglCreateWindowSurface(display, config, surface, intArrayOf(EGL14.EGL_NONE), 0)
            if (recorderEglSurface == EGL14.EGL_NO_SURFACE) {
                val err = EGL14.eglGetError()
                Log.e("NitroCamera", "NitraRenderer: Failed to create recorder EGL surface: 0x${Integer.toHexString(err)}")
            }
        }
    }

    fun updateShader(shader: String) {
        if (fragmentShader == shader) return

        if (shader.isEmpty()) {
            fragmentShader = PASSTHROUGH_FS
        } else {
            // Build a compatibility wrapper for user shaders
            fragmentShader =
                "#extension GL_OES_EGL_image_external : require\n" +
                "precision highp float;\n" +
                "varying vec2 vTextureCoord;\n" +
                "uniform samplerExternalOES sTexture;\n" +
                UNDISTORT_GLSL +
                "\n" +
                "// Compatibility macros for user-friendly filter writing\n" +
                "#define fragColor gl_FragColor\n" +
                "#define uv vTextureCoord\n" +
                "#define inputColor (texture2D(sTexture, undistort(vTextureCoord)))\n" +
                "uniform float time;\n" +
                shader
        }

        // Signal drawFrame to re-init the program
        if (program != 0) {
            program = 0
            phLoc = -1
        }
    }

    fun drawFrame() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY) return

        try {
            frameConsumed = false
            val pSurface = platformSurface
            val pvActive = platformEglSurface != EGL14.EGL_NO_SURFACE &&
                pSurface != null && pSurface.isValid

            // 1. Flutter Texture surface. When the platform view is attached the
            // Texture widget isn't on screen, so skip its draw+swap (halves GPU
            // work — vision-camera renders one surface). We still need the OES
            // frame consumed each vsync; renderToSurface(platformEglSurface)
            // handles updateTexImage when the texture surface was skipped.
            if (!pvActive) {
                renderToSurface(eglSurface)
            }

            // 2. Platform view surface (AndroidView SurfaceView)
            if (pvActive) {
                GLES20.glFlush()
                renderToSurface(platformEglSurface)
            } else if (platformEglSurface != EGL14.EGL_NO_SURFACE) {
                detachPlatformSurface()
            }

            // 3. Branched Logic (on recorderEglSurface)
            if (recorderEglSurface != EGL14.EGL_NO_SURFACE) {
                // IMPORTANT: Flush pipeline before switching surfaces on some Adreno drivers
                GLES20.glFlush()
                renderToSurface(recorderEglSurface)
            }
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraRenderer: Draw internal error: ${e.message}")
        }
    }

    private fun renderToSurface(surface: EGLSurface) {
        if (surface == EGL14.EGL_NO_SURFACE) return

        EGL14.eglMakeCurrent(eglDisplay, surface, surface, eglContext)

        if (program == 0 || phLoc == -1) {
            setupProgram()
            if (program == 0 || phLoc == -1) return
        }

        val st = inputSurfaceTexture ?: return

        // Consume the camera frame ONCE per drawFrame (on whichever surface
        // renders first — texture surface normally, platform surface in PV mode).
        if (!frameConsumed) {
            frameConsumed = true
            try {
                st.updateTexImage()
                st.getTransformMatrix(transformMatrix)
            } catch (_: Exception) {
                if (isFirstFrame) android.opengl.Matrix.setIdentityM(transformMatrix, 0)
            }
        }

        // --- ASPECT RATIO & VIEWPORT CORRECTION (CENTER CROP) ---
        val surfaceW = IntArray(1)
        val surfaceH = IntArray(1)
        EGL14.eglQuerySurface(eglDisplay, surface, EGL14.EGL_WIDTH, surfaceW, 0)
        EGL14.eglQuerySurface(eglDisplay, surface, EGL14.EGL_HEIGHT, surfaceH, 0)
        val sw = surfaceW[0].toFloat()
        val sh = surfaceH[0].toFloat()

        GLES20.glViewport(0, 0, sw.toInt(), sh.toInt())
        GLES20.glClearColor(0f, 0f, 0f, 1f)
        GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)

        // --- ROTATION + CENTER-CROP (applied AFTER the camera OES transform) ---
        // The sensor buffer is landscape; we rotate it upright + cover-crop it. The
        // rotation must be composed AFTER the device's getTransformMatrix (which
        // includes a V-flip) — composing before it flips the rotation direction and
        // leaves the preview 90° off (verified vs the OnePlus stock camera).
        android.opengl.Matrix.setIdentityM(projectionMatrix, 0)
        // Effective rotation accounts for BOTH the sensor mount AND the current
        // device/display rotation, so the preview stays upright in every device
        // orientation (matches the stock camera). back: sensor - display;
        // front: sensor + display (then mirrored below).
        val effectiveOrientation = if (isFrontCamera) {
            (sensorOrientation + displayRotationDegrees) % 360
        } else {
            (sensorOrientation - displayRotationDegrees + 360) % 360
        }
        // The OES matrix may ALREADY contain a rotation: when the producer surface
        // carries a display transform hint, the HAL pre-rotates the buffer and
        // encodes it in getTransformMatrix (observed on OnePlus: oes = V-flip∘R90).
        // Decompose it (R = F·L, F = plain V-flip) and only apply the DIFFERENCE —
        // otherwise we double-rotate. Plain V-flip matrices give 0 → unchanged.
        val oesRotation = run {
            val r00 = transformMatrix[0]
            val r10 = -transformMatrix[1]
            val deg = Math.toDegrees(Math.atan2(r10.toDouble(), r00.toDouble()))
            ((Math.round(deg / 90.0) * 90).toInt() % 360 + 360) % 360
        }
        val extraRotation = ((effectiveOrientation - oesRotation) % 360 + 360) % 360

        // Cover-crop for the effective (post-rotation) content aspect.
        // EXCEPTION — the Flutter Texture surface renders the FULL upright frame
        // (no crop): the producer surface's size is timing-dependent (Impeller
        // sometimes resizes it to layout, sometimes keeps setSize dims), so any
        // GL-side aspect fit would be wrong half the time. Instead Dart wraps the
        // Texture in a FittedBox declaring the true content aspect — the buffer's
        // arbitrary aspect cancels out exactly (same contract as the iOS path).
        val fillWholeSurface = surface == eglSurface
        val crop = if (fillWholeSurface) floatArrayOf(1f, 1f)
            else NitraFrameTransform.coverCrop(
                effectiveOrientation, width, height, sw.toInt(), sh.toInt())
        val cropX = crop[0]
        val cropY = crop[1]
        val surfKind = when (surface) {
            eglSurface -> "texture"
            platformEglSurface -> "platformView"
            else -> "recorder"
        }
        val dimKey = "$surfKind:${sw.toInt()}x${sh.toInt()}:$effectiveOrientation:$oesRotation:$sensorOrientation:$isFrontCamera:$displayRotationDegrees"
        if (dimKey != lastDimLog) {
            lastDimLog = dimKey
            val m = transformMatrix
            Log.i("NitroCamera", "renderToSurface[$surfKind] surface=${sw.toInt()}x${sh.toInt()} " +
                "content=${width}x$height sensor=$sensorOrientation front=$isFrontCamera " +
                "display=$displayRotationDegrees effOrient=$effectiveOrientation " +
                "oesRot=$oesRotation extra=$extraRotation crop=($cropX,$cropY) " +
                "oes=[${m[0]},${m[1]},${m[4]},${m[5]},${m[12]},${m[13]}]")
        }
        val texM = FloatArray(16)
        android.opengl.Matrix.setIdentityM(texM, 0)
        android.opengl.Matrix.translateM(texM, 0, 0.5f, 0.5f, 0f)
        android.opengl.Matrix.scaleM(texM, 0, if (isFrontCamera) -cropX else cropX, cropY, 1f)
        android.opengl.Matrix.rotateM(texM, 0, -extraRotation.toFloat(), 0f, 0f, 1f)
        android.opengl.Matrix.translateM(texM, 0, -0.5f, -0.5f, 0f)
        // combined = texM * cameraTransform  → rotation applied to the OES-mapped coords.
        // Keep `transformMatrix` as the RAW OES matrix (only refreshed on the first
        // surface via getTransformMatrix); each surface — Flutter texture, platform
        // SurfaceView, recorder — re-derives its own crop into this LOCAL matrix.
        // Overwriting the shared field double-transformed the 2nd+ surface (broke
        // platform-view mode).
        val stMatrix = FloatArray(16)
        android.opengl.Matrix.multiplyMM(stMatrix, 0, texM, 0, transformMatrix, 0)
        // Base texcoords (rotation now lives in uSTMatrix).
        texCoordBuffer.clear()
        texCoordBuffer.put(floatArrayOf(0f, 0f, 1f, 0f, 0f, 1f, 1f, 1f))
        texCoordBuffer.position(0)

        isFirstFrame = false
        GLES20.glUseProgram(program)
        GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
        GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)
        GLES20.glUniformMatrix4fv(mhLoc, 1, false, stMatrix, 0)
        GLES20.glUniformMatrix4fv(upLoc, 1, false, projectionMatrix, 0)
        
        val timeLoc = GLES20.glGetUniformLocation(program, "time")
        if (timeLoc != -1) {
            GLES20.glUniform1f(timeLoc, (System.currentTimeMillis() % 1000000) / 1000f)
        }

        val dkLoc = GLES20.glGetUniformLocation(program, "uDistK")
        if (dkLoc != -1) GLES20.glUniform3f(dkLoc, distK1, distK2, distK3)
        val dfLoc = GLES20.glGetUniformLocation(program, "uDistFocal")
        if (dfLoc != -1) GLES20.glUniform1f(dfLoc, distFocal)

        GLES20.glEnableVertexAttribArray(phLoc)
        GLES20.glVertexAttribPointer(phLoc, 2, GLES20.GL_FLOAT, false, 8, vertexBuffer)
        GLES20.glEnableVertexAttribArray(thLoc)
        GLES20.glVertexAttribPointer(thLoc, 2, GLES20.GL_FLOAT, false, 8, texCoordBuffer)
        GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

        if (surface == recorderEglSurface) {
             // Sync timestamps for recorder smooth playback
             val nsecs = st.timestamp
             EGLExt.eglPresentationTimeANDROID(eglDisplay, surface, nsecs)
        }

        if (!EGL14.eglSwapBuffers(eglDisplay, surface)) {
            val err = EGL14.eglGetError()
            if (err == EGL14.EGL_BAD_SURFACE || err == 0x300D) {
                Log.w("NitroCamera", "NitraRenderer: Platform surface became bad, detaching.")
                if (surface == platformEglSurface) {
                    detachPlatformSurface()
                } else if (surface == recorderEglSurface) {
                    setRecordingSurface(null)
                }
            } else {
                Log.w("NitroCamera", "eglSwapBuffers failed: 0x${Integer.toHexString(err)}")
            }
        }
    }


    fun release() {
        if (eglDisplay != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)

            // Delete GL resources before destroying context
            if (program != 0) GLES20.glDeleteProgram(program)
            if (textureId != -1) {
                GLES20.glDeleteTextures(1, intArrayOf(textureId), 0)
            }

            EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(eglDisplay, eglSurface)
            EGL14.eglDestroyContext(eglDisplay, eglContext)
            EGL14.eglTerminate(eglDisplay)
        }
        inputSurface?.release()
        inputSurfaceTexture?.release()
        outputSurface?.release()
        eglDisplay = EGL14.EGL_NO_DISPLAY
        eglContext = EGL14.EGL_NO_CONTEXT
        eglSurface = EGL14.EGL_NO_SURFACE
    }

    private fun createProgram(vs: String, fs: String): Int {
        val vShader = loadShader(GLES20.GL_VERTEX_SHADER, vs)
        val fShader = loadShader(GLES20.GL_FRAGMENT_SHADER, fs)
        if (vShader == 0 || fShader == 0) return 0

        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vShader)
        GLES20.glAttachShader(p, fShader)
        GLES20.glLinkProgram(p)

        val linkStatus = IntArray(1)
        GLES20.glGetProgramiv(p, GLES20.GL_LINK_STATUS, linkStatus, 0)
        if (linkStatus[0] != GLES20.GL_TRUE) {
            Log.e("NitroCamera", "NitraRenderer: Program link error: ${GLES20.glGetProgramInfoLog(p)}")
            GLES20.glDeleteProgram(p)
            return 0
        }
        return p
    }

    private fun loadShader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type)
        if (s == 0) return 0
        GLES20.glShaderSource(s, source)
        GLES20.glCompileShader(s)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, compiled, 0)
        if (compiled[0] == 0) {
            Log.e("NitroCamera", "NitraRenderer: Shader compile error (${if (type == GLES20.GL_VERTEX_SHADER) "VS" else "FS"}): ${GLES20.glGetShaderInfoLog(s)}")
            GLES20.glDeleteShader(s)
            return 0
        }
        return s
    }

    // --- Still Capture Post-Processing ---

    fun applyFilterToStill(inputBytes: ByteArray, shader: String): ByteArray {
        try {
            // 1. Convert OES shader to 2D shader (since we're processing a static bitmap)
            val stillFS = if (shader.isEmpty()) PASSTHROUGH_FS.replace("samplerExternalOES", "sampler2D")
                          else shader.replace("samplerExternalOES", "sampler2D")
                                    .replace("sTexture", "sTextureStill")
                                    .replace("#extension GL_OES_EGL_image_external : require", "")

            val fullStillFS = """
                precision highp float;
                varying vec2 vTextureCoord;
                uniform sampler2D sTextureStill;
                #define fragColor gl_FragColor
                #define uv vTextureCoord
                #define inputColor (texture2D(sTextureStill, vTextureCoord))
                $stillFS
            """.trimIndent()

            // 2. Decode bitmap to get dimensions
            val options = android.graphics.BitmapFactory.Options().apply { inMutable = true }
            val bitmap = android.graphics.BitmapFactory.decodeByteArray(inputBytes, 0, inputBytes.size, options) ?: return inputBytes
            val w = bitmap.width
            val h = bitmap.height

            // 3. Setup Offscreen GL
            val dpy = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
            val ver = IntArray(2)
            EGL14.eglInitialize(dpy, ver, 0, ver, 1)

            val confSpec = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
                EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_NONE
            )
            val configs = arrayOfNulls<EGLConfig>(1)
            EGL14.eglChooseConfig(dpy, confSpec, 0, configs, 0, 1, IntArray(1), 0)

            val ctx = EGL14.eglCreateContext(dpy, configs[0], EGL14.EGL_NO_CONTEXT, intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE), 0)
            val surf = EGL14.eglCreatePbufferSurface(dpy, configs[0], intArrayOf(EGL14.EGL_WIDTH, w, EGL14.EGL_HEIGHT, h, EGL14.EGL_NONE), 0)
            EGL14.eglMakeCurrent(dpy, surf, surf, ctx)

            // 4. Render
            val simpleVS = "attribute vec4 position; attribute vec2 texCoord; varying vec2 vTextureCoord; void main() { gl_Position = position; vTextureCoord = texCoord; }"
            val prg = createProgram(simpleVS, fullStillFS)
            if (prg != 0) {
                GLES20.glViewport(0, 0, w, h)
                val tex = IntArray(1); GLES20.glGenTextures(1, tex, 0)
                GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex[0])
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
                GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
                GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)

                GLES20.glUseProgram(prg)
                GLES20.glUniform1i(GLES20.glGetUniformLocation(prg, "sTextureStill"), 0)

                val vBuf = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(floatArrayOf(-1f,-1f, 1f,-1f, -1f,1f, 1f,1f)); position(0) }
                val tBuf = ByteBuffer.allocateDirect(32).order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(floatArrayOf(0f,0f, 1f,0f, 0f,1f, 1f,1f)); position(0) }

                val pLoc = GLES20.glGetAttribLocation(prg, "position")
                val tcLoc = GLES20.glGetAttribLocation(prg, "texCoord")
                GLES20.glEnableVertexAttribArray(pLoc); GLES20.glVertexAttribPointer(pLoc, 2, GLES20.GL_FLOAT, false, 8, vBuf)
                GLES20.glEnableVertexAttribArray(tcLoc); GLES20.glVertexAttribPointer(tcLoc, 2, GLES20.GL_FLOAT, false, 8, tBuf)

                GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

                // Read back to bitmap
                val outBuf = ByteBuffer.allocateDirect(w * h * 4)
                GLES20.glReadPixels(0, 0, w, h, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, outBuf)
                bitmap.copyPixelsFromBuffer(outBuf.rewind())
            }

            // 5. Cleanup & Return
            EGL14.eglMakeCurrent(dpy, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            EGL14.eglDestroySurface(dpy, surf)
            EGL14.eglDestroyContext(dpy, ctx)
            EGL14.eglTerminate(dpy)

            val outStream = java.io.ByteArrayOutputStream()
            bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 95, outStream)
            return outStream.toByteArray()
        } catch (e: Exception) {
            Log.e("NitroCamera", "applyFilterToStill failed: ${e.message}")
            return inputBytes
        }
    }
}
