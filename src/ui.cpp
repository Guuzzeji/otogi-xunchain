// The game's menus in RmlUi: the settings page and frame rate counter
// (context 0, src/settings_menu.zig) and the F1 debug menu (context 1,
// src/debug_menu.zig). SDL3's events in (RmlUi's SDL platform backend), its
// GL3 renderer in GL ES 3 mode out, into ANGLE's context over the window after
// the blit. Render thread only. The settings page's sizes follow the window's
// height, the debug menu's stay small: one context each, each with its dp ratio.
#include "RmlUi_Platform_SDL.h"
#include "RmlUi_Renderer_GL3.h"
#include "../setup/ui_common.h"
#include <GLES3/gl3.h>

// RmlUi's warnings and errors (bad markup or styles) to otogi.log.
class System : public SystemInterface_SDL {
public:
    using SystemInterface_SDL::SystemInterface_SDL;
    bool LogMessage(Rml::Log::Type type, const Rml::String& message) override {
        if (type <= Rml::Log::LT_WARNING) fprintf(stderr, "[UI] %s\n", message.c_str());
        return true;
    }
};

static SDL_Window* window;
static RenderInterface_GL3* renderer;
static Rml::Context* ctx[2];
static Rml::ElementDocument* doc[2];

static Rml::Element* byId(const char* id) {
    for (Rml::ElementDocument* d : doc)
        if (Rml::Element* el = d ? d->GetElementById(id) : nullptr) return el;
    return nullptr;
}

// ── on* attributes: onclick="close" calls ui_event("close", value) ─────────
// On the settings page a text field counts once Enter is pressed, not on
// every key (a half-typed resolution would switch the screen mode).
class Listener : public Rml::EventListener {
public:
    Rml::String cmd;
    Listener(const Rml::String& c) : cmd(c) {}
    void ProcessEvent(Rml::Event& e) override {
        Rml::Element* el = e.GetCurrentElement();
        if (el->GetOwnerDocument() == doc[0] && !e.GetParameter<bool>("linebreak", true)) return;
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

extern "C" bool ui_init(SDL_Window* w) {
    window = w;
    renderer = new RenderInterface_GL3(); // compiles its shaders: the GL context must be current
    if (!*renderer) return false;
    Rml::SetSystemInterface(new System(w));
    Rml::SetFileInterface(&files);
    Rml::SetRenderInterface(renderer);
    if (!Rml::Initialise()) return false;
    Rml::Factory::RegisterEventListenerInstancer(&listeners);
    ctx[0] = Rml::CreateContext("settings", {1, 1});
    ctx[1] = Rml::CreateContext("debug", {1, 1});
    return ctx[0] && ctx[1];
}

extern "C" bool ui_load(int i, const char* path) {
    doc[i] = ctx[i]->LoadDocument(path);
    return doc[i] != nullptr;
}

// Shown or hidden. Hiding takes the focus off its controls, which ends text input.
extern "C" void ui_show(int i, bool on) {
    if (!doc[i] || doc[i]->IsVisible() == on) return;
    if (on) return doc[i]->Show();
    doc[i]->Focus();
    doc[i]->Hide();
}

// Nothing focused yet: the first move focuses the first control instead.
static bool focusFirst(int i) {
    Rml::Element* f = ctx[i]->GetFocusElement();
    if (f && f != doc[i] && f != ctx[i]->GetRootElement()) return false;
    ctx[i]->ProcessKeyDown(Rml::Input::KI_TAB, 0);
    return true;
}

// An SDL event for context i (src/debug_menu.zig picks which go where).
extern "C" void ui_input(int i, const SDL_Event* e) {
    if (e->type == SDL_EVENT_KEY_DOWN && (e->key.key == SDLK_UP || e->key.key == SDLK_DOWN || e->key.key == SDLK_LEFT || e->key.key == SDLK_RIGHT) && focusFirst(i)) return;
    SDL_Event copy = *e;
    RmlSDL::InputEventHandler(ctx[i], window, copy);
}

// A text field has the focus: keys are typing.
extern "C" bool ui_typing(int i) {
    Rml::Element* f = ctx[i] ? ctx[i]->GetFocusElement() : nullptr;
    return f && f->GetTagName() == "input";
}

// Focus off any control (Esc out of a text field).
extern "C" void ui_blur(int i) {
    if (doc[i]) doc[i]->Focus();
}

// ── Controller: bits up, down, left, right (d-pad or stick), A, B = 1, 2, 4,
// 8, 16, 32. Moves repeat while held; the first one focuses the first control.
// A clicks. Returns the buttons newly down (B closes, in Zig).
extern "C" int ui_pad(int i, int b) {
    static int held;
    static Uint64 next_repeat;
    int down = b & ~held;
    const int dirs = 15;
    Uint64 now = SDL_GetTicks();
    if (down & dirs) next_repeat = now + 400;
    else if ((b & dirs) && now >= next_repeat) down |= b & dirs, next_repeat = now + 120;
    held = b;
    if (!down || !doc[i]) return down;
    if ((down & dirs) && focusFirst(i)) return down;
    Rml::Context* c = ctx[i];
    Rml::Element* f = c->GetFocusElement();
    if (down & 1) c->ProcessKeyDown(Rml::Input::KI_UP, 0);
    if (down & 2) c->ProcessKeyDown(Rml::Input::KI_DOWN, 0);
    if (down & 4) c->ProcessKeyDown(Rml::Input::KI_LEFT, 0);
    if (down & 8) c->ProcessKeyDown(Rml::Input::KI_RIGHT, 0);
    if ((down & 16) && f) f->Click();
    return down;
}

// Focus the first control, with the focus ring (the page just opened: lay it
// out first, its controls were hidden).
extern "C" void ui_focus_first(int i) {
    if (!doc[i]) return;
    ctx[i]->Update();
    doc[i]->Focus();
    focusFirst(i);
}

// A bar graph in element `id`: n bars (made the first time), bar k is
// v[(at + k) % n] / max of its height.
extern "C" void ui_bars(const char* id, const float* v, int n, int at, float max) {
    Rml::Element* el = byId(id);
    if (!el) return;
    while (el->GetNumChildren() < n) {
        Rml::Element* bar = el->AppendChild(el->GetOwnerDocument()->CreateElement("div"));
        bar->SetProperty(Rml::PropertyId::Width, Rml::Property(100.f / n, Rml::Unit::PERCENT));
        bar->SetProperty(Rml::PropertyId::Left, Rml::Property(100.f * (el->GetNumChildren() - 1) / n, Rml::Unit::PERCENT));
    }
    for (int k = 0; k < n; k++)
        el->GetChild(k)->SetProperty(Rml::PropertyId::Height, Rml::Property(Rml::Math::Clamp(v[(at + k) % n] / max, 0.f, 1.f) * 100.f, Rml::Unit::PERCENT));
}

// One frame of the contexts whose document is shown, over the window (w x h
// pixels; frame buffer 0 bound). ratio: each context's size of a dp. `corner`
// (0 top right, 1 top left, 2 bottom right, 3 bottom left; -1 none): only the
// metrics overlay is shown, so context 0 is just that corner of the window,
// box_w x box_h dp: the renderer's layers (cleared, resolved and blended over
// the window each frame) stay that small.
extern "C" void ui_frame(int w, int h, float ratio0, float ratio1, int corner, float box_w, float box_h) {
    const float ratio[2] = {ratio0, ratio1};
    int vw = w, vh = h, x = 0, y = 0;
    if (corner >= 0) {
        vw = Rml::Math::Min(w, int(box_w * ratio0)), vh = Rml::Math::Min(h, int(box_h * ratio0));
        x = corner & 1 ? 0 : w - vw;
        y = corner & 2 ? 0 : h - vh; // GL's y grows upward
    }
    bool any = false;
    for (int i = 0; i < 2; i++) {
        if (!doc[i] || !doc[i]->IsVisible()) continue;
        if (ctx[i]->GetDimensions() != Rml::Vector2i(vw, vh)) ctx[i]->SetDimensions({vw, vh});
        if (ctx[i]->GetDensityIndependentPixelRatio() != ratio[i]) ctx[i]->SetDensityIndependentPixelRatio(ratio[i]);
        ctx[i]->Update();
        any = true;
    }
    if (!any || w < 1 || h < 1) return;
    // The renderer puts back blend, depth, stencil, scissor and viewport; the
    // rest the game expects to find as it left it is put back here.
    GLint prog, vao, buf, active, tex, sampler, unpack;
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &buf);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
    glGetIntegerv(GL_SAMPLER_BINDING, &sampler);
    glGetIntegerv(GL_UNPACK_ALIGNMENT, &unpack);
    glBindSampler(0, 0); // the game's would override the UI's filtering
    glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
    renderer->SetViewport(vw, vh, x, y);
    renderer->BeginFrame();
    for (int i = 1; i >= 0; i--) // the settings page over the debug menu
        if (doc[i] && doc[i]->IsVisible()) ctx[i]->Render();
    renderer->EndFrame();
    glUseProgram(prog);
    glBindVertexArray(vao);
    glBindBuffer(GL_ARRAY_BUFFER, buf);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glBindSampler(0, sampler);
    glActiveTexture(active);
    glPixelStorei(GL_UNPACK_ALIGNMENT, unpack);
}
