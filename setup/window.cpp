// Win32 window + D3D11 swap chain for the setup GUI, after Dear ImGui's
// example_win32_directx11. Zig draws the UI between win_begin and win_end.
#include "imgui.h"
#include "imgui_impl_win32.h"
#include "imgui_impl_dx11.h"
#include <d3d11.h>
#include <commdlg.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <string.h>
#include <stdlib.h>

static ID3D11Device* dev;
static ID3D11DeviceContext* ctx;
static IDXGISwapChain* chain;
static ID3D11RenderTargetView* rtv;
static UINT resize_w, resize_h;
static HWND hwnd;
extern "C" void setup_style(void); // setup/main.zig
static char gpu_name[128];

static void createTarget() {
    ID3D11Texture2D* bb;
    chain->GetBuffer(0, IID_PPV_ARGS(&bb));
    dev->CreateRenderTargetView(bb, nullptr, &rtv);
    bb->Release();
}

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(HWND, UINT, WPARAM, LPARAM);

static LRESULT WINAPI wndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    if (ImGui_ImplWin32_WndProcHandler(h, msg, wp, lp)) return true;
    switch (msg) {
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) resize_w = LOWORD(lp), resize_h = HIWORD(lp);
        return 0;
    case WM_SYSCOMMAND:
        if ((wp & 0xfff0) == SC_KEYMENU) return 0;
        break;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

extern "C" bool win_init(const wchar_t* title, int w, int h) {
    ImGui_ImplWin32_EnableDpiAwareness();
    float scale = ImGui_ImplWin32_GetDpiScaleForMonitor(MonitorFromPoint(POINT{0, 0}, MONITOR_DEFAULTTOPRIMARY));
    WNDCLASSEXW wc = {sizeof(wc), CS_CLASSDC, wndProc, 0, 0, GetModuleHandleW(nullptr), nullptr, LoadCursor(nullptr, IDC_ARROW), nullptr, nullptr, L"OtogiSetup", nullptr};
    RegisterClassExW(&wc);
    hwnd = CreateWindowW(wc.lpszClassName, title, WS_OVERLAPPEDWINDOW, 100, 100, (int)(w * scale), (int)(h * scale), nullptr, nullptr, wc.hInstance, nullptr);
    DXGI_SWAP_CHAIN_DESC sd = {};
    sd.BufferCount = 2;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    const D3D_FEATURE_LEVEL levels[2] = {D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0};
    D3D_FEATURE_LEVEL got;
    HRESULT r = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, levels, 2, D3D11_SDK_VERSION, &sd, &chain, &dev, &got, &ctx);
    if (r != S_OK) // no usable GPU (a bare VM): software
        r = D3D11CreateDeviceAndSwapChain(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, 0, levels, 2, D3D11_SDK_VERSION, &sd, &chain, &dev, &got, &ctx);
    if (r != S_OK) return false;
    IDXGIDevice* dxgi;
    IDXGIAdapter* adapter;
    DXGI_ADAPTER_DESC desc;
    if (dev->QueryInterface(IID_PPV_ARGS(&dxgi)) == S_OK) {
        if (dxgi->GetAdapter(&adapter) == S_OK) {
            if (adapter->GetDesc(&desc) == S_OK) WideCharToMultiByte(CP_UTF8, 0, desc.Description, -1, gpu_name, sizeof gpu_name, nullptr, nullptr);
            adapter->Release();
        }
        dxgi->Release();
    }
    createTarget();
    ShowWindow(hwnd, SW_SHOWDEFAULT);
    ImGui::CreateContext();
    ImGui::GetIO().IniFilename = nullptr;
    // Zig sets colors and sizes (style()), then scales them here once.
    setup_style();
    ImGui::GetStyle().ScaleAllSizes(scale);
    ImGui::GetStyle().FontScaleDpi = scale;
    ImGui_ImplWin32_Init(hwnd);
    ImGui_ImplDX11_Init(dev, ctx);
    return true;
}

// false once the window is closed.
extern "C" bool win_begin() {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
        if (msg.message == WM_QUIT) return false;
    }
    if (resize_w != 0 && resize_h != 0) {
        rtv->Release();
        chain->ResizeBuffers(0, resize_w, resize_h, DXGI_FORMAT_UNKNOWN, 0);
        resize_w = resize_h = 0;
        createTarget();
    }
    ImGui_ImplDX11_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    return true;
}

extern "C" void win_end() {
    ImGui::Render();
    const float clear[4] = {0.1f, 0.1f, 0.12f, 1};
    ctx->OMSetRenderTargets(1, &rtv, nullptr);
    ctx->ClearRenderTargetView(rtv, clear);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
    chain->Present(1, 0);
}

// File > Open dialog for a disc image; buf gets the UTF-8 path.
extern "C" bool win_pick_iso(char* buf, int len) {
    wchar_t path[MAX_PATH] = L"";
    OPENFILENAMEW ofn = {sizeof(ofn)};
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter = L"Xbox disc image (*.iso)\0*.iso\0All files\0*.*\0";
    ofn.lpstrFile = path;
    ofn.nMaxFile = MAX_PATH;
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST;
    if (!GetOpenFileNameW(&ofn)) return false;
    return WideCharToMultiByte(CP_UTF8, 0, path, -1, buf, len, nullptr, nullptr) > 0;
}

extern "C" const char* win_gpu_name() { return gpu_name; }

// Open a file or folder the way Explorer would (Play, Open folder, Open log).
extern "C" void win_open(const char* path) {
    wchar_t w[MAX_PATH];
    if (MultiByteToWideChar(CP_UTF8, 0, path, -1, w, MAX_PATH) == 0) return;
    ShellExecuteW(hwnd, L"open", w, nullptr, nullptr, SW_SHOWNORMAL);
}

// Folder picker; buf gets the UTF-8 path.
extern "C" bool win_pick_folder(char* buf, int len) {
    bool ok = false;
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IFileOpenDialog* dlg;
    if (CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dlg)) == S_OK) {
        DWORD opts;
        dlg->GetOptions(&opts);
        dlg->SetOptions(opts | FOS_PICKFOLDERS);
        IShellItem* item;
        wchar_t* path;
        if (dlg->Show(hwnd) == S_OK && dlg->GetResult(&item) == S_OK) {
            if (item->GetDisplayName(SIGDN_FILESYSPATH, &path) == S_OK) {
                ok = WideCharToMultiByte(CP_UTF8, 0, path, -1, buf, len, nullptr, nullptr) > 0;
                CoTaskMemFree(path);
            }
            item->Release();
        }
        dlg->Release();
    }
    return ok;
}

// ── Textures for the UI: ImTextureID is the shader resource view ──────────

static void* makeTexture(DXGI_FORMAT fmt, const void* px, UINT pitch, int w, int h) {
    D3D11_TEXTURE2D_DESC td = {};
    td.Width = w;
    td.Height = h;
    td.MipLevels = 1;
    td.ArraySize = 1;
    td.Format = fmt;
    td.SampleDesc.Count = 1;
    td.Usage = D3D11_USAGE_IMMUTABLE;
    td.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    D3D11_SUBRESOURCE_DATA sd = {px, pitch, 0};
    ID3D11Texture2D* tex;
    if (dev->CreateTexture2D(&td, &sd, &tex) != S_OK) return nullptr;
    ID3D11ShaderResourceView* srv = nullptr;
    dev->CreateShaderResourceView(tex, nullptr, &srv);
    tex->Release();
    return srv;
}

// A JPG/PNG kept in the exe (setup/assets/art), through WIC, the image codecs
// Windows ships.
extern "C" void* win_texture_image(const unsigned char* data, int len, int* w, int* h) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IWICImagingFactory* wic;
    if (CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)) != S_OK) return nullptr;
    void* out = nullptr;
    IWICStream* stream;
    IWICBitmapDecoder* dec;
    IWICBitmapFrameDecode* frame;
    IWICFormatConverter* conv;
    if (wic->CreateStream(&stream) == S_OK) {
        if (stream->InitializeFromMemory((BYTE*)data, len) == S_OK && wic->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnDemand, &dec) == S_OK) {
            if (dec->GetFrame(0, &frame) == S_OK) {
                if (wic->CreateFormatConverter(&conv) == S_OK) {
                    UINT uw, uh;
                    frame->GetSize(&uw, &uh);
                    if (conv->Initialize(frame, GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom) == S_OK) {
                        unsigned char* px = (unsigned char*)malloc(uw * uh * 4);
                        if (px && conv->CopyPixels(nullptr, uw * 4, uw * uh * 4, px) == S_OK) {
                            *w = uw;
                            *h = uh;
                            out = makeTexture(DXGI_FORMAT_R8G8B8A8_UNORM, px, uw * 4, uw, uh);
                        }
                        free(px);
                    }
                    conv->Release();
                }
                frame->Release();
            }
            dec->Release();
        }
        stream->Release();
    }
    wic->Release();
    return out;
}

// A font kept in the exe: the atlas must not free it.
extern "C" ImFont* win_font_memory(const void* data, int len) {
    ImFontConfig cfg;
    cfg.FontDataOwnedByAtlas = false;
    return ImGui::GetIO().Fonts->AddFontFromMemoryTTF((void*)data, len, 17, &cfg);
}
