// TouchRecordKit Touches — OFX filter that draws touch / Apple Pencil / keyboard overlays
// from a TouchRecordKit .touches.json sidecar. Raw OFX C API, CPU rendering via CoreGraphics.
#import <Foundation/Foundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <initializer_list>
#include <cstdarg>
#include <ctime>
#include <mutex>
#include <stdexcept>
#include "ofxCore.h"
#include "ofxImageEffect.h"
#include "ofxParam.h"
#include "ofxProperty.h"
#include "Overlay.h"

using namespace trk;

static OfxHost* gHost = nullptr;
static const OfxPropertySuiteV1* P = nullptr;
static const OfxImageEffectSuiteV1* E = nullptr;
static const OfxParameterSuiteV1* PS = nullptr;

// MARK: Param helpers

static OfxPropertySetHandle defParam(OfxParamSetHandle ps, const char* type, const char* name, const char* label,
                                     const char* parent, const char* hint = nullptr) {
    OfxPropertySetHandle p = nullptr;
    PS->paramDefine(ps, type, name, &p);
    P->propSetString(p, kOfxPropLabel, 0, label);
    if (parent) P->propSetString(p, kOfxParamPropParent, 0, parent);
    if (hint) P->propSetString(p, kOfxParamPropHint, 0, hint);
    return p;
}
static void defGroup(OfxParamSetHandle ps, const char* name, const char* label, bool open) {
    auto p = defParam(ps, kOfxParamTypeGroup, name, label, nullptr);
    P->propSetInt(p, kOfxParamPropGroupOpen, 0, open ? 1 : 0);
}
static void defBool(OfxParamSetHandle ps, const char* name, const char* label, const char* parent, bool def,
                    const char* hint = nullptr) {
    auto p = defParam(ps, kOfxParamTypeBoolean, name, label, parent, hint);
    P->propSetInt(p, kOfxParamPropDefault, 0, def ? 1 : 0);
}
static void defDouble(OfxParamSetHandle ps, const char* name, const char* label, const char* parent, double def,
                      double dmin, double dmax, const char* hint = nullptr, double hmin = -1e9, double hmax = 1e9) {
    auto p = defParam(ps, kOfxParamTypeDouble, name, label, parent, hint);
    P->propSetDouble(p, kOfxParamPropDefault, 0, def);
    P->propSetDouble(p, kOfxParamPropMin, 0, hmin);
    P->propSetDouble(p, kOfxParamPropMax, 0, hmax);
    P->propSetDouble(p, kOfxParamPropDisplayMin, 0, dmin);
    P->propSetDouble(p, kOfxParamPropDisplayMax, 0, dmax);
}
static void defInt(OfxParamSetHandle ps, const char* name, const char* label, const char* parent, int def,
                   int dmin, int dmax, const char* hint = nullptr) {
    auto p = defParam(ps, kOfxParamTypeInteger, name, label, parent, hint);
    P->propSetInt(p, kOfxParamPropDefault, 0, def);
    P->propSetInt(p, kOfxParamPropDisplayMin, 0, dmin);
    P->propSetInt(p, kOfxParamPropDisplayMax, 0, dmax);
}
static void defChoice(OfxParamSetHandle ps, const char* name, const char* label, const char* parent, int def,
                      std::initializer_list<const char*> options, const char* hint = nullptr) {
    auto p = defParam(ps, kOfxParamTypeChoice, name, label, parent, hint);
    int i = 0;
    for (auto o : options) P->propSetString(p, kOfxParamPropChoiceOption, i++, o);
    P->propSetInt(p, kOfxParamPropDefault, 0, def);
}
static void defColor(OfxParamSetHandle ps, const char* name, const char* label, const char* parent, RGBA c) {
    auto p = defParam(ps, kOfxParamTypeRGBA, name, label, parent);
    double v[4] = {c.r, c.g, c.b, c.a};
    P->propSetDoubleN(p, kOfxParamPropDefault, 4, v);
}
static void defString(OfxParamSetHandle ps, const char* name, const char* label, const char* parent, bool filePath,
                      const char* hint = nullptr) {
    auto p = defParam(ps, kOfxParamTypeString, name, label, parent, hint);
    P->propSetString(p, kOfxParamPropDefault, 0, "");
    P->propSetInt(p, kOfxParamPropAnimates, 0, 0);
    if (filePath) {
        P->propSetString(p, kOfxParamPropStringMode, 0, kOfxParamStringIsFilePath);
        P->propSetInt(p, kOfxParamPropStringFilePathExists, 0, 1);
    } else {
        P->propSetString(p, kOfxParamPropStringMode, 0, kOfxParamStringIsSingleLine);
    }
}

struct Params {
    OfxParamSetHandle ps; OfxTime t;
    OfxParamHandle h(const char* n) const { OfxParamHandle x = nullptr; PS->paramGetHandle(ps, n, &x, nullptr); return x; }
    double d(const char* n) const { double v = 0; if (auto x = h(n)) PS->paramGetValueAtTime(x, t, &v); return v; }
    int i(const char* n) const { int v = 0; if (auto x = h(n)) PS->paramGetValueAtTime(x, t, &v); return v; }
    bool b(const char* n) const { return i(n) != 0; }
    RGBA c(const char* n) const {
        RGBA v{1, 1, 1, 1};
        if (auto x = h(n)) PS->paramGetValueAtTime(x, t, &v.r, &v.g, &v.b, &v.a);
        return v;
    }
    std::string s(const char* n) const { char* v = nullptr; if (auto x = h(n)) PS->paramGetValue(x, &v); return v ? v : ""; }
};

/// Appends to ~/Library/Logs/TouchRecordKit.log. Only used for failures.
static void logLine(const char* fmt, ...) {
    static std::mutex m;
    std::lock_guard<std::mutex> lock(m);
    NSString* path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/TouchRecordKit.log"];
    FILE* f = fopen(path.fileSystemRepresentation, "a");
    if (!f) return;
    time_t now = time(nullptr);
    char ts[32]; strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", localtime(&now));
    fprintf(f, "%s  ", ts);
    va_list ap; va_start(ap, fmt); vfprintf(f, fmt, ap); va_end(ap);
    fputc('\n', f);
    fclose(f);
}

// MARK: Source media (Resolve extension)

// Resolve-specific properties (not in the OFX headers): the clip's media file and the frame within it.
static const char* kResolveSrcFilePath = "OfxImageEffectPropSrcFilePath";
static const char* kResolveSrcFrame = "OfxImageEffectPropSrcFrame";

static bool getStr(OfxPropertySetHandle h, const char* n, std::string& out) {
    char* v = nullptr;
    if (h && P->propGetString(h, n, 0, &v) == kOfxStatOK && v && *v) { out = v; return true; }
    return false;
}
static bool getNum(OfxPropertySetHandle h, const char* n, double& out) {
    if (!h) return false;
    double d = 0; int i = 0;
    if (P->propGetDouble(h, n, 0, &d) == kOfxStatOK) { out = d; return true; }
    if (P->propGetInt(h, n, 0, &i) == kOfxStatOK) { out = i; return true; }
    return false;
}

struct SourceInfo { std::string mediaPath, sidecar; bool hasFrame = false; double frame = 0; };

static SourceInfo sourceInfo(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
    OfxPropertySetHandle effProps = nullptr, clipProps = nullptr;
    E->getPropertySet(effect, &effProps);
    OfxImageClipHandle clip = nullptr;
    if (E->clipGetHandle(effect, kOfxImageEffectSimpleSourceClipName, &clip, nullptr) == kOfxStatOK)
        E->clipGetPropertySet(clip, &clipProps);
    const std::pair<const char*, OfxPropertySetHandle> sets[] = {{"args", inArgs}, {"effect", effProps}, {"clip", clipProps}};

    SourceInfo info;
    // Resolve puts the path on the effect and the frame in the render args; check all three to be safe.
    for (auto& s : sets) if (getStr(s.second, kResolveSrcFilePath, info.mediaPath)) break;
    for (auto& s : sets) if (getNum(s.second, kResolveSrcFrame, info.frame)) { info.hasFrame = true; break; }

    if (!info.mediaPath.empty()) {
        @autoreleasepool {
            NSString* media = [NSString stringWithUTF8String:info.mediaPath.c_str()];
            info.sidecar = [[media stringByDeletingPathExtension] stringByAppendingString:@".touches.json"].UTF8String;
        }
    }
    return info;
}

/// Manual file wins; otherwise the sidecar next to the clip's media.
static std::string touchFilePath(const Params& p, const SourceInfo& src, bool* automatic) {
    std::string manual = p.s("file");
    if (automatic) *automatic = manual.empty();
    return manual.empty() ? src.sidecar : manual;
}

// MARK: Actions

static OfxStatus onLoad() {
    if (!gHost) return kOfxStatErrMissingHostFeature;
    P = (const OfxPropertySuiteV1*)gHost->fetchSuite(gHost->host, kOfxPropertySuite, 1);
    E = (const OfxImageEffectSuiteV1*)gHost->fetchSuite(gHost->host, kOfxImageEffectSuite, 1);
    PS = (const OfxParameterSuiteV1*)gHost->fetchSuite(gHost->host, kOfxParameterSuite, 1);
    return (P && E && PS) ? kOfxStatOK : kOfxStatErrMissingHostFeature;
}

static OfxStatus describe(OfxImageEffectHandle effect) {
    OfxPropertySetHandle props;
    E->getPropertySet(effect, &props);
    P->propSetString(props, kOfxPropLabel, 0, "TouchRecordKit Touches");
    P->propSetString(props, kOfxImageEffectPluginPropGrouping, 0, "TouchRecordKit");
    P->propSetString(props, kOfxPropPluginDescription, 0,
                     "Draws touches, Apple Pencil strokes and keyboard presses recorded by TouchRecordKit (.touches.json).");
    P->propSetString(props, kOfxImageEffectPropSupportedContexts, 0, kOfxImageEffectContextFilter);
    P->propSetString(props, kOfxImageEffectPropSupportedContexts, 1, kOfxImageEffectContextGeneral);
    P->propSetString(props, kOfxImageEffectPropSupportedPixelDepths, 0, kOfxBitDepthFloat);
    P->propSetString(props, kOfxImageEffectPropSupportedPixelDepths, 1, kOfxBitDepthShort);
    P->propSetString(props, kOfxImageEffectPropSupportedPixelDepths, 2, kOfxBitDepthByte);
    P->propSetString(props, kOfxImageEffectPluginRenderThreadSafety, 0, kOfxImageEffectRenderFullySafe);
    P->propSetInt(props, kOfxImageEffectPluginPropHostFrameThreading, 0, 0);
    P->propSetInt(props, kOfxImageEffectPropSupportsTiles, 0, 1);
    P->propSetInt(props, kOfxImageEffectPropSupportsMultiResolution, 0, 1);
    P->propSetInt(props, kOfxImageEffectPropTemporalClipAccess, 0, 0);
    return kOfxStatOK;
}

static OfxStatus describeInContext(OfxImageEffectHandle effect) {
    OfxPropertySetHandle cp;
    E->clipDefine(effect, kOfxImageEffectSimpleSourceClipName, &cp);
    P->propSetString(cp, kOfxImageEffectPropSupportedComponents, 0, kOfxImageComponentRGBA);
    E->clipDefine(effect, kOfxImageEffectOutputClipName, &cp);
    P->propSetString(cp, kOfxImageEffectPropSupportedComponents, 0, kOfxImageComponentRGBA);

    OfxParamSetHandle ps;
    E->getParamSet(effect, &ps);

    defGroup(ps, "grpSource", "Source", true);
    defString(ps, "file", "Touch Data Override (.json)", "grpSource", true,
              "Leave empty to use the .touches.json next to the clip's media automatically. Set a file to override.");
    defDouble(ps, "syncMs", "Sync Offset (ms)", "grpSource", 0, -500, 500,
              "Positive delays the overlay. iPad screen capture usually arrives a little late, so try 30–100 ms.");
    defInt(ps, "frameOffset", "Frame Offset", "grpSource", 0, -1000, 1000,
           "Frames to subtract from the host time before lookup. Use Debug to check alignment.");
    defBool(ps, "debug", "Debug (show time & content box)", "grpSource", false);

    defGroup(ps, "grpFingers", "Fingers", true);
    defBool(ps, "showFingers", "Show Fingers", "grpFingers", true);
    defChoice(ps, "fingerStyle", "Style", "grpFingers", 0, {"Filled", "Ring", "Filled + Ring"});
    defDouble(ps, "fingerSize", "Size", "grpFingers", 4.5, 1, 15, "Diameter, % of screen height", 0.1, 100);
    defColor(ps, "fingerColor", "Color", "grpFingers", {1, 1, 1, 0.55});
    defBool(ps, "shadow", "Drop Shadow", "grpFingers", true, "Keeps light touch marks visible on light backgrounds.");
    defBool(ps, "tapRipple", "Tap Ripple", "grpFingers", true);
    defDouble(ps, "fingerTrailMs", "Trail (ms)", "grpFingers", 0, 0, 1000, nullptr, 0, 10000);
    defDouble(ps, "fadeMs", "Fade Out (ms)", "grpFingers", 250, 0, 1000, nullptr, 0, 10000);
    defDouble(ps, "minTouchMs", "Hide Touches Shorter Than (ms)", "grpFingers", 0, 0, 300,
              "Curate out accidental brushes.", 0, 10000);

    defGroup(ps, "grpPencil", "Apple Pencil", true);
    defBool(ps, "showPencil", "Show Pencil", "grpPencil", true);
    defColor(ps, "pencilColor", "Color", "grpPencil", {1, 0.27, 0.23, 0.9});
    defDouble(ps, "pencilSize", "Width", "grpPencil", 1.2, 0.2, 5, "% of screen height", 0.01, 100);
    defDouble(ps, "pencilTrailMs", "Trail (ms)", "grpPencil", 450, 0, 3000, nullptr, 0, 60000);
    defBool(ps, "pressureWidth", "Pressure Affects Width", "grpPencil", true);
    defBool(ps, "showPencilDot", "Show Tip Dot", "grpPencil", true);
    defBool(ps, "showHover", "Show Hover", "grpPencil", true);

    defGroup(ps, "grpPointer", "Pointer", false);
    defBool(ps, "showPointer", "Show Trackpad/Mouse Pointer", "grpPointer", true);

    defGroup(ps, "grpKeys", "Keyboard", true);
    defBool(ps, "showKeys", "Show Keys", "grpKeys", true);
    defChoice(ps, "keyMode", "Mode", "grpKeys", 0, {"All Keys", "Shortcuts Only (⌘ ⌃ ⌥)", "Modifiers Only"});
    defChoice(ps, "keyPosition", "Position", "grpKeys", 0, {"Bottom Center", "Bottom Left", "Bottom Right", "Top Center"});
    defDouble(ps, "keySize", "Size", "grpKeys", 5, 2, 12, "Key height, % of frame height", 0.5, 50);
    defDouble(ps, "keyLingerMs", "Linger (ms)", "grpKeys", 600, 0, 2000, nullptr, 0, 10000);
    defDouble(ps, "keyBgOpacity", "Background Opacity", "grpKeys", 0.75, 0, 1, nullptr, 0, 1);
    defString(ps, "ignoreKeys", "Ignore Keys", "grpKeys", false, "Comma separated, e.g. space, delete, shift");
    return kOfxStatOK;
}

static OverlayOptions readOptions(const Params& p) {
    OverlayOptions o;
    o.showFingers = p.b("showFingers");
    o.fingerStyle = p.i("fingerStyle");
    o.fingerSize = p.d("fingerSize") / 100.0;
    o.fingerColor = p.c("fingerColor");
    o.tapRipple = p.b("tapRipple");
    o.shadow = p.b("shadow");
    o.fingerTrailMs = p.d("fingerTrailMs");
    o.fadeMs = p.d("fadeMs");
    o.minTouchMs = p.d("minTouchMs");
    o.showPencil = p.b("showPencil");
    o.pencilColor = p.c("pencilColor");
    o.pencilSize = p.d("pencilSize") / 100.0;
    o.pencilTrailMs = p.d("pencilTrailMs");
    o.pressureWidth = p.b("pressureWidth");
    o.showPencilDot = p.b("showPencilDot");
    o.showHover = p.b("showHover");
    o.showPointer = p.b("showPointer");
    o.showKeys = p.b("showKeys");
    o.keyMode = p.i("keyMode");
    o.keyPosition = p.i("keyPosition");
    o.keySize = p.d("keySize") / 100.0;
    o.keyLingerMs = p.d("keyLingerMs");
    o.keyBgOpacity = p.d("keyBgOpacity");
    o.ignoreKeys = p.s("ignoreKeys");
    o.debug = p.b("debug");
    return o;
}

static OfxStatus isIdentity(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs, OfxPropertySetHandle outArgs) {
    OfxTime time = 0;
    P->propGetDouble(inArgs, kOfxPropTime, 0, &time);
    OfxParamSetHandle ps; E->getParamSet(effect, &ps);
    Params p{ps, time};
    if (p.b("debug")) return kOfxStatReplyDefault;
    SourceInfo src = sourceInfo(effect, inArgs);
    std::string path = touchFilePath(p, src, nullptr);
    if (path.empty()) return kOfxStatReplyDefault; // can't tell yet — let render decide
    if (!loadTouchData(path, nullptr)) {
        P->propSetString(outArgs, kOfxPropName, 0, kOfxImageEffectSimpleSourceClipName);
        return kOfxStatOK;
    }
    return kOfxStatReplyDefault;
}

struct Img {
    void* data = nullptr; int rowBytes = 0; OfxRectI b{0, 0, 0, 0}; std::string depth;
    explicit Img(OfxPropertySetHandle h) {
        if (!h) return;
        P->propGetPointer(h, kOfxImagePropData, 0, &data);
        P->propGetInt(h, kOfxImagePropRowBytes, 0, &rowBytes);
        P->propGetIntN(h, kOfxImagePropBounds, 4, &b.x1);
        char* d = nullptr;
        P->propGetString(h, kOfxImageEffectPropPixelDepth, 0, &d);
        depth = d ? d : "";
    }
    template <typename T> T* px(int x, int y) const {
        if (!data || x < b.x1 || x >= b.x2 || y < b.y1 || y >= b.y2) return nullptr;
        return reinterpret_cast<T*>(static_cast<char*>(data) + (ptrdiff_t)(y - b.y1) * rowBytes) + (ptrdiff_t)(x - b.x1) * 4;
    }
};

template <typename T>
static void composite(const Img& src, const Img& dst, OfxRectI win, const uint8_t* ov, int ovW, float maxV) {
    const bool isFloat = std::is_floating_point<T>::value;
    for (int y = win.y1; y < win.y2; ++y) {
        const uint8_t* row = ov + (size_t)(win.y2 - 1 - y) * ovW * 4; // CG rows are top-down
        for (int x = win.x1; x < win.x2; ++x) {
            T* d = dst.px<T>(x, y);
            if (!d) continue;
            const T* s = src.px<T>(x, y);
            const uint8_t* o = row + (x - win.x1) * 4;
            float oa = o[3] / 255.f;
            float sv[4] = {0, 0, 0, 0};
            if (s) for (int c = 0; c < 4; ++c) sv[c] = float(s[c]) / maxV;
            float r[4];
            for (int c = 0; c < 3; ++c) r[c] = sv[c] * (1 - oa) + o[c] / 255.f;
            r[3] = sv[3] * (1 - oa) + oa;
            for (int c = 0; c < 4; ++c) {
                if (isFloat) d[c] = T(r[c]);
                else d[c] = T(std::fmin(std::fmax(r[c], 0.f), 1.f) * maxV + 0.5f);
            }
        }
    }
}

static OfxStatus render(OfxImageEffectHandle effect, OfxPropertySetHandle inArgs) {
    OfxTime time = 0;
    P->propGetDouble(inArgs, kOfxPropTime, 0, &time);
    OfxRectI win;
    P->propGetIntN(inArgs, kOfxImageEffectPropRenderWindow, 4, &win.x1);
    double rs[2] = {1, 1};
    P->propGetDoubleN(inArgs, kOfxImageEffectPropRenderScale, 2, rs);

    OfxImageClipHandle srcClip = nullptr, outClip = nullptr;
    E->clipGetHandle(effect, kOfxImageEffectSimpleSourceClipName, &srcClip, nullptr);
    E->clipGetHandle(effect, kOfxImageEffectOutputClipName, &outClip, nullptr);
    OfxPropertySetHandle outH = nullptr, srcH = nullptr;
    if (E->clipGetImage(outClip, time, nullptr, &outH) != kOfxStatOK) return kOfxStatFailed;
    if (E->clipGetImage(srcClip, time, nullptr, &srcH) != kOfxStatOK) srcH = nullptr;
    Img dst(outH), src(srcH);

    OfxParamSetHandle ps; E->getParamSet(effect, &ps);
    Params p{ps, time};
    OverlayOptions opts = readOptions(p);
    std::string err;
    SourceInfo media = sourceInfo(effect, inArgs);
    bool automatic = false;
    std::string path = touchFilePath(p, media, &automatic);
    auto data = loadTouchData(path, &err);
    if (!data && automatic) err = media.mediaPath.empty() ? "no media path from host — set Touch Data Override"
                                                        : "no .touches.json next to clip media";
    static const TouchData empty;
    const TouchData& td = data ? *data : empty;

    OfxRectD rod{0, 0, 0, 0};
    E->clipGetRegionOfDefinition(srcClip, time, &rod);
    CGRect frame = CGRectMake(rod.x1 * rs[0], rod.y1 * rs[1], (rod.x2 - rod.x1) * rs[0], (rod.y2 - rod.y1) * rs[1]);

    double fps = 0;
    OfxPropertySetHandle effProps; E->getPropertySet(effect, &effProps);
    P->propGetDouble(effProps, kOfxImageEffectPropFrameRate, 0, &fps);
    if (fps <= 0) fps = td.fps > 0 ? td.fps : 30;
    // Prefer Resolve's source-media frame (independent of timeline position and trims) at the recording's fps.
    double frameNum, frameFps;
    if (media.hasFrame) { frameNum = media.frame; frameFps = td.fps > 0 ? td.fps : fps; }
    else { frameNum = time; frameFps = fps; }
    frameNum -= p.i("frameOffset");
    double t = frameNum / frameFps - p.d("syncMs") / 1000.0;

    int w = win.x2 - win.x1, h = win.y2 - win.y1;
    std::vector<uint8_t> ov((size_t)std::max(w, 0) * std::max(h, 0) * 4, 0);
    if (w > 0 && h > 0) {
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(ov.data(), w, h, 8, w * 4, cs,
                                                 kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
        CGColorSpaceRelease(cs);
        if (ctx) {
            CGContextTranslateCTM(ctx, -win.x1, -win.y1);
            char dbg[512];
            std::string name = path.empty() ? std::string("—") : path.substr(path.find_last_of('/') + 1);
            snprintf(dbg, sizeof dbg, "%s frame %.0f  →  %.3f s @ %.3g fps   %s: %s",
                     media.hasFrame ? "src" : "host", frameNum, t, frameFps,
                     automatic ? "auto" : "override", data ? name.c_str() : err.c_str());
            drawOverlay(ctx, td, t, frame, opts, dbg);
            CGContextRelease(ctx);
        }
        if (dst.depth == kOfxBitDepthFloat) composite<float>(src, dst, win, ov.data(), w, 1.f);
        else if (dst.depth == kOfxBitDepthShort) composite<uint16_t>(src, dst, win, ov.data(), w, 65535.f);
        else composite<uint8_t>(src, dst, win, ov.data(), w, 255.f);
    }
    if (srcH) E->clipReleaseImage(srcH);
    E->clipReleaseImage(outH);
    return kOfxStatOK;
}

static OfxStatus dispatch(const char* action, OfxImageEffectHandle effect, OfxPropertySetHandle inArgs,
                          OfxPropertySetHandle outArgs) {
    if (!strcmp(action, kOfxActionLoad)) return onLoad();
    if (!strcmp(action, kOfxActionDescribe)) return describe(effect);
    if (!strcmp(action, kOfxImageEffectActionDescribeInContext)) return describeInContext(effect);
    if (!strcmp(action, kOfxImageEffectActionRender)) return render(effect, inArgs);
    if (!strcmp(action, kOfxImageEffectActionIsIdentity)) return isIdentity(effect, inArgs, outArgs);
    // Resolve treats anything but kOfxStatOK from these as failure, despite the spec allowing ReplyDefault.
    if (!strcmp(action, kOfxActionCreateInstance) || !strcmp(action, kOfxActionDestroyInstance) ||
        !strcmp(action, kOfxActionUnload))
        return kOfxStatOK;
    return kOfxStatReplyDefault;
}

static OfxStatus mainEntry(const char* action, const void* handle, OfxPropertySetHandle inArgs, OfxPropertySetHandle outArgs) {
    @autoreleasepool {
        OfxStatus s;
        try {
            s = dispatch(action, (OfxImageEffectHandle)handle, inArgs, outArgs);
        } catch (const std::exception& e) {
            logLine("%s threw: %s", action, e.what());
            return kOfxStatFailed;
        } catch (...) {
            logLine("%s threw unknown exception", action);
            return kOfxStatFailed;
        }
        if (s == kOfxStatFailed) logLine("%s failed", action);
        return s;
    }
}

static void setHost(OfxHost* h) { gHost = h; }

static OfxPlugin gPlugin = {kOfxImageEffectPluginApi, 1, "com.fform.touchrecordkit.ofx", 1, 0, setHost, mainEntry};

extern "C" {
OfxExport int OfxGetNumberOfPlugins(void) { return 1; }
OfxExport OfxPlugin* OfxGetPlugin(int n) { return n == 0 ? &gPlugin : nullptr; }
}
