// Win32 window + D3D11 for the launcher, drawn by RmlUi (its Win32 platform
// and DX11 renderer, Backends/). Zig owns the state: it sets markup by element
// id (ui_set, ui_attr, ...) and gets every on* attribute's value as a command
// (ui_event). The documents, stylesheets, art and fonts live in the exe
// (ui_file, setup/main.zig).
#include "RmlUi_Include_Windows.h"
#include "RmlUi_Platform_Win32.h"
#include "RmlUi_Renderer_DX11.h"
#include <RmlUi/Core.h>
#include <commdlg.h>
#include <dwmapi.h>
#include <shellapi.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <xinput.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unordered_map>

extern "C" void ui_event(const char* cmd, const char* value);           // setup/main.zig
extern "C" const unsigned char* ui_file(const char* path, size_t* len); // setup/main.zig

static HWND hwnd;
static ID3D11Device* dev;
static ID3D11DeviceContext* ctx;
static IDXGISwapChain* chain;
static ID3D11RenderTargetView* rtv;
static bool resized = true;
static int win_w, win_h;
static char gpu_name[128];
static Rml::Context* context;
static Rml::ElementDocument* doc;
class System;
static System* sys;
static TextInputMethodEditor_Win32* ime;

static float dpRatio() { return GetDpiForWindow(hwnd) / 96.0f; }

// OTOGI_UI_LOG=<file>: RmlUi's warnings and errors there (bad markup or styles).
class System : public SystemInterface_Win32 {
public:
    FILE* log = nullptr;
    bool LogMessage(Rml::Log::Type type, const Rml::String& message) override {
        if (log && type <= Rml::Log::LT_WARNING) fprintf(log, "%s\n", message.c_str()), fflush(log);
        return true;
    }
};

// ── Files: embedded first (setup/ui, setup/assets), else the disk (Windows fonts)
struct MemFile {
    const unsigned char* p;
    size_t n, at;
    FILE* f;
};
class Files : public Rml::FileInterface {
public:
    Rml::FileHandle Open(const Rml::String& path) override {
        size_t n = 0;
        const char* name = path.c_str();
        while (*name == '/') name++;
        if (const unsigned char* p = ui_file(name, &n)) return (Rml::FileHandle) new MemFile{p, n, 0, nullptr};
        FILE* f = fopen(path.c_str(), "rb");
        return f ? (Rml::FileHandle) new MemFile{nullptr, 0, 0, f} : 0;
    }
    void Close(Rml::FileHandle h) override {
        MemFile* m = (MemFile*)h;
        if (m->f) fclose(m->f);
        delete m;
    }
    size_t Read(void* buf, size_t size, Rml::FileHandle h) override {
        MemFile* m = (MemFile*)h;
        if (m->f) return fread(buf, 1, size, m->f);
        size = Rml::Math::Min(size, m->n - m->at);
        memcpy(buf, m->p + m->at, size);
        m->at += size;
        return size;
    }
    bool Seek(Rml::FileHandle h, long off, int origin) override {
        MemFile* m = (MemFile*)h;
        if (m->f) return fseek(m->f, off, origin) == 0;
        long base = origin == SEEK_SET ? 0 : origin == SEEK_CUR ? (long)m->at : (long)m->n;
        if (base + off < 0 || base + off > (long)m->n) return false;
        m->at = base + off;
        return true;
    }
    size_t Tell(Rml::FileHandle h) override {
        MemFile* m = (MemFile*)h;
        return m->f ? ftell(m->f) : m->at;
    }
};
static Files files;

// ── Images: JPG/PNG through WIC, the codecs Windows ships ──────────────────
static bool decodeImage(const void* data, size_t len, Rml::Vector<Rml::byte>& px, UINT& w, UINT& h) {
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IWICImagingFactory* wic;
    if (CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)) != S_OK) return false;
    bool ok = false;
    IWICStream* stream;
    IWICBitmapDecoder* dec;
    IWICBitmapFrameDecode* frame;
    IWICFormatConverter* conv;
    if (wic->CreateStream(&stream) == S_OK) {
        if (stream->InitializeFromMemory((BYTE*)data, (DWORD)len) == S_OK && wic->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnDemand, &dec) == S_OK) {
            if (dec->GetFrame(0, &frame) == S_OK) {
                if (wic->CreateFormatConverter(&conv) == S_OK) {
                    frame->GetSize(&w, &h);
                    // RmlUi wants premultiplied alpha.
                    if (conv->Initialize(frame, GUID_WICPixelFormat32bppPRGBA, WICBitmapDitherTypeNone, nullptr, 0, WICBitmapPaletteTypeCustom) == S_OK) {
                        px.resize(w * h * 4);
                        ok = conv->CopyPixels(nullptr, w * 4, (UINT)px.size(), px.data()) == S_OK;
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
    return ok;
}

class Renderer : public RenderInterface_DX11 {
public:
    Renderer(ID3D11Device* d) : RenderInterface_DX11(d) {}
    Rml::TextureHandle LoadTexture(Rml::Vector2i& dims, const Rml::String& source) override {
        Rml::FileHandle f = files.Open(source);
        if (!f) return 0;
        files.Seek(f, 0, SEEK_END);
        Rml::Vector<Rml::byte> bytes(files.Tell(f));
        files.Seek(f, 0, SEEK_SET);
        files.Read(bytes.data(), bytes.size(), f);
        files.Close(f);
        Rml::Vector<Rml::byte> px;
        UINT w, h;
        if (!decodeImage(bytes.data(), bytes.size(), px, w, h)) return 0;
        dims = {(int)w, (int)h};
        return GenerateTexture(px, dims);
    }
};
static Renderer* renderer;

// ── on* attributes: onclick="play" calls ui_event("play", value) ──────────
// "win:min", "win:max" and "win:close" are the title bar's own.
class Listener : public Rml::EventListener {
public:
    Rml::String cmd;
    Listener(const Rml::String& c) : cmd(c) {}
    void ProcessEvent(Rml::Event& e) override {
        if (cmd == "win:min") return (void)ShowWindow(hwnd, SW_MINIMIZE);
        if (cmd == "win:max") return (void)ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        if (cmd == "win:close") return (void)PostMessageW(hwnd, WM_CLOSE, 0, 0);
        Rml::Element* el = e.GetCurrentElement();
        Rml::String v = e.GetParameter<Rml::String>("value", "");
        if (v.empty()) v = el->GetAttribute<Rml::String>("value", "");
        ui_event(cmd.c_str(), v.c_str());
    }
    void OnDetach(Rml::Element*) override { delete this; }
};
class Listeners : public Rml::EventListenerInstancer {
public:
    Rml::EventListener* InstanceEventListener(const Rml::String& value, Rml::Element*) override { return new Listener(value); }
};
static Listeners listeners;

// ── Frameless window: the page draws its own title bar (#titlebar) ─────────
static LRESULT hitTest(POINT p) {
    RECT r;
    GetWindowRect(hwnd, &r);
    const int edge = (int)(6 * dpRatio());
    if (!IsZoomed(hwnd)) {
        bool l = p.x < r.left + edge, rt = p.x >= r.right - edge, t = p.y < r.top + edge, b = p.y >= r.bottom - edge;
        if (t && l) return HTTOPLEFT;
        if (t && rt) return HTTOPRIGHT;
        if (b && l) return HTBOTTOMLEFT;
        if (b && rt) return HTBOTTOMRIGHT;
        if (l) return HTLEFT;
        if (rt) return HTRIGHT;
        if (t) return HTTOP;
        if (b) return HTBOTTOM;
    }
    // In #titlebar but not on anything clickable: drag the window.
    ScreenToClient(hwnd, &p);
    for (Rml::Element* el = context ? context->GetElementAtPoint({(float)p.x, (float)p.y}) : nullptr; el; el = el->GetParentNode()) {
        if (el->HasAttribute("onclick")) return HTCLIENT;
        if (el->GetId() == "titlebar") return HTCAPTION;
    }
    return HTCLIENT;
}

static void createTarget() {
    ID3D11Texture2D* bb;
    chain->GetBuffer(0, IID_PPV_ARGS(&bb));
    dev->CreateRenderTargetView(bb, nullptr, &rtv);
    bb->Release();
}

static LRESULT WINAPI wndProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_NCCALCSIZE:
        if (wp && IsZoomed(h)) { // a maximized window hangs its frame off the screen
            RECT* rc = &((NCCALCSIZE_PARAMS*)lp)->rgrc[0];
            UINT dpi = GetDpiForWindow(h);
            int f = GetSystemMetricsForDpi(SM_CXFRAME, dpi) + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
            rc->left += f, rc->right -= f, rc->top += f, rc->bottom -= f;
        }
        if (wp) return 0; // no caption, no border: the client is the whole window
        break;
    case WM_NCHITTEST:
        return hitTest({(short)LOWORD(lp), (short)HIWORD(lp)});
    case WM_SIZE:
        if (wp != SIZE_MINIMIZED) win_w = LOWORD(lp), win_h = HIWORD(lp), resized = true;
        return 0;
    case WM_DPICHANGED: {
        RECT* r = (RECT*)lp;
        SetWindowPos(h, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top, SWP_NOZORDER | SWP_NOACTIVATE);
        if (context) context->SetDensityIndependentPixelRatio(dpRatio());
        return 0;
    }
    case WM_GETMINMAXINFO:
        ((MINMAXINFO*)lp)->ptMinTrackSize = {(LONG)(880 * dpRatio()), (LONG)(600 * dpRatio())};
        return 0;
    case WM_CLOSE:
        PostQuitMessage(0);
        return 0;
    case WM_KEYDOWN: // Enter or Space on a focused button clicks it
        if ((wp == VK_RETURN || wp == VK_SPACE) && context) {
            Rml::Element* f = context->GetFocusElement();
            if (f && f->HasAttribute("onclick") && f->GetTagName() != "input") {
                f->Click();
                return 0;
            }
        }
        break;
    }
    if (context && !RmlWin32::WindowProcedure(context, *ime, h, msg, wp, lp)) return 0;
    return DefWindowProcW(h, msg, wp, lp);
}

extern "C" bool ui_init(const wchar_t* title, int w, int h) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    WNDCLASSEXW wc = {sizeof(wc), CS_HREDRAW | CS_VREDRAW, wndProc, 0, 0, GetModuleHandleW(nullptr), nullptr, LoadCursor(nullptr, IDC_ARROW), nullptr, nullptr, L"OtogiLauncher", nullptr};
    RegisterClassExW(&wc);
    float scale = GetDpiForSystem() / 96.0f;
    RECT work;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
    w = Rml::Math::Min((int)(w * scale), (int)(work.right - work.left));
    h = Rml::Math::Min((int)(h * scale), (int)(work.bottom - work.top));
    hwnd = CreateWindowExW(0, wc.lpszClassName, title, WS_OVERLAPPEDWINDOW, work.left + (work.right - work.left - w) / 2, work.top + (work.bottom - work.top - h) / 2, w, h, nullptr, nullptr, wc.hInstance, nullptr);
    const MARGINS shadow = {0, 0, 1, 0}; // keeps DWM's shadow and rounded corners
    DwmExtendFrameIntoClientArea(hwnd, &shadow);
    SetWindowPos(hwnd, nullptr, 0, 0, 0, 0, SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER);

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

    sys = new System();
    if (const char* p = getenv("OTOGI_UI_LOG")) sys->log = fopen(p, "w");
    sys->SetWindow(hwnd);
    ime = new TextInputMethodEditor_Win32();
    renderer = new Renderer(dev);
    Rml::SetSystemInterface(sys);
    Rml::SetFileInterface(&files);
    Rml::SetRenderInterface(renderer);
    Rml::SetTextInputHandler(ime);
    Rml::Initialise();
    Rml::Factory::RegisterEventListenerInstancer(&listeners);
    RECT cr;
    GetClientRect(hwnd, &cr);
    win_w = cr.right, win_h = cr.bottom;
    context = Rml::CreateContext("main", {win_w, win_h});
    if (!context) return false;
    context->SetDensityIndependentPixelRatio(dpRatio());
    ShowWindow(hwnd, SW_SHOWDEFAULT);
    return true;
}

// A font from the exe (ui_file) or from disk.
extern "C" bool ui_font(const char* path, bool fallback) { return Rml::LoadFontFace(path, fallback); }

extern "C" bool ui_load(const char* path) {
    doc = context->LoadDocument(path);
    if (doc) doc->Show();
    return doc != nullptr;
}

// ── Controller: d-pad/stick move focus, A clicks, B is "back", LB/RB switch pages
static void pad() {
    static WORD held;
    static ULONGLONG next_repeat;
    XINPUT_STATE s;
    if (XInputGetState(0, &s) != ERROR_SUCCESS) return;
    WORD b = s.Gamepad.wButtons;
    const SHORT dead = 16000;
    if (s.Gamepad.sThumbLY > dead) b |= XINPUT_GAMEPAD_DPAD_UP;
    if (s.Gamepad.sThumbLY < -dead) b |= XINPUT_GAMEPAD_DPAD_DOWN;
    if (s.Gamepad.sThumbLX < -dead) b |= XINPUT_GAMEPAD_DPAD_LEFT;
    if (s.Gamepad.sThumbLX > dead) b |= XINPUT_GAMEPAD_DPAD_RIGHT;
    WORD down = b & ~held;
    const WORD dirs = XINPUT_GAMEPAD_DPAD_UP | XINPUT_GAMEPAD_DPAD_DOWN | XINPUT_GAMEPAD_DPAD_LEFT | XINPUT_GAMEPAD_DPAD_RIGHT;
    ULONGLONG now = GetTickCount64();
    if (down & dirs) next_repeat = now + 400;
    else if ((b & dirs) && now >= next_repeat) down |= b & dirs, next_repeat = now + 120;
    held = b;
    if (!down) return;
    Rml::Element* f = context->GetFocusElement();
    if ((down & dirs) && (!f || f == doc || f == context->GetRootElement())) {
        context->ProcessKeyDown(Rml::Input::KI_TAB, 0); // first press: focus the first control
        return;
    }
    if (down & XINPUT_GAMEPAD_DPAD_UP) context->ProcessKeyDown(Rml::Input::KI_UP, 0);
    if (down & XINPUT_GAMEPAD_DPAD_DOWN) context->ProcessKeyDown(Rml::Input::KI_DOWN, 0);
    if (down & XINPUT_GAMEPAD_DPAD_LEFT) context->ProcessKeyDown(Rml::Input::KI_LEFT, 0);
    if (down & XINPUT_GAMEPAD_DPAD_RIGHT) context->ProcessKeyDown(Rml::Input::KI_RIGHT, 0);
    if ((down & XINPUT_GAMEPAD_A) && f) f->Click();
    if (down & XINPUT_GAMEPAD_B) ui_event("back", "");
    if (down & XINPUT_GAMEPAD_LEFT_SHOULDER) ui_event("page-step", "-1");
    if (down & XINPUT_GAMEPAD_RIGHT_SHOULDER) ui_event("page-step", "1");
}

// One frame: messages, controller, layout, draw. False once the window closes.
extern "C" bool ui_frame() {
    MSG msg;
    while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
        if (msg.message == WM_QUIT) return false;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (GetForegroundWindow() == hwnd) pad();
    if (resized && win_w > 0 && win_h > 0) {
        resized = false;
        rtv->Release();
        chain->ResizeBuffers(0, win_w, win_h, DXGI_FORMAT_UNKNOWN, 0);
        createTarget();
        renderer->SetViewport(win_w, win_h);
        context->SetDimensions({win_w, win_h});
    }
    context->Update();
    renderer->Clear(rtv);
    renderer->BeginFrame();
    context->Render();
    renderer->EndFrame(rtv);
    chain->Present(1, 0);
    if (IsIconic(hwnd)) Sleep(50);
    return true;
}

// ── Zig sets the page by element id. Unchanged values cost nothing. ─────────
static std::unordered_map<Rml::String, Rml::String> last;
static Rml::Element* byId(const char* id) { return doc ? doc->GetElementById(id) : nullptr; }

// Inner markup. Elements with class "follow" (the log) stay scrolled to the end
// while they are at it.
extern "C" void ui_set(const char* id, const char* rml) {
    Rml::Element* el = byId(id);
    if (!el) return;
    auto it = last.find(id);
    if (it != last.end() && it->second == rml) return;
    last[id] = rml;
    const bool follow = el->IsClassSet("follow") && el->GetScrollTop() + el->GetClientHeight() >= el->GetScrollHeight() - 4;
    el->SetInnerRML(rml);
    if (follow) {
        doc->UpdateDocument();
        el->SetScrollTop(el->GetScrollHeight());
    }
}

extern "C" void ui_attr(const char* id, const char* name, const char* value) {
    Rml::Element* el = byId(id);
    if (!el) return;
    if (!value) return el->RemoveAttribute(name);
    if (!el->HasAttribute(name) || el->GetAttribute<Rml::String>(name, "") != value) el->SetAttribute(name, Rml::String(value));
}

extern "C" void ui_class(const char* id, const char* cls, bool on) {
    if (Rml::Element* el = byId(id))
        if (el->IsClassSet(cls) != on) el->SetClass(cls, on);
}

// A form control's value, unless the player is typing in it.
extern "C" void ui_value(const char* id, const char* value) {
    Rml::Element* el = byId(id);
    if (!el || el == context->GetFocusElement()) return;
    auto* fc = rmlui_dynamic_cast<Rml::ElementFormControl*>(el);
    if (fc && fc->GetValue() != value) fc->SetValue(value);
}

extern "C" void ui_clipboard(const char* text) { sys->SetClipboardText(text); }

extern "C" const char* win_gpu_name() { return gpu_name; }

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
