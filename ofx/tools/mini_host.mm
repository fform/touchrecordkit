// Minimal OFX host for testing the TouchRecordKit Touches plugin outside Resolve.
// Usage: mini_host <plugin binary> <touches.json> <outdir> <frame> [frame...]
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <cstdarg>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>
#include "ofxCore.h"
#include "ofxImageEffect.h"
#include "ofxParam.h"
#include "ofxProperty.h"

struct Prop { std::vector<std::string> s; std::vector<double> d; std::vector<int> i; std::vector<void*> p; };
struct PropSet { std::map<std::string, Prop> m; };
#define PSH(h) (reinterpret_cast<PropSet*>(h))

template <typename V> static void setv(std::vector<V>& v, int idx, V x) { if ((int)v.size() <= idx) v.resize(idx + 1); v[idx] = x; }

static OfxStatus pSetPointer(OfxPropertySetHandle h, const char* n, int i, void* v) { setv(PSH(h)->m[n].p, i, v); return kOfxStatOK; }
static OfxStatus pSetString(OfxPropertySetHandle h, const char* n, int i, const char* v) { setv(PSH(h)->m[n].s, i, std::string(v)); return kOfxStatOK; }
static OfxStatus pSetDouble(OfxPropertySetHandle h, const char* n, int i, double v) { setv(PSH(h)->m[n].d, i, v); return kOfxStatOK; }
static OfxStatus pSetInt(OfxPropertySetHandle h, const char* n, int i, int v) { setv(PSH(h)->m[n].i, i, v); return kOfxStatOK; }
static OfxStatus pSetPointerN(OfxPropertySetHandle h, const char* n, int c, void* const* v) { for (int i = 0; i < c; ++i) pSetPointer(h, n, i, v[i]); return kOfxStatOK; }
static OfxStatus pSetStringN(OfxPropertySetHandle h, const char* n, int c, const char* const* v) { for (int i = 0; i < c; ++i) pSetString(h, n, i, v[i]); return kOfxStatOK; }
static OfxStatus pSetDoubleN(OfxPropertySetHandle h, const char* n, int c, const double* v) { for (int i = 0; i < c; ++i) pSetDouble(h, n, i, v[i]); return kOfxStatOK; }
static OfxStatus pSetIntN(OfxPropertySetHandle h, const char* n, int c, const int* v) { for (int i = 0; i < c; ++i) pSetInt(h, n, i, v[i]); return kOfxStatOK; }
static OfxStatus pGetPointer(OfxPropertySetHandle h, const char* n, int i, void** v) { auto& x = PSH(h)->m[n].p; if (i >= (int)x.size()) return kOfxStatErrUnknown; *v = x[i]; return kOfxStatOK; }
static OfxStatus pGetString(OfxPropertySetHandle h, const char* n, int i, char** v) { auto& x = PSH(h)->m[n].s; if (i >= (int)x.size()) return kOfxStatErrUnknown; *v = (char*)x[i].c_str(); return kOfxStatOK; }
static OfxStatus pGetDouble(OfxPropertySetHandle h, const char* n, int i, double* v) { auto& x = PSH(h)->m[n].d; if (i >= (int)x.size()) return kOfxStatErrUnknown; *v = x[i]; return kOfxStatOK; }
static OfxStatus pGetInt(OfxPropertySetHandle h, const char* n, int i, int* v) { auto& x = PSH(h)->m[n].i; if (i >= (int)x.size()) return kOfxStatErrUnknown; *v = x[i]; return kOfxStatOK; }
static OfxStatus pGetPointerN(OfxPropertySetHandle h, const char* n, int c, void** v) { for (int i = 0; i < c; ++i) if (pGetPointer(h, n, i, v + i)) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus pGetStringN(OfxPropertySetHandle h, const char* n, int c, char** v) { for (int i = 0; i < c; ++i) if (pGetString(h, n, i, v + i)) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus pGetDoubleN(OfxPropertySetHandle h, const char* n, int c, double* v) { for (int i = 0; i < c; ++i) if (pGetDouble(h, n, i, v + i)) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus pGetIntN(OfxPropertySetHandle h, const char* n, int c, int* v) { for (int i = 0; i < c; ++i) if (pGetInt(h, n, i, v + i)) return kOfxStatErrUnknown; return kOfxStatOK; }
static OfxStatus pReset(OfxPropertySetHandle h, const char* n) { PSH(h)->m.erase(n); return kOfxStatOK; }
static OfxStatus pGetDim(OfxPropertySetHandle h, const char* n, int* c) { auto& x = PSH(h)->m[n]; *c = (int)std::max({x.s.size(), x.d.size(), x.i.size(), x.p.size()}); return kOfxStatOK; }

struct Param { std::string type; PropSet props; };
struct ParamSet { std::map<std::string, std::unique_ptr<Param>> params; std::vector<std::string> order; PropSet props; };
struct Image { PropSet props; std::vector<float> f; };
struct Clip { PropSet props; Image* image = nullptr; OfxRectD rod; };
struct Effect { PropSet props; ParamSet params; std::map<std::string, std::unique_ptr<Clip>> clips; };

static OfxStatus eGetPropertySet(OfxImageEffectHandle e, OfxPropertySetHandle* p) { *p = (OfxPropertySetHandle)&((Effect*)e)->props; return kOfxStatOK; }
static OfxStatus eGetParamSet(OfxImageEffectHandle e, OfxParamSetHandle* p) { *p = (OfxParamSetHandle)&((Effect*)e)->params; return kOfxStatOK; }
static OfxStatus eClipDefine(OfxImageEffectHandle e, const char* n, OfxPropertySetHandle* p) {
    auto& c = ((Effect*)e)->clips[n]; c = std::make_unique<Clip>(); *p = (OfxPropertySetHandle)&c->props; return kOfxStatOK; }
static OfxStatus eClipGetHandle(OfxImageEffectHandle e, const char* n, OfxImageClipHandle* c, OfxPropertySetHandle* p) {
    auto it = ((Effect*)e)->clips.find(n); if (it == ((Effect*)e)->clips.end()) return kOfxStatErrBadHandle;
    *c = (OfxImageClipHandle)it->second.get(); if (p) *p = (OfxPropertySetHandle)&it->second->props; return kOfxStatOK; }
static OfxStatus eClipGetPropertySet(OfxImageClipHandle c, OfxPropertySetHandle* p) { *p = (OfxPropertySetHandle)&((Clip*)c)->props; return kOfxStatOK; }
static OfxStatus eClipGetImage(OfxImageClipHandle c, OfxTime, const OfxRectD*, OfxPropertySetHandle* p) {
    auto* clip = (Clip*)c; if (!clip->image) return kOfxStatFailed; *p = (OfxPropertySetHandle)&clip->image->props; return kOfxStatOK; }
static OfxStatus eClipReleaseImage(OfxPropertySetHandle) { return kOfxStatOK; }
static OfxStatus eClipGetRoD(OfxImageClipHandle c, OfxTime, OfxRectD* r) { *r = ((Clip*)c)->rod; return kOfxStatOK; }
static int eAbort(OfxImageEffectHandle) { return 0; }

static OfxStatus parDefine(OfxParamSetHandle ps, const char* type, const char* n, OfxPropertySetHandle* p) {
    auto* s = (ParamSet*)ps; auto& x = s->params[n]; x = std::make_unique<Param>(); x->type = type; s->order.push_back(n);
    if (p) *p = (OfxPropertySetHandle)&x->props; return kOfxStatOK; }
static OfxStatus parGetHandle(OfxParamSetHandle ps, const char* n, OfxParamHandle* h, OfxPropertySetHandle* p) {
    auto* s = (ParamSet*)ps; auto it = s->params.find(n); if (it == s->params.end()) return kOfxStatErrUnknown;
    *h = (OfxParamHandle)it->second.get(); if (p) *p = (OfxPropertySetHandle)&it->second->props; return kOfxStatOK; }
static OfxStatus parGetValueV(OfxParamHandle h, va_list ap) {
    auto* p = (Param*)h; auto& d = p->props.m[kOfxParamPropDefault];
    if (p->type == kOfxParamTypeDouble) *va_arg(ap, double*) = d.d.at(0);
    else if (p->type == kOfxParamTypeInteger || p->type == kOfxParamTypeBoolean || p->type == kOfxParamTypeChoice) *va_arg(ap, int*) = d.i.at(0);
    else if (p->type == kOfxParamTypeRGBA) for (int i = 0; i < 4; ++i) *va_arg(ap, double*) = d.d.at(i);
    else if (p->type == kOfxParamTypeString) *va_arg(ap, char**) = (char*)d.s.at(0).c_str();
    else return kOfxStatErrUnknown;
    return kOfxStatOK;
}
static OfxStatus parGetValue(OfxParamHandle h, ...) { va_list ap; va_start(ap, h); auto r = parGetValueV(h, ap); va_end(ap); return r; }
static OfxStatus parGetValueAtTime(OfxParamHandle h, OfxTime, ...) { va_list ap; va_start(ap, h); auto r = parGetValueV(h, ap); va_end(ap); return r; }

static OfxPropertySuiteV1 gProps;
static OfxImageEffectSuiteV1 gEffect;
static OfxParameterSuiteV1 gParams;
static PropSet gHostProps;
static const void* fetchSuite(OfxPropertySetHandle, const char* name, int) {
    if (!strcmp(name, kOfxPropertySuite)) return &gProps;
    if (!strcmp(name, kOfxImageEffectSuite)) return &gEffect;
    if (!strcmp(name, kOfxParameterSuite)) return &gParams;
    return nullptr;
}

static void setParam(Effect& e, const char* n, int v) { e.params.params.at(n)->props.m[kOfxParamPropDefault].i = {v}; }
static void setParamS(Effect& e, const char* n, const std::string& v) { e.params.params.at(n)->props.m[kOfxParamPropDefault].s = {v}; }

int main(int argc, char** argv) {
    if (argc < 5) { fprintf(stderr, "usage: mini_host plugin json outdir frame...\n"); return 1; }
    gProps.propSetPointer = pSetPointer; gProps.propSetString = pSetString; gProps.propSetDouble = pSetDouble; gProps.propSetInt = pSetInt;
    gProps.propSetPointerN = pSetPointerN; gProps.propSetStringN = pSetStringN; gProps.propSetDoubleN = pSetDoubleN; gProps.propSetIntN = pSetIntN;
    gProps.propGetPointer = pGetPointer; gProps.propGetString = pGetString; gProps.propGetDouble = pGetDouble; gProps.propGetInt = pGetInt;
    gProps.propGetPointerN = pGetPointerN; gProps.propGetStringN = pGetStringN; gProps.propGetDoubleN = pGetDoubleN; gProps.propGetIntN = pGetIntN;
    gProps.propReset = pReset; gProps.propGetDimension = pGetDim;
    gEffect.getPropertySet = eGetPropertySet; gEffect.getParamSet = eGetParamSet; gEffect.clipDefine = eClipDefine;
    gEffect.clipGetHandle = eClipGetHandle; gEffect.clipGetPropertySet = eClipGetPropertySet; gEffect.clipGetImage = eClipGetImage;
    gEffect.clipReleaseImage = eClipReleaseImage; gEffect.clipGetRegionOfDefinition = eClipGetRoD; gEffect.abort = eAbort;
    gParams.paramDefine = parDefine; gParams.paramGetHandle = parGetHandle; gParams.paramGetValue = parGetValue; gParams.paramGetValueAtTime = parGetValueAtTime;
    OfxHost host{(OfxPropertySetHandle)&gHostProps, fetchSuite};

    void* lib = dlopen(argv[1], RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    auto getN = (int (*)())dlsym(lib, "OfxGetNumberOfPlugins");
    auto get = (OfxPlugin * (*)(int)) dlsym(lib, "OfxGetPlugin");
    OfxPlugin* plug = get(0);
    printf("plugins: %d  id: %s  api: %s\n", getN(), plug->pluginIdentifier, plug->pluginApi);
    plug->setHost(&host);

    Effect fx;
    auto act = [&](const char* a, OfxPropertySetHandle in = nullptr, OfxPropertySetHandle out = nullptr) {
        OfxStatus s = plug->mainEntry(a, &fx, in, out);
        printf("%-40s -> %d\n", a, s);
        return s;
    };
    act(kOfxActionLoad);
    act(kOfxActionDescribe);
    char* label = nullptr; pGetString((OfxPropertySetHandle)&fx.props, kOfxPropLabel, 0, &label);
    printf("label: %s\n", label);
    act(kOfxImageEffectActionDescribeInContext);
    printf("params (%zu):", fx.params.order.size());
    for (auto& n : fx.params.order) printf(" %s", n.c_str());
    printf("\n");
    if (act(kOfxActionCreateInstance) != kOfxStatOK) { fprintf(stderr, "createInstance must return OK (Resolve requires it)\n"); return 1; }

    const int W = 1920, H = 1080;
    Image src, dst;
    src.f.resize(W * H * 4); dst.f.resize(W * H * 4);
    for (int y = 0; y < H; ++y) for (int x = 0; x < W; ++x) {
        float* p = &src.f[(y * W + x) * 4];
        bool inPad = x >= 240 && x < 1680; // 4:3 iPad area pillarboxed in 16:9
        p[0] = inPad ? 0.18f + 0.15f * y / H : 0; p[1] = inPad ? 0.2f : 0; p[2] = inPad ? 0.25f + 0.1f * x / W : 0; p[3] = 1;
    }
    if (const char* bg = getenv("TRK_BG")) {
        CGImageSourceRef is = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(bg)], nullptr);
        CGImageRef bi = is ? CGImageSourceCreateImageAtIndex(is, 0, nullptr) : nullptr;
        if (bi) {
            std::vector<uint8_t> px(W * H * 4);
            CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef bc = CGBitmapContextCreate(px.data(), W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
            CGContextDrawImage(bc, CGRectMake(0, 0, W, H), bi);
            for (int y = 0; y < H; ++y) for (int x = 0; x < W * 4; ++x)   // CG rows top-down -> OFX bottom-up
                src.f[y * W * 4 + x] = px[(H - 1 - y) * W * 4 + x] / 255.f;
            CGContextRelease(bc); CGColorSpaceRelease(cs); CGImageRelease(bi);
        }
        if (is) CFRelease(is);
    }
    for (Image* im : {&src, &dst}) {
        void* data = im->f.data(); int b[4] = {0, 0, W, H};
        pSetPointer((OfxPropertySetHandle)&im->props, kOfxImagePropData, 0, data);
        pSetInt((OfxPropertySetHandle)&im->props, kOfxImagePropRowBytes, 0, W * 16);
        pSetIntN((OfxPropertySetHandle)&im->props, kOfxImagePropBounds, 4, b);
        pSetString((OfxPropertySetHandle)&im->props, kOfxImageEffectPropPixelDepth, 0, kOfxBitDepthFloat);
    }
    fx.clips.at(kOfxImageEffectSimpleSourceClipName)->image = &src;
    fx.clips.at(kOfxImageEffectSimpleSourceClipName)->rod = {0, 0, W, H};
    fx.clips.at(kOfxImageEffectOutputClipName)->image = &dst;
    fx.clips.at(kOfxImageEffectOutputClipName)->rod = {0, 0, W, H};
    pSetDouble((OfxPropertySetHandle)&fx.props, kOfxImageEffectPropFrameRate, 0, 60);

    PropSet in, out;
    // No file yet -> identity
    pSetDouble((OfxPropertySetHandle)&in, kOfxPropTime, 0, 0);
    act(kOfxImageEffectActionIsIdentity, (OfxPropertySetHandle)&in, (OfxPropertySetHandle)&out);
    // A .mp4 argument simulates Resolve: media path + source frame are passed, Touch Data param left empty.
    bool simulateResolve = std::string(argv[2]).size() > 4 && std::string(argv[2]).substr(std::string(argv[2]).size() - 4) == ".mp4";
    if (!simulateResolve) setParamS(fx, "file", argv[2]);
    setParam(fx, "debug", getenv("TRK_BG") ? 0 : 1);
    setParam(fx, "fingerTrailMs", 0);

    for (int a = 4; a < argc; ++a) {
        double frame = atof(argv[a]);
        PropSet ra;
        int win[4] = {0, 0, W, H}; double rs[2] = {1, 1};
        pSetDouble((OfxPropertySetHandle)&ra, kOfxPropTime, 0, simulateResolve ? frame + 1000 : frame); // timeline time ≠ source frame
        if (simulateResolve) {
            pSetString((OfxPropertySetHandle)&ra, "OfxImageEffectPropSrcFilePath", 0, argv[2]);
            pSetDouble((OfxPropertySetHandle)&ra, "OfxImageEffectPropSrcFrame", 0, frame);
        }
        pSetIntN((OfxPropertySetHandle)&ra, kOfxImageEffectPropRenderWindow, 4, win);
        pSetDoubleN((OfxPropertySetHandle)&ra, kOfxImageEffectPropRenderScale, 2, rs);
        if (act(kOfxImageEffectActionRender, (OfxPropertySetHandle)&ra) != kOfxStatOK) return 1;
        // write PNG (OFX rows are bottom-up)
        std::vector<uint8_t> rgba(W * H * 4);
        for (int y = 0; y < H; ++y) for (int x = 0; x < W * 4; ++x)
            rgba[(H - 1 - y) * W * 4 + x] = (uint8_t)(std::min(std::max(dst.f[y * W * 4 + x], 0.f), 1.f) * 255 + 0.5f);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(rgba.data(), W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedLast);
        CGImageRef img = CGBitmapContextCreateImage(ctx);
        NSString* path = [NSString stringWithFormat:@"%s/frame_%04d.png", argv[3], (int)frame];
        CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, nullptr);
        CGImageDestinationAddImage(d, img, nullptr); CGImageDestinationFinalize(d);
        CFRelease(d); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    }
    return 0;
}
