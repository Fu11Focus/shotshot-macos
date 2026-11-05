// Резидентний демон ShotShot (C++, БЕЗ AppKit).
//
// Єдина задача: ловити ⌘⇧7 через CGEventTap на «голому» CFRunLoop і запускати
// редактор на вимогу. AppKit тут не лінкується взагалі — тому idle ~2 МБ.
//
// Ціна (як і в ClipHistory): демону потрібен Accessibility для CGEventTap.
// Редактору (окремий процес) потрібен Screen Recording для ScreenCaptureKit.
// Постійної іконки в менюбарі немає — демон невидимий.
//
// Лінкує: ApplicationServices (CoreGraphics event tap), CoreFoundation.

#include <ApplicationServices/ApplicationServices.h>
#include <spawn.h>
#include <unistd.h>
#include <libgen.h>
#include <string>
#include <cstdio>
#include <cstring>

extern char **environ;

static std::string gEditorPath;
static CFMachPortRef gTap = NULL;
static const CGKeyCode kKey7 = 0x1A; // kVK_ANSI_7

static void launchEditor() {
    pid_t pid;
    char *argv[] = { (char *)gEditorPath.c_str(), NULL };
    posix_spawn(&pid, gEditorPath.c_str(), NULL, NULL, argv, environ);
}

static CGEventRef hotkeyCallback(CGEventTapProxy, CGEventType type,
                                 CGEventRef event, void *) {
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (gTap) CGEventTapEnable(gTap, true);
        return event;
    }
    if (type == kCGEventKeyDown) {
        CGKeyCode code = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        CGEventFlags f = CGEventGetFlags(event);
        bool cmd   = f & kCGEventFlagMaskCommand;
        bool shift = f & kCGEventFlagMaskShift;
        bool alt   = f & kCGEventFlagMaskAlternate;
        bool ctrl  = f & kCGEventFlagMaskControl;
        if (code == kKey7 && cmd && shift && !alt && !ctrl) {
            launchEditor();
            return NULL; // поглинаємо ⌘⇧7
        }
    }
    return event;
}

static bool installHotkey() {
    const void *keys[] = { kAXTrustedCheckOptionPrompt };
    const void *vals[] = { kCFBooleanTrue };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    bool trusted = AXIsProcessTrustedWithOptions(opts);
    CFRelease(opts);

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
    gTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                            kCGEventTapOptionDefault, mask, hotkeyCallback, NULL);
    if (!gTap) {
        fprintf(stderr, "CGEventTapCreate failed (trusted=%d).\n"
                        "Додай демон у System Settings → Privacy & Security → Accessibility.\n",
                trusted);
        return false;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(NULL, gTap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, kCFRunLoopCommonModes);
    CGEventTapEnable(gTap, true);
    CFRelease(src);
    return true;
}

static void writeStatus(const char *msg) {
    const char *home = getenv("HOME");
    std::string path = std::string(home ? home : "/tmp") + "/.shotd-status";
    FILE *f = fopen(path.c_str(), "w");
    if (f) { fprintf(f, "%s\n", msg); fclose(f); }
}

int main(int argc, char **argv) {
    char buf[4096];
    strncpy(buf, argv[0], sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    gEditorPath = std::string(dirname(buf)) + "/ShotShotCppEditor";

    bool ok = installHotkey();
    char status[256];
    snprintf(status, sizeof(status), "pid=%d tap=%s editor=%s",
             getpid(), ok ? "OK" : "FAILED(no-accessibility)", gEditorPath.c_str());
    writeStatus(status);
    fprintf(stderr, "shotd up, %s\n", status);
    CFRunLoopRun();
    return 0;
}
