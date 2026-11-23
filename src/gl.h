/* EGL and GL ES 3 (ANGLE's on Windows, the system's on Linux), for translate-c
 * (src/gl_hle.zig imports it as "gl"). */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#ifdef _WIN32
#include <EGL/eglext_angle.h>
#endif
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
