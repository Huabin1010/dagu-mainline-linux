/* SPDX-License-Identifier: MIT
 * d3dbench: offscreen Direct3D 11 throughput test for dagu Windows.
 *
 * dagu has no working GPU driver, so D3D runs on the Microsoft Basic Render
 * Driver (WARP, CPU rasterizer). This draws a depth-tested, lit mesh into an
 * offscreen render target at several resolutions and prints frames per
 * second, so CPU / power-plan / resolution changes can be compared with a
 * number instead of a feeling. No CRT; links kernel32/d3d11/d3dcompiler only.
 *
 *   d3dbench.exe            run all resolutions
 * Output: one line per resolution, "WxH  N tris  F.F fps".
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d11.h>
#include <d3dcompiler.h>
#include <dxgi1_2.h>

int _fltused = 0;

void *memset(void *d, int c, size_t n) { unsigned char *p = d; while (n--) *p++ = (unsigned char)c; return d; }
void *memcpy(void *d, const void *s, size_t n) { unsigned char *p = d; const unsigned char *q = s; while (n--) *p++ = *q++; return d; }

static HANDLE gOut;
static void Puts(const char *s) { DWORD w, n = 0; while (s[n]) n++; WriteFile(gOut, s, n, &w, NULL); }
static void PutU(unsigned v) { char b[12]; int i = 11; b[i] = 0; do { b[--i] = (char)('0' + v % 10); v /= 10; } while (v); Puts(b + i); }

/* Grid of GRID x GRID quads per layer, LAYERS layers back to front.
 * Vertex shader builds positions from SV_VertexID (no vertex buffer). */
#define GRID   96
#define LAYERS 6

static const char kShader[] =
"cbuffer C : register(b0) { float t; float3 pad; };\n"
"struct V { float4 p : SV_Position; float3 n : N; float2 uv : T; };\n"
"V vs(uint id : SV_VertexID) {\n"
"  const uint G = 96;\n"
"  uint q = id / 6, k = id % 6, layer = q / (G*G), cell = q % (G*G);\n"
"  uint cx = cell % G, cy = cell / G;\n"
"  uint2 o[6] = { uint2(0,0), uint2(1,0), uint2(0,1), uint2(1,0), uint2(1,1), uint2(0,1) };\n"
"  float2 g = (float2(cx, cy) + o[k]) / G;\n"
"  float h = 0.08 * sin(g.x * 18 + t) * cos(g.y * 14 + t * 0.7);\n"
"  V v; v.uv = g;\n"
"  v.p = float4(g * 2 - 1, 0.2 + layer * 0.12 + h, 1);\n"
"  v.n = normalize(float3(-cos(g.x*18+t)*1.4, sin(g.y*14+t*0.7)*1.1, 1));\n"
"  return v;\n"
"}\n"
"float4 ps(V i) : SV_Target {\n"
"  float3 L = normalize(float3(0.4, 0.6, 1));\n"
"  float d = saturate(dot(i.n, L));\n"
"  float3 H = normalize(L + float3(0, 0, 1));\n"
"  float s = pow(saturate(dot(i.n, H)), 24);\n"
"  float c = 0;\n"
"  [unroll] for (int k = 0; k < 8; k++) c += sin(i.uv.x * (k + 3) * 9 + t) * cos(i.uv.y * (k + 2) * 7);\n"
"  float3 base = float3(0.3, 0.5, 0.8) + 0.05 * c;\n"
"  return float4(base * (0.2 + d) + s, 1);\n"
"}\n";

static ID3DBlob *Compile(const char *entry, const char *target)
{
    ID3DBlob *code = NULL, *err = NULL;
    if (FAILED(D3DCompile(kShader, sizeof(kShader) - 1, "bench", NULL, NULL, entry, target,
                          D3DCOMPILE_OPTIMIZATION_LEVEL3, 0, &code, &err))) {
        Puts("shader compile failed: ");
        if (err) Puts((const char *)ID3D10Blob_GetBufferPointer(err));
        Puts("\n");
        ExitProcess(2);
    }
    return code;
}

static void RunRes(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11VertexShader *vs,
                   ID3D11PixelShader *ps, ID3D11Buffer *cb, UINT w, UINT h)
{
    D3D11_TEXTURE2D_DESC td = {0};
    D3D11_QUERY_DESC qd = {0};
    D3D11_VIEWPORT vp = {0};
    ID3D11Texture2D *rt = NULL, *ds = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11DepthStencilView *dsv = NULL;
    ID3D11Query *q = NULL;
    LARGE_INTEGER f, a, b;
    float clear[4] = { 0.05f, 0.05f, 0.08f, 1 };
    float t = 0;
    UINT frames = 0, verts = GRID * GRID * 6 * LAYERS;
    double secs;
    unsigned fps10;

    td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_R8G8B8A8_UNORM; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt);
    td.Format = DXGI_FORMAT_D24_UNORM_S8_UINT; td.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &ds);
    if (!rt || !ds) { Puts("texture alloc failed\n"); return; }
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv);
    ID3D11Device_CreateDepthStencilView(dev, (ID3D11Resource *)ds, NULL, &dsv);
    qd.Query = D3D11_QUERY_EVENT;
    ID3D11Device_CreateQuery(dev, &qd, &q);

    vp.Width = (float)w; vp.Height = (float)h; vp.MaxDepth = 1;
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, dsv);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &cb);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);

    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&a);
    do {
        float c[4] = { t, 0, 0, 0 };
        ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)cb, 0, NULL, c, 0, 0);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
        ID3D11DeviceContext_ClearDepthStencilView(ctx, dsv, D3D11_CLEAR_DEPTH, 1, 0);
        ID3D11DeviceContext_Draw(ctx, verts, 0);
        ID3D11DeviceContext_End(ctx, (ID3D11Asynchronous *)q);
        while (ID3D11DeviceContext_GetData(ctx, (ID3D11Asynchronous *)q, NULL, 0, 0) == S_FALSE)
            ;                                   /* wait for the frame to finish */
        frames++;
        t += 0.05f;
        QueryPerformanceCounter(&b);
        secs = (double)(b.QuadPart - a.QuadPart) / (double)f.QuadPart;
    } while (secs < 6.0 || frames < 3);

    fps10 = (unsigned)(frames * 10.0 / secs + 0.5);
    PutU(w); Puts("x"); PutU(h); Puts("  "); PutU(verts / 3); Puts(" tris  ");
    PutU(fps10 / 10); Puts("."); PutU(fps10 % 10); Puts(" fps\n");

    ID3D11Query_Release(q);
    ID3D11DepthStencilView_Release(dsv);
    ID3D11RenderTargetView_Release(rtv);
    ID3D11Texture2D_Release(ds);
    ID3D11Texture2D_Release(rt);
}

/* On-screen mode: a visible window with a DXGI swap chain, Present(0) each
 * frame, so the cost of getting frames to the display (DWM + Basic Display)
 * is included. flip=1 uses FLIP_DISCARD, flip=0 the legacy blt model. */
static void RunWindow(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11VertexShader *vs,
                      ID3D11PixelShader *ps, ID3D11Buffer *cb, UINT w, UINT h, int flip)
{
    WNDCLASSA wc = {0};
    HWND hw;
    IDXGIDevice *xd = NULL;
    IDXGIAdapter *xa = NULL;
    IDXGIFactory2 *xf = NULL;
    IDXGISwapChain1 *sc = NULL;
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    ID3D11Texture2D *bb = NULL, *ds = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    ID3D11DepthStencilView *dsv = NULL;
    D3D11_TEXTURE2D_DESC td = {0};
    D3D11_VIEWPORT vp = {0};
    LARGE_INTEGER f, a, b;
    float clear[4] = { 0.05f, 0.05f, 0.08f, 1 }, t = 0;
    UINT frames = 0, verts = GRID * GRID * 6 * LAYERS;
    double secs;
    unsigned fps10;
    HRESULT hr;

    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3dbench";
    RegisterClassA(&wc);
    hw = CreateWindowA("d3dbench", "d3dbench", WS_POPUP | WS_VISIBLE, 0, 0, (int)w, (int)h,
                       NULL, NULL, wc.hInstance, NULL);
    ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&xd);
    IDXGIDevice_GetAdapter(xd, &xa);
    IDXGIAdapter_GetParent(xa, &IID_IDXGIFactory2, (void **)&xf);
    sd.Width = w; sd.Height = h; sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.SwapEffect = flip ? DXGI_SWAP_EFFECT_FLIP_DISCARD : DXGI_SWAP_EFFECT_DISCARD;
    if (!flip) sd.BufferCount = 1;
    hr = IDXGIFactory2_CreateSwapChainForHwnd(xf, (IUnknown *)dev, hw, &sd, NULL, NULL, &sc);
    if (FAILED(hr)) { Puts("CreateSwapChainForHwnd failed\n"); return; }
    IDXGISwapChain1_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    td.Width = w; td.Height = h; td.MipLevels = 1; td.ArraySize = 1;
    td.Format = DXGI_FORMAT_D24_UNORM_S8_UINT; td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_DEFAULT; td.BindFlags = D3D11_BIND_DEPTH_STENCIL;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &ds);
    ID3D11Device_CreateDepthStencilView(dev, (ID3D11Resource *)ds, NULL, &dsv);

    vp.Width = (float)w; vp.Height = (float)h; vp.MaxDepth = 1;
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &cb);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &cb);

    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&a);
    do {
        MSG m;
        float c[4] = { t, 0, 0, 0 };
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) DispatchMessageA(&m);
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, dsv);
        ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)cb, 0, NULL, c, 0, 0);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
        ID3D11DeviceContext_ClearDepthStencilView(ctx, dsv, D3D11_CLEAR_DEPTH, 1, 0);
        ID3D11DeviceContext_Draw(ctx, verts, 0);
        IDXGISwapChain1_Present(sc, 0, 0);
        frames++;
        t += 0.05f;
        QueryPerformanceCounter(&b);
        secs = (double)(b.QuadPart - a.QuadPart) / (double)f.QuadPart;
    } while (secs < 6.0 || frames < 3);

    fps10 = (unsigned)(frames * 10.0 / secs + 0.5);
    Puts(flip ? "window/flip " : "window/blt  ");
    PutU(w); Puts("x"); PutU(h); Puts("  ");
    PutU(fps10 / 10); Puts("."); PutU(fps10 % 10); Puts(" fps\n");
    ID3D11DepthStencilView_Release(dsv); ID3D11Texture2D_Release(ds);
    ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(bb);
    IDXGISwapChain1_Release(sc);
    DestroyWindow(hw);
}

void start(void)
{
    static const UINT res[][2] = { { 2560, 1600 }, { 1920, 1200 }, { 1280, 800 }, { 960, 600 } };
    int window = 0;
    {
        const char *c = GetCommandLineA();
        while (*c) { if (c[0] == ' ' && c[1] == 'w') window = 1; c++; }
    }
    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    ID3D11VertexShader *vs = NULL;
    ID3D11PixelShader *ps = NULL;
    ID3D11Buffer *cb = NULL;
    D3D11_BUFFER_DESC bd = {0};
    D3D_FEATURE_LEVEL fl;
    ID3DBlob *vb, *pb;
    UINT i;

    gOut = GetStdHandle(STD_OUTPUT_HANDLE);
    if (FAILED(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                 D3D11_SDK_VERSION, &dev, &fl, &ctx))) {
        Puts("D3D11CreateDevice failed\n");
        ExitProcess(1);
    }
    Puts("feature level 0x"); { static const char hx[] = "0123456789abcdef"; char b[5];
        b[0] = hx[(fl >> 12) & 15]; b[1] = hx[(fl >> 8) & 15]; b[2] = hx[(fl >> 4) & 15]; b[3] = hx[fl & 15]; b[4] = 0; Puts(b); }
    Puts("\n");
    vb = Compile("vs", "vs_5_0");
    pb = Compile("ps", "ps_5_0");
    ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vb), ID3D10Blob_GetBufferSize(vb), NULL, &vs);
    ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(pb), ID3D10Blob_GetBufferSize(pb), NULL, &ps);
    bd.ByteWidth = 16; bd.Usage = D3D11_USAGE_DEFAULT; bd.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    ID3D11Device_CreateBuffer(dev, &bd, NULL, &cb);
    if (!vs || !ps || !cb) { Puts("pipeline create failed\n"); ExitProcess(3); }

    for (i = 0; i < sizeof(res) / sizeof(res[0]); i++) {
        if (window) {
            RunWindow(dev, ctx, vs, ps, cb, res[i][0], res[i][1], 1);
            RunWindow(dev, ctx, vs, ps, cb, res[i][0], res[i][1], 0);
        } else {
            RunRes(dev, ctx, vs, ps, cb, res[i][0], res[i][1]);
        }
    }
    ExitProcess(0);
}
