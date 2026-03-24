package dev.shreeman.nitro_camera

import android.graphics.SurfaceTexture
import android.opengl.*
import android.util.Log
import android.view.Surface
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/**
 * High-performance GPU-accelerated OpenGL Renderer for the Nitro Camera pipeline.
 * Implements a programmable video filter chain using GLSL Shaders.
 * 
 * Flow: Camera (OES Texture) -> OpenGL Shader -> Output Surface (Flutter Texture)
 */
class NitraRenderer(private val width: Int, private val height: Int) {
    private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var eglSurface: EGLSurface = EGL14.EGL_NO_SURFACE

    private var program: Int = 0
    private var textureId: Int = -1
    var inputSurfaceTexture: SurfaceTexture? = null
    var inputSurface: Surface? = null
    private var outputSurface: Surface? = null

    private var vertexBuffer: FloatBuffer
    private var texCoordBuffer: FloatBuffer

    private var transformMatrix = FloatArray(16)
    private val vertexShader = "attribute vec4 position;\n" +
            "attribute vec4 texCoord;\n" +
            "varying vec2 vTextureCoord;\n" +
            "uniform mat4 uSTMatrix;\n" +
            "void main() {\n" +
            "    gl_Position = position;\n" +
            "    vTextureCoord = (uSTMatrix * texCoord).xy;\n" +
            "}\n"

    private val PASSTHROUGH_FS =
        "#extension GL_OES_EGL_image_external : require\n" +
        "precision mediump float;\n" +
        "varying vec2 vTextureCoord;\n" +
        "uniform samplerExternalOES sTexture;\n" +
        "void main() {\n" +
        "    gl_FragColor = texture2D(sTexture, vTextureCoord);\n" +
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
        initEGL()
        initGL()
    }

    private fun initEGL() {
        eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        EGL14.eglInitialize(eglDisplay, version, 0, version, 1)

        val configSpec = intArrayOf(
            EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
            EGL14.EGL_ALPHA_SIZE, 8, EGL14.EGL_NONE
        )
        val configs = arrayOfNulls<EGLConfig>(1)
        val numConfigs = IntArray(1)
        EGL14.eglChooseConfig(eglDisplay, configSpec, 0, configs, 0, 1, numConfigs, 0)

        val attribList = intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE)
        eglContext = EGL14.eglCreateContext(eglDisplay, configs[0], EGL14.EGL_NO_CONTEXT, attribList, 0)

        val surfaceAttribs = intArrayOf(EGL14.EGL_NONE)
        eglSurface = EGL14.eglCreateWindowSurface(eglDisplay, configs[0], outputSurface, surfaceAttribs, 0)

        EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
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
        
        // IMPORTANT: Release context from this thread so the rendering thread can pick it up later in drawFrame()
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
    }

    private var phLoc: Int = -1
    private var thLoc: Int = -1
    private var mhLoc: Int = -1

    fun updateShader(shader: String) {
        if (fragmentShader == shader) return
        
        if (shader.isEmpty()) {
            fragmentShader = PASSTHROUGH_FS
        } else {
            // Build a compatibility wrapper for user shaders
            fragmentShader = 
                "#extension GL_OES_EGL_image_external : require\n" +
                "precision mediump float;\n" +
                "varying vec2 vTextureCoord;\n" +
                "uniform samplerExternalOES sTexture;\n" +
                "\n" +
                "// Compatibility macros for user-friendly filter writing\n" +
                "#define fragColor gl_FragColor\n" +
                "#define uv vTextureCoord\n" +
                "#define inputColor (texture2D(sTexture, vTextureCoord))\n" +
                "\n" +
                shader
        }
        
        // Signal drawFrame to re-init the program
        if (program != 0) {
            program = 0
            phLoc = -1
        }
    }

    fun drawFrame() {
        if (eglDisplay == EGL14.EGL_NO_DISPLAY || eglSurface == EGL14.EGL_NO_SURFACE) return
        
        try {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            
            if (program == 0 || phLoc == -1) {
                Log.d("NitroCamera", "NitraRenderer: initProgram (w=$width, h=$height)")
                setupProgram() 
                if (program == 0 || phLoc == -1) return
            }

            // 1. Update Texture (Critical: must be on GL thread)
            val st = inputSurfaceTexture ?: return
            try {
                st.updateTexImage()
                st.getTransformMatrix(transformMatrix)
            } catch (e: Exception) {
                // If this fails, the camera likely hasn't pushed a frame yet.
                // We'll skip this draw to avoid GL_INVALID_OPERATION
                return
            }

            GLES20.glViewport(0, 0, width, height)
            GLES20.glClearColor(1.0f, 0.0f, 0.0f, 1.0f) // RED CLEAR FOR DEBUG
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glUseProgram(program)

            GLES20.glActiveTexture(GLES20.GL_TEXTURE0)
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId)

            GLES20.glUniformMatrix4fv(mhLoc, 1, false, transformMatrix, 0)
            
            GLES20.glEnableVertexAttribArray(phLoc)
            GLES20.glVertexAttribPointer(phLoc, 2, GLES20.GL_FLOAT, false, 8, vertexBuffer)
            
            GLES20.glEnableVertexAttribArray(thLoc)
            GLES20.glVertexAttribPointer(thLoc, 2, GLES20.GL_FLOAT, false, 8, texCoordBuffer)
            
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

            if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
                Log.e("NitroCamera", "NitraRenderer: eglSwapBuffers failed")
                val err = EGL14.eglGetError()
                if (err != EGL14.EGL_SUCCESS) {
                    Log.e("NitroCamera", "NitraRenderer: eglSwapBuffers failed: 0x${Integer.toHexString(err)}")
                }
            }
            // checkGLError("drawFrame") // Too noisy for 60fps
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraRenderer: Draw internal error: ${e.message}")
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
}
