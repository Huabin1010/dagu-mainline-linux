/* SPDX-License-Identifier: MIT
 * glbench: which OpenGL does this process get, and how fast is it?
 *
 * dagu has no GPU driver, so Windows' own opengl32.dll falls back to the GDI
 * "Generic" software renderer (OpenGL 1.1). Most 3D apps need GL 3.3+ and
 * refuse to start on that. Dropping Mesa's llvmpipe opengl32.dll next to an
 * app's .exe replaces it app-locally with OpenGL 4.5 on the CPU. This prints
 * GL_VENDOR / GL_RENDERER / GL_VERSION and a lit-mesh frame rate, so the two
 * can be compared. Uses only GL 1.1 calls so both paths can run it.
 *
 *   glbench.exe [width height]     (default 1280 800)
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <gl/gl.h>

int _fltused = 0;
void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }

static HANDLE gOut;
static int gSwap;
static void Puts(const char *s) { DWORD w, n = 0; if (!s) s = "(null)"; while (s[n]) n++; WriteFile(gOut, s, n, &w, NULL); }
static void PutU(unsigned v) { char b[12]; int i = 11; b[i] = 0; do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v); Puts(b + i); }

static unsigned ParseU(const char *s) { unsigned v = 0; while (*s >= '0' && *s <= '9') v = v * 10 + (unsigned)(*s++ - '0'); return v; }

#define GRID 96
static float gVtx[GRID * GRID * 6 * 3];
static float gNrm[GRID * GRID * 6 * 3];

/* cheap sin/cos (no CRT) */
static float Sin(float x)
{
    const float pi = 3.14159265f, tp = 6.2831853f;
    float y;
    while (x > pi) x -= tp;
    while (x < -pi) x += tp;
    y = 1.27323954f * x - 0.405284735f * x * (x < 0 ? -x : x);
    return 0.225f * (y * (y < 0 ? -y : y) - y) + y;
}

static void BuildMesh(float t)
{
    static const int ox[6] = { 0, 1, 0, 1, 1, 0 }, oy[6] = { 0, 0, 1, 0, 1, 1 };
    int cx, cy, k, n = 0;
    for (cy = 0; cy < GRID; cy++)
        for (cx = 0; cx < GRID; cx++)
            for (k = 0; k < 6; k++) {
                float gx = (float)(cx + ox[k]) / GRID, gy = (float)(cy + oy[k]) / GRID;
                float h = 0.08f * Sin(gx * 18 + t) * Sin(gy * 14 + t * 0.7f + 1.57f);
                gVtx[n] = gx * 2 - 1; gVtx[n + 1] = gy * 2 - 1; gVtx[n + 2] = h;
                gNrm[n] = -Sin(gx * 18 + t + 1.57f) * 0.5f; gNrm[n + 1] = Sin(gy * 14 + t) * 0.4f; gNrm[n + 2] = 1;
                n += 3;
            }
}

void start(void)
{
    WNDCLASSA wc = {0};
    PIXELFORMATDESCRIPTOR pfd = {0};
    HWND hw;
    HDC dc;
    HGLRC rc;
    int pf, i, argc = 0;
    unsigned w = 1280, h = 800, frames = 0, fps10;
    LARGE_INTEGER f, a, b;
    double secs = 0;
    float t = 0;
    static const float lp[4] = { 0.4f, 0.6f, 1, 0 }, dif[4] = { 0.3f, 0.5f, 0.8f, 1 };
    char *cmd = GetCommandLineA(), *args[4];

    gOut = GetStdHandle(STD_OUTPUT_HANDLE);
    /* tiny argv split */
    while (*cmd && argc < 4) {
        while (*cmd == ' ') cmd++;
        if (!*cmd) break;
        args[argc++] = cmd;
        if (*cmd == '"') { cmd++; while (*cmd && *cmd != '"') cmd++; if (*cmd) cmd++; }
        else while (*cmd && *cmd != ' ') cmd++;
        if (*cmd) *cmd++ = 0;
    }
    if (argc >= 3) { w = ParseU(args[1]); h = ParseU(args[2]); }
    if (argc >= 4 && args[3][0] == 's') gSwap = 1;   /* "swap": visible window + SwapBuffers */

    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "glbench";
    RegisterClassA(&wc);
    hw = CreateWindowA("glbench", "glbench", WS_POPUP, 0, 0, (int)w, (int)h, NULL, NULL, wc.hInstance, NULL);
    if (gSwap) ShowWindow(hw, SW_SHOWNORMAL);
    dc = GetDC(hw);
    pfd.nSize = sizeof(pfd); pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA; pfd.cColorBits = 32; pfd.cDepthBits = 24;
    pf = ChoosePixelFormat(dc, &pfd);
    if (!pf || !SetPixelFormat(dc, pf, &pfd)) { Puts("pixel format failed\n"); ExitProcess(1); }
    rc = wglCreateContext(dc);
    if (!rc || !wglMakeCurrent(dc, rc)) { Puts("context failed\n"); ExitProcess(2); }

    Puts("GL_VENDOR   = "); Puts((const char *)glGetString(GL_VENDOR)); Puts("\n");
    Puts("GL_RENDERER = "); Puts((const char *)glGetString(GL_RENDERER)); Puts("\n");
    Puts("GL_VERSION  = "); Puts((const char *)glGetString(GL_VERSION)); Puts("\n");

    glViewport(0, 0, (GLsizei)w, (GLsizei)h);
    glEnable(GL_DEPTH_TEST);
    glEnable(GL_LIGHTING); glEnable(GL_LIGHT0); glEnable(GL_NORMALIZE);
    glLightfv(GL_LIGHT0, GL_POSITION, lp);
    glMaterialfv(GL_FRONT_AND_BACK, GL_DIFFUSE, dif);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_NORMAL_ARRAY);
    glVertexPointer(3, GL_FLOAT, 0, gVtx);
    glNormalPointer(GL_FLOAT, 0, gNrm);

    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&a);
    do {
        BuildMesh(t);
        glClearColor(0.05f, 0.05f, 0.08f, 1);
        glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
        for (i = 0; i < 6; i++) {          /* 6 layers, like d3dbench */
            glLoadIdentity();
            glTranslatef(0, 0, -0.2f - i * 0.12f);
            glDrawArrays(GL_TRIANGLES, 0, GRID * GRID * 6);
        }
        if (gSwap) {
            MSG m;
            while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&m);
            SwapBuffers(dc);
        } else {
            glFinish();
        }
        frames++;
        t += 0.05f;
        QueryPerformanceCounter(&b);
        secs = (double)(b.QuadPart - a.QuadPart) / (double)f.QuadPart;
    } while (secs < 6.0 || frames < 3);

    fps10 = (unsigned)(frames * 10.0 / secs + 0.5);
    PutU(w); Puts("x"); PutU(h); Puts("  "); PutU(GRID * GRID * 2 * 6); Puts(" tris  ");
    PutU(fps10 / 10); Puts("."); PutU(fps10 % 10); Puts(" fps\n");
    wglMakeCurrent(NULL, NULL);
    wglDeleteContext(rc);
    ExitProcess(0);
}
