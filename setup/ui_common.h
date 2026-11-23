// What both RmlUi hosts share: the launcher's (setup/window.cpp, Win32 + D3D11)
// and the game's menus (src/ui.cpp, SDL3 + GL ES 3). Zig owns the state: it
// sets markup by element id (ui_set, ui_attr, ...) and serves the documents,
// stylesheets and fonts from the exe (ui_file). The host defines byId first.
#include <RmlUi/Core.h>
#include <stdio.h>
#include <string.h>
#include <unordered_map>

extern "C" void ui_event(const char* cmd, const char* value);           // Zig: an on* attribute's command
extern "C" const unsigned char* ui_file(const char* path, size_t* len); // Zig: a file inside the exe

static Rml::Element* byId(const char* id);

// ── Files: embedded first, else the disk (Windows fonts) ──────────────────
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

// A font from the exe (ui_file) or from disk.
extern "C" bool ui_font(const char* path, bool fallback) { return Rml::LoadFontFace(path, fallback); }

// ── Zig sets the page by element id. Unchanged values cost nothing. ─────────
static std::unordered_map<Rml::String, std::pair<Rml::Element*, Rml::String>> last;

// Inner markup. Elements with class "follow" (a log) stay scrolled to the end
// while they are at it.
extern "C" void ui_set(const char* id, const char* rml) {
    Rml::Element* el = byId(id);
    if (!el) return;
    auto it = last.find(id);
    // The element too: markup set on a parent makes new ones, which start empty.
    if (it != last.end() && it->second.first == el && it->second.second == rml) return;
    last[id] = {el, rml};
    const bool follow = el->IsClassSet("follow") && el->GetScrollTop() + el->GetClientHeight() >= el->GetScrollHeight() - 4;
    el->SetInnerRML(rml);
    if (follow) {
        el->GetOwnerDocument()->UpdateDocument();
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
    if (!el || el == el->GetContext()->GetFocusElement()) return;
    auto* fc = rmlui_dynamic_cast<Rml::ElementFormControl*>(el);
    if (fc && fc->GetValue() != value) fc->SetValue(value);
}
