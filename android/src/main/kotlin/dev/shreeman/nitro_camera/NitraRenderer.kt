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
    private val vertexShader = """
        attribute vec4 position;
        attribute vec4 texCoord;
        varying vec2 vTextureCoord;
        uniform mat4 uSTMatrix;
        void main() {
            gl_Position = position;
            vTextureCoord = (uSTMatrix * texCoord).xy;
        }
    """.trimIndent()

    // Default Fragment Shader (Pass-through)
    private var fragmentShader = """
        #extension GL_OES_EGL_image_external : require
        precision mediump float;
        varying vec2 vTextureCoord;
        uniform samplerExternalOES sTexture;
        void main() {
            gl_FragColor = texture2D(sTexture, vTextureCoord);
        }
    """.trimIndent()

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
        program = createProgram(vertexShader, fragmentShader)
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
    }

    fun updateShader(shaderSource: String) {
        GLES20.glDeleteProgram(program)
        program = createProgram(vertexShader, shaderSource)
        fragmentShader = shaderSource
    }

    fun drawFrame() {
        if (program == 0 || inputSurfaceTexture == null || eglDisplay == EGL14.EGL_NO_DISPLAY) return
        
        try {
            EGL14.eglMakeCurrent(eglDisplay, eglSurface, eglSurface, eglContext)
            inputSurfaceTexture?.updateTexImage()
            inputSurfaceTexture?.getTransformMatrix(transformMatrix)

            GLES20.glUseProgram(program)
            GLES20.glViewport(0, 0, width, height)
            
            val ph = GLES20.glGetAttribLocation(program, "position")
            val th = GLES20.glGetAttribLocation(program, "texCoord")
            val mh = GLES20.glGetUniformLocation(program, "uSTMatrix")

            if (ph < 0 || th < 0 || mh < 0) {
                if (System.currentTimeMillis() % 1000 < 50) { // Log infrequently to avoid flooding
                    Log.w("NitroCamera", "NitraRenderer: Shader variable locations not found (ph=$ph, th=$th, mh=$mh)")
                }
                return
            }

            GLES20.glVertexAttribPointer(ph, 2, GLES20.GL_FLOAT, false, 8, vertexBuffer)
            GLES20.glVertexAttribPointer(th, 2, GLES20.GL_FLOAT, false, 8, texCoordBuffer)
            GLES20.glEnableVertexAttribArray(ph)
            GLES20.glEnableVertexAttribArray(th)
            GLES20.glUniformMatrix4fv(mh, 1, false, transformMatrix, 0)

            GLES20.glClearColor(0f, 0f, 0f, 1f)
            GLES20.glClear(GLES20.GL_COLOR_BUFFER_BIT)
            GLES20.glDrawArrays(GLES20.GL_TRIANGLE_STRIP, 0, 4)

            if (!EGL14.eglSwapBuffers(eglDisplay, eglSurface)) {
                Log.e("NitroCamera", "NitraRenderer: eglSwapBuffers failed")
            }
            checkGLError("drawFrame")
        } catch (e: Exception) {
            Log.e("NitroCamera", "NitraRenderer: Draw internal error: ${e.message}")
        }
    }

    private fun checkGLError(op: String) {
        val error = GLES20.glGetError()
        if (error != GLES20.GL_NO_ERROR) {
            Log.e("NitroCamera", "NitraRenderer: $op: glError 0x${Integer.toHexString(error)}")
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
        val p = GLES20.glCreateProgram()
        GLES20.glAttachShader(p, vShader)
        GLES20.glAttachShader(p, fShader)
        GLES20.glLinkProgram(p)
        return p
    }

    private fun loadShader(type: Int, source: String): Int {
        val s = GLES20.glCreateShader(type)
        GLES20.glShaderSource(s, source)
        GLES20.glCompileShader(s)
        val compiled = IntArray(1)
        GLES20.glGetShaderiv(s, GLES20.GL_COMPILE_STATUS, compiled, 0)
        if (compiled[0] == 0) {
            Log.e("NitroCamera", "NitraRenderer: Shader compile error: ${GLES20.glGetShaderInfoLog(s)}")
        }
        return s
    }
}
