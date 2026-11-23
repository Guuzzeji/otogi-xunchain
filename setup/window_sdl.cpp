// The launcher's window on Linux: SDL3 + GL ES 3, drawn by RmlUi (its SDL
// platform and GL3 renderer in GL ES mode, Backends/), the twin of
// setup/window.cpp (Win32 + D3D11) with the same C functions for setup/main.zig.
#include "RmlUi_Platform_SDL.h"
#include "RmlUi_Renderer_GL3.h"
#include "ui_common.h"
#include <GLES3/gl3.h>
#include <SDL3/SDL.h>
#include <stdlib.h>

static SDL_Window* window;
static int win_w, win_h;
static char gpu_name[128];
static Rml::Context* context;
static Rml::ElementDocument* doc;

// OTOGI_UI_LOG=<file>: RmlUi's warnings and errors there (bad markup or styles).
class System : public SystemInterface_SDL {
public:
    using SystemInterface_SDL::SystemInterface_SDL;
    FILE* log = nullptr;
    bool LogMessage(Rml::Log::Type type, const Rml::String& message) override {
        if (log && type <= Rml::Log::LT_WARNING) fprintf(log, "%s\n", message.c_str()), fflush(log);
        return true;
    }
};
static System* sys;

// ── Images: the embedded PNGs, decoded in Zig (setup/png.zig) ───────────────
extern "C" unsigned char* ui_png(const char* path, int* w, int* h); // premultiplied RGBA; free()
class Renderer : public RenderInterface_GL3 {
public:
    Rml::TextureHandle LoadTexture(Rml::Vector2i& dims, const Rml::String& source) override {
        const char* name = source.c_str();
        while (*name == '/') name++;
        unsigned char* px = ui_png(name, &dims.x, &dims.y);
        if (!px) return 0;
        Rml::TextureHandle t = GenerateTexture({px, (size_t)dims.x * dims.y * 4}, dims);
        free(px);
        return t;
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
        if (cmd == "win:min") return (void)SDL_MinimizeWindow(window);
        if (cmd == "win:max") return (void)(SDL_GetWindowFlags(window) & SDL_WINDOW_MAXIMIZED ? SDL_RestoreWindow(window) : SDL_MaximizeWindow(window));
        if (cmd == "win:close") {
            SDL_Event q = {SDL_EVENT_QUIT};
            return (void)SDL_PushEvent(&q);
        }
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
static SDL_HitTestResult hitTest(SDL_Window* w, const SDL_Point* p, void*) {
    const int edge = 6;
    int ww, wh;
    SDL_GetWindowSize(w, &ww, &wh);
    if (!(SDL_GetWindowFlags(w) & SDL_WINDOW_MAXIMIZED)) {
        bool l = p->x < edge, r = p->x >= ww - edge, t = p->y < edge, b = p->y >= wh - edge;
        if (t && l) return SDL_HITTEST_RESIZE_TOPLEFT;
        if (t && r) return SDL_HITTEST_RESIZE_TOPRIGHT;
        if (b && l) return SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if (b && r) return SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (l) return SDL_HITTEST_RESIZE_LEFT;
        if (r) return SDL_HITTEST_RESIZE_RIGHT;
        if (t) return SDL_HITTEST_RESIZE_TOP;
        if (b) return SDL_HITTEST_RESIZE_BOTTOM;
    }
    // In #titlebar but not on anything clickable: drag the window.
    const float d = SDL_GetWindowPixelDensity(w);
    for (Rml::Element* el = context ? context->GetElementAtPoint({p->x * d, p->y * d}) : nullptr; el; el = el->GetParentNode()) {
        if (el->HasAttribute("onclick")) return SDL_HITTEST_NORMAL;
        if (el->GetId() == "titlebar") return SDL_HITTEST_DRAGGABLE;
    }
    return SDL_HITTEST_NORMAL;
}

extern "C" bool ui_init(const char* title, int w, int h) {
    SDL_SetHint(SDL_HINT_VIDEO_FORCE_EGL, "1"); // GL ES through EGL, as the game (src/gl_hle.zig)
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD)) return false;
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
    float scale = SDL_GetDisplayContentScale(SDL_GetPrimaryDisplay());
    SDL_Rect work;
    if (scale <= 0) scale = 1;
    if (SDL_GetDisplayUsableBounds(SDL_GetPrimaryDisplay(), &work)) w = Rml::Math::Min((int)(w * scale), work.w), h = Rml::Math::Min((int)(h * scale), work.h);
    window = SDL_CreateWindow(title, w, h, SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_BORDERLESS | SDL_WINDOW_HIGH_PIXEL_DENSITY);
    if (!window || !SDL_GL_CreateContext(window)) return false;
    SDL_GL_SetSwapInterval(1);
    SDL_SetWindowMinimumSize(window, (int)(880 * scale), (int)(600 * scale));
    SDL_SetWindowHitTest(window, hitTest, nullptr);
    snprintf(gpu_name, sizeof gpu_name, "%s", (const char*)glGetString(GL_RENDERER));

    sys = new System(window);
    if (const char* p = getenv("OTOGI_UI_LOG")) sys->log = fopen(p, "w");
    renderer = new Renderer(); // compiles its shaders: the GL context must be current
    if (!*renderer) return false;
    Rml::SetSystemInterface(sys);
    Rml::SetFileInterface(&files);
    Rml::SetRenderInterface(renderer);
    Rml::Initialise();
    Rml::Factory::RegisterEventListenerInstancer(&listeners);
    SDL_GetWindowSizeInPixels(window, &win_w, &win_h);
    context = Rml::CreateContext("main", {win_w, win_h});
    if (!context) return false;
    context->SetDensityIndependentPixelRatio(SDL_GetWindowDisplayScale(window));
    renderer->SetViewport(win_w, win_h);
    return true;
}

extern "C" bool ui_load(const char* path) {
    doc = context->LoadDocument(path);
    if (doc) doc->Show();
    return doc != nullptr;
}

// ── Controller: d-pad/stick move focus, A clicks, B is "back", LB/RB switch pages
static SDL_Gamepad* gamepad;
static void pad() {
    enum { UP = 1, DOWN = 2, LEFT = 4, RIGHT = 8, A = 16, B = 32, LB = 64, RB = 128 };
    static int held;
    static Uint64 next_repeat;
    if (!gamepad) return;
    auto btn = [](SDL_GamepadButton x) { return SDL_GetGamepadButton(gamepad, x); };
    const Sint16 dead = 16000, lx = SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_LEFTX), ly = SDL_GetGamepadAxis(gamepad, SDL_GAMEPAD_AXIS_LEFTY);
    int b = (btn(SDL_GAMEPAD_BUTTON_DPAD_UP) || ly < -dead ? UP : 0) | (btn(SDL_GAMEPAD_BUTTON_DPAD_DOWN) || ly > dead ? DOWN : 0) |
            (btn(SDL_GAMEPAD_BUTTON_DPAD_LEFT) || lx < -dead ? LEFT : 0) | (btn(SDL_GAMEPAD_BUTTON_DPAD_RIGHT) || lx > dead ? RIGHT : 0) |
            (btn(SDL_GAMEPAD_BUTTON_SOUTH) ? A : 0) | (btn(SDL_GAMEPAD_BUTTON_EAST) ? B : 0) |
            (btn(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER) ? LB : 0) | (btn(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER) ? RB : 0);
    // Only while the launcher is the active window: not while playing the game.
    if (!(SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS)) return (void)(held = b);
    int down = b & ~held;
    const int dirs = UP | DOWN | LEFT | RIGHT;
    Uint64 now = SDL_GetTicks();
    if (down & dirs) next_repeat = now + 400;
    else if ((b & dirs) && now >= next_repeat) down |= b & dirs, next_repeat = now + 120;
    held = b;
    if (!down) return;
    Rml::Element* f = context->GetFocusElement();
    if ((down & dirs) && (!f || f == doc || f == context->GetRootElement())) {
        context->ProcessKeyDown(Rml::Input::KI_TAB, 0); // first press: focus the first control
        return;
    }
    if (down & UP) context->ProcessKeyDown(Rml::Input::KI_UP, 0);
    if (down & DOWN) context->ProcessKeyDown(Rml::Input::KI_DOWN, 0);
    if (down & LEFT) context->ProcessKeyDown(Rml::Input::KI_LEFT, 0);
    if (down & RIGHT) context->ProcessKeyDown(Rml::Input::KI_RIGHT, 0);
    if ((down & A) && f) f->Click();
    if (down & B) ui_event("back", "");
    if (down & LB) ui_event("page-step", "-1");
    if (down & RB) ui_event("page-step", "1");
}

// One frame: events, controller, layout, draw. False once the window closes.
extern "C" bool ui_frame() {
    SDL_Event e;
    while (SDL_PollEvent(&e)) {
        switch (e.type) {
        case SDL_EVENT_QUIT:
            return false;
        case SDL_EVENT_GAMEPAD_ADDED:
            if (!gamepad) gamepad = SDL_OpenGamepad(e.gdevice.which);
            continue;
        case SDL_EVENT_GAMEPAD_REMOVED:
            if (gamepad && SDL_GetGamepadID(gamepad) == e.gdevice.which) SDL_CloseGamepad(gamepad), gamepad = nullptr;
            continue;
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            win_w = e.window.data1, win_h = e.window.data2;
            renderer->SetViewport(win_w, win_h);
            break;
        case SDL_EVENT_KEY_DOWN: // Enter or Space on a focused button clicks it
            if (e.key.key == SDLK_RETURN || e.key.key == SDLK_SPACE) {
                Rml::Element* f = context->GetFocusElement();
                if (f && f->HasAttribute("onclick") && f->GetTagName() != "input") {
                    f->Click();
                    continue;
                }
            }
            break;
        }
        RmlSDL::InputEventHandler(context, window, e);
    }
    pad();
    context->Update();
    glViewport(0, 0, win_w, win_h);
    glClearColor(0, 0, 0, 1);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);
    renderer->BeginFrame();
    context->Render();
    renderer->EndFrame();
    SDL_GL_SwapWindow(window);
    // At most 60 frames a second, 10 in the background: V-sync does not always
    // hold, and a spinning launcher takes every core. (On llvmpipe, Mesa's CPU
    // renderer, a frame alone costs ~170 ms of CPU at 1280x860: ~18 a second.)
    static Uint64 last;
    const Uint64 frame_ns = SDL_GetWindowFlags(window) & SDL_WINDOW_INPUT_FOCUS ? 16666667 : 100000000;
    const Uint64 now = SDL_GetTicksNS();
    if (now - last < frame_ns) SDL_DelayNS(frame_ns - (now - last));
    last = SDL_GetTicksNS();
    return true;
}

static Rml::Element* byId(const char* id) { return doc ? doc->GetElementById(id) : nullptr; }

extern "C" void ui_clipboard(const char* text) { sys->SetClipboardText(text); }

extern "C" const char* win_gpu_name() { return gpu_name; }

// The desktop's file dialogs (xdg portal or zenity): SDL answers on any thread,
// so wait here, the way the Windows dialogs block.
struct Pick {
    char* buf;
    int len;
    SDL_AtomicInt done;
    bool ok;
};
static void picked(void* u, const char* const* files, int) {
    Pick* p = (Pick*)u;
    if (!files) fprintf(stderr, "file dialog: %s\n", SDL_GetError()); // none on this desktop: type the path
    p->ok = files && files[0] && snprintf(p->buf, p->len, "%s", files[0]) < p->len;
    SDL_SetAtomicInt(&p->done, 1);
}
static bool waitPick(Pick& p) {
    while (!SDL_GetAtomicInt(&p.done)) SDL_PumpEvents(), SDL_Delay(10);
    return p.ok;
}

// A disc image, or the default.xbe of a folder of the disc's files.
extern "C" bool win_pick_iso(char* buf, int len) {
    static const SDL_DialogFileFilter filters[] = {{"Xbox disc image or default.xbe", "iso;xbe"}, {"All files", "*"}};
    Pick p = {buf, len};
    SDL_ShowOpenFileDialog(picked, &p, window, filters, 2, nullptr, false);
    return waitPick(p);
}

extern "C" bool win_pick_folder(char* buf, int len) {
    Pick p = {buf, len};
    SDL_ShowOpenFolderDialog(picked, &p, window, nullptr, false);
    return waitPick(p);
}

// Open a file, folder or web page in the desktop's app for it (xdg-open).
extern "C" void win_open(const char* path) { SDL_OpenURL(path); }

// The primary display's modes, as width, height pairs; how many.
extern "C" int win_modes(int* wh, int max) {
    int n = 0, count = 0;
    SDL_DisplayMode** modes = SDL_GetFullscreenDisplayModes(SDL_GetPrimaryDisplay(), &count);
    for (int i = 0; modes && i < count && n < max; i++) wh[2 * n] = modes[i]->w, wh[2 * n + 1] = modes[i]->h, n++;
    SDL_free(modes);
    return n;
}
