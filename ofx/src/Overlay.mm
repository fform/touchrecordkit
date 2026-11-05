#import <Foundation/Foundation.h>
#import <CoreText/CoreText.h>
#include "Overlay.h"
#include <algorithm>
#include <cmath>
#include <set>
#include <sstream>

namespace trk {

static CGRect aspectFit(double aspect, CGRect r) {
    if (aspect <= 0) return r;
    double w = r.size.width, h = r.size.height;
    if (w / h > aspect) w = h * aspect; else h = w / aspect;
    return CGRectMake(CGRectGetMidX(r) - w / 2, CGRectGetMidY(r) - h / 2, w, h);
}

CGRect contentRect(const TouchData& d, double t, CGRect frame) {
    double va = (d.videoW > 0 && d.videoH > 0) ? d.videoW / d.videoH : d.screenAspect(t);
    return aspectFit(d.screenAspect(t), aspectFit(va, frame));
}

static inline CGPoint toFrame(const Sample& s, CGRect c) {
    return CGPointMake(c.origin.x + s.x * c.size.width, CGRectGetMaxY(c) - s.y * c.size.height);
}

static Sample sampleAt(const Stroke& st, double t) {
    const auto& v = st.samples;
    auto it = std::lower_bound(v.begin(), v.end(), t, [](const Sample& s, double t) { return s.t < t; });
    if (it == v.begin()) return v.front();
    if (it == v.end()) return v.back();
    const Sample& b = *it; const Sample& a = *(it - 1);
    double f = (b.t > a.t) ? (t - a.t) / (b.t - a.t) : 0;
    Sample s = a;
    s.t = t;
    s.x = a.x + (b.x - a.x) * f; s.y = a.y + (b.y - a.y) * f;
    s.force = a.force + (b.force - a.force) * f;
    return s;
}

static void setFill(CGContextRef c, RGBA k, double alpha) { CGContextSetRGBFillColor(c, k.r, k.g, k.b, k.a * alpha); }
static void setStroke(CGContextRef c, RGBA k, double alpha) { CGContextSetRGBStrokeColor(c, k.r, k.g, k.b, k.a * alpha); }

/// Soft dark shadow scaled to the mark size; makes light marks visible on light backgrounds.
static void beginShadow(CGContextRef c, bool on, double r, double alpha) {
    CGContextSaveGState(c);
    if (!on) return;
    CGColorRef col = CGColorCreateSRGB(0, 0, 0, 0.55 * alpha);
    CGContextSetShadowWithColor(c, CGSizeMake(0, -r * 0.06), std::max(2.0, r * 0.45), col);
    CGColorRelease(col);
}
static void endShadow(CGContextRef c) { CGContextRestoreGState(c); }

static void circle(CGContextRef c, CGPoint p, double r, bool fill) {
    CGRect rr = CGRectMake(p.x - r, p.y - r, r * 2, r * 2);
    if (fill) CGContextFillEllipseInRect(c, rr); else CGContextStrokeEllipseInRect(c, rr);
}

/// Trail made of short segments so width (pressure) and alpha (age) can vary along it.
static void drawTrail(CGContextRef c, const Stroke& st, double t, double trailSec, CGRect content,
                      RGBA color, double baseWidth, bool pressure) {
    if (trailSec <= 0) return;
    double from = t - trailSec;
    const auto& v = st.samples;
    auto it = std::lower_bound(v.begin(), v.end(), from, [](const Sample& s, double t) { return s.t < t; });
    if (it != v.begin()) --it;
    CGContextSetLineCap(c, kCGLineCapRound);
    for (; it + 1 != v.end() && it->t <= t; ++it) {
        Sample a = *it, b = *(it + 1);
        if (b.t > t) b = sampleAt(st, t);
        double age = t - b.t;
        double alpha = std::clamp(1.0 - age / trailSec, 0.0, 1.0);
        if (alpha <= 0) continue;
        double f = pressure ? std::clamp(0.25 + 1.5 * (a.force + b.force) / 2, 0.25, 1.6) : 1.0;
        setStroke(c, color, alpha);
        CGContextSetLineWidth(c, std::max(1.0, baseWidth * f));
        CGPoint pa = toFrame(a, content), pb = toFrame(b, content);
        CGContextMoveToPoint(c, pa.x, pa.y);
        CGContextAddLineToPoint(c, pb.x, pb.y);
        CGContextStrokePath(c);
    }
}

// MARK: Keys

static std::string symbolFor(const std::string& l) {
    static const std::pair<const char*, const char*> map[] = {
        {"cmd", "⌘"}, {"shift", "⇧"}, {"option", "⌥"}, {"control", "⌃"}, {"capslock", "⇪"},
        {"return", "↩"}, {"delete", "⌫"}, {"fwddelete", "⌦"}, {"tab", "⇥"}, {"esc", "esc"},
        {"space", "space"}, {"left", "←"}, {"right", "→"}, {"up", "↑"}, {"down", "↓"}, {"fn", "fn"}};
    for (auto& m : map) if (l == m.first) return m.second;
    return l;
}

static int modifierOrder(const std::string& l) {
    if (l == "control") return 0; if (l == "option") return 1; if (l == "shift") return 2;
    if (l == "cmd") return 3; if (l == "capslock") return 4; return 5;
}

static std::set<std::string> parseIgnore(const std::string& s) {
    std::set<std::string> out;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        item.erase(0, item.find_first_not_of(" \t"));
        item.erase(item.find_last_not_of(" \t") + 1);
        std::string lower = item;
        std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
        if (!lower.empty()) out.insert(lower);
    }
    return out;
}

struct Cap { std::string text; double alpha; };

static void drawText(CGContextRef c, const std::string& text, CGPoint baselineCenter, double size, RGBA color, double alpha,
                     double* outWidth = nullptr, bool measureOnly = false) {
    @autoreleasepool {
        CTFontRef font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, nullptr);
        CGColorRef col = CGColorCreateSRGB(color.r, color.g, color.b, color.a * alpha);
        NSDictionary* attrs = @{(__bridge id)kCTFontAttributeName: (__bridge id)font,
                                (__bridge id)kCTForegroundColorAttributeName: (__bridge id)col};
        NSAttributedString* as = [[NSAttributedString alloc] initWithString:[NSString stringWithUTF8String:text.c_str()]
                                                                 attributes:attrs];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)as);
        double w = CTLineGetTypographicBounds(line, nullptr, nullptr, nullptr);
        if (outWidth) *outWidth = w;
        if (!measureOnly) {
            CGContextSetTextMatrix(c, CGAffineTransformIdentity);
            CGContextSetTextPosition(c, baselineCenter.x - w / 2, baselineCenter.y);
            CTLineDraw(line, c);
        }
        CFRelease(line); CGColorRelease(col); CFRelease(font);
    }
}

static void drawKeys(CGContextRef c, const TouchData& d, double t, CGRect frame, const OverlayOptions& o) {
    double linger = o.keyLingerMs / 1000.0;
    auto ignore = parseIgnore(o.ignoreKeys);
    auto ignored = [&](const std::string& l) {
        std::string lower = l; std::transform(lower.begin(), lower.end(), lower.begin(), ::tolower);
        return ignore.count(lower) > 0;
    };
    auto alphaFor = [&](const KeyPress& k) {
        if (t < k.down) return 0.0;
        if (t <= k.up) return 1.0;
        return linger > 0 ? std::clamp(1.0 - (t - k.up) / linger, 0.0, 1.0) : 0.0;
    };

    std::vector<Cap> caps;
    if (o.keyMode == 1) {
        // Shortcuts: most recent non-modifier key pressed with ⌘/⌃/⌥, shown as a combo.
        const KeyPress* best = nullptr;
        for (const auto& k : d.keys) {
            if (k.down > t) break;
            if (k.isModifier || ignored(k.label) || alphaFor(k) <= 0) continue;
            bool combo = false;
            for (auto& m : k.modifiers) if (m == "cmd" || m == "control" || m == "option") combo = true;
            if (combo) best = &k;
        }
        if (best) {
            double a = alphaFor(*best);
            auto mods = best->modifiers;
            std::sort(mods.begin(), mods.end(), [](auto& x, auto& y) { return modifierOrder(x) < modifierOrder(y); });
            for (auto& m : mods) if (m != "capslock") caps.push_back({symbolFor(m), a});
            caps.push_back({symbolFor(best->label), a});
        }
    } else {
        std::vector<const KeyPress*> active;
        for (const auto& k : d.keys) {
            if (k.down > t) break;
            if (ignored(k.label) || alphaFor(k) <= 0) continue;
            if (o.keyMode == 2 && !k.isModifier) continue;
            active.push_back(&k);
        }
        std::stable_sort(active.begin(), active.end(), [](auto* a, auto* b) {
            if (a->isModifier != b->isModifier) return a->isModifier;
            if (a->isModifier) return modifierOrder(a->label) < modifierOrder(b->label);
            return a->down < b->down;
        });
        // Keep it readable while typing fast: at most 8 caps, newest last.
        if (active.size() > 8) active.erase(active.begin(), active.end() - 8);
        for (auto* k : active) caps.push_back({symbolFor(k->label), alphaFor(*k)});
    }
    if (caps.empty()) return;

    double h = frame.size.height * o.keySize;
    double font = h * 0.5, pad = h * 0.32, gap = h * 0.18, radius = h * 0.22;
    std::vector<double> widths;
    double total = 0;
    for (auto& cap : caps) {
        double w = 0;
        drawText(c, cap.text, CGPointZero, font, {1, 1, 1, 1}, 1, &w, true);
        w = std::max(h, w + pad * 2);
        widths.push_back(w);
        total += w;
    }
    total += gap * (caps.size() - 1);
    double margin = frame.size.height * 0.05;
    double x;
    switch (o.keyPosition) {
        case 1: x = frame.origin.x + margin; break;
        case 2: x = CGRectGetMaxX(frame) - margin - total; break;
        default: x = CGRectGetMidX(frame) - total / 2; break;
    }
    double y = o.keyPosition == 3 ? CGRectGetMaxY(frame) - margin - h : frame.origin.y + margin;

    for (size_t i = 0; i < caps.size(); ++i) {
        CGRect r = CGRectMake(x, y, widths[i], h);
        CGPathRef p = CGPathCreateWithRoundedRect(r, radius, radius, nullptr);
        CGContextAddPath(c, p);
        CGContextSetRGBFillColor(c, 0.08, 0.08, 0.1, o.keyBgOpacity * caps[i].alpha);
        CGContextFillPath(c);
        CGContextAddPath(c, p);
        CGContextSetRGBStrokeColor(c, 1, 1, 1, 0.25 * caps[i].alpha);
        CGContextSetLineWidth(c, std::max(1.0, h * 0.03));
        CGContextStrokePath(c);
        CGPathRelease(p);
        drawText(c, caps[i].text, CGPointMake(CGRectGetMidX(r), y + h * 0.5 - font * 0.36), font,
                 {1, 1, 1, 1}, caps[i].alpha);
        x += widths[i] + gap;
    }
}

// MARK: Main

void drawOverlay(CGContextRef c, const TouchData& d, double t, CGRect frame,
                 const OverlayOptions& o, const std::string& debugText) {
    CGRect content = contentRect(d, t, frame);
    double H = content.size.height;
    double fade = o.fadeMs / 1000.0;
    double maxTail = std::max({fade, o.pencilTrailMs / 1000.0, o.fingerTrailMs / 1000.0, 0.4});

    CGContextSaveGState(c);
    CGContextSetShouldAntialias(c, true);

    for (const auto& st : d.strokes) {
        if (st.start > t) break;
        if (st.end + maxTail < t || st.samples.empty()) continue;

        bool active = t <= st.end;
        double since = t - st.end;

        if (st.hover) {
            if (!o.showHover || (st.kind == Kind::Pointer && !o.showPointer)) continue;
            if (st.kind == Kind::Finger) continue;
            double a = active ? 1.0 : std::clamp(1.0 - since / 0.15, 0.0, 1.0);
            if (a <= 0) continue;
            CGPoint p = toFrame(sampleAt(st, t), content);
            RGBA col = st.kind == Kind::Pencil ? o.pencilColor : o.fingerColor;
            double hr = H * (st.kind == Kind::Pencil ? o.pencilSize : o.fingerSize * 0.35);
            beginShadow(c, o.shadow, hr, a);
            setStroke(c, col, a * 0.7);
            CGContextSetLineWidth(c, std::max(1.0, H * 0.003));
            circle(c, p, hr, false);
            endShadow(c);
            continue;
        }

        if (st.ended && o.minTouchMs > 0 && (st.end - st.start) * 1000 < o.minTouchMs) continue;

        if (st.kind == Kind::Pencil) {
            if (!o.showPencil) continue;
            drawTrail(c, st, std::min(t, st.end + o.pencilTrailMs / 1000.0), o.pencilTrailMs / 1000.0, content,
                      o.pencilColor, H * o.pencilSize, o.pressureWidth);
            if (o.showPencilDot) {
                double a = active ? 1.0 : (fade > 0 ? std::clamp(1.0 - since / fade, 0.0, 1.0) : 0);
                if (a > 0) {
                    Sample s = sampleAt(st, t);
                    double f = o.pressureWidth ? std::clamp(0.4 + 1.2 * s.force, 0.4, 1.6) : 1.0;
                    setFill(c, o.pencilColor, a);
                    circle(c, toFrame(s, content), H * o.pencilSize * 0.9 * f, true);
                }
            }
            continue;
        }

        // Finger / pointer click
        if (st.kind == Kind::Finger ? !o.showFingers : !o.showPointer) continue;
        double scale = st.kind == Kind::Pointer ? 0.6 : 1.0;
        double r = H * o.fingerSize * 0.5 * scale;

        if (o.fingerTrailMs > 0)
            drawTrail(c, st, std::min(t, st.end + o.fingerTrailMs / 1000.0), o.fingerTrailMs / 1000.0, content,
                      o.fingerColor, r * 0.5, false);

        double a = active ? 1.0 : (fade > 0 ? std::clamp(1.0 - since / fade, 0.0, 1.0) : 0);
        int style = (o.fingerStyle >= 0 && o.fingerStyle <= 2) ? o.fingerStyle : 0;
        if (a > 0) {
            CGPoint p = toFrame(sampleAt(st, t), content);
            beginShadow(c, o.shadow, r, a);
            if (style == 0 || style == 2) { setFill(c, o.fingerColor, a); circle(c, p, r, true); }
            if (style == 1 || style == 2) {
                RGBA ring = o.fingerColor; ring.a = std::min(1.0, ring.a * 1.6);
                setStroke(c, ring, a);
                CGContextSetLineWidth(c, std::max(1.5, r * 0.18));
                circle(c, p, r, false);
            }
            endShadow(c);
        }
        if (o.tapRipple) {
            double age = t - st.start, dur = 0.35;
            if (age >= 0 && age < dur) {
                double k = age / dur;
                beginShadow(c, o.shadow, r * 0.5, 1.0 - k);
                RGBA ring = o.fingerColor; ring.a = std::min(1.0, ring.a * 1.4);
                setStroke(c, ring, 1.0 - k);
                CGContextSetLineWidth(c, std::max(1.0, r * 0.12));
                circle(c, toFrame(st.samples.front(), content), r * (1.0 + 1.2 * k), false);
                endShadow(c);
            }
        }
    }

    if (o.showKeys) drawKeys(c, d, t, frame, o);

    if (o.debug) {
        CGContextSetRGBStrokeColor(c, 0, 1, 1, 0.8);
        CGContextSetLineWidth(c, 2);
        CGContextStrokeRect(c, CGRectInset(content, 1, 1));
        double size = frame.size.height * 0.03;
        drawText(c, debugText, CGPointMake(CGRectGetMidX(frame), CGRectGetMaxY(frame) - size * 1.6), size,
                 {0, 1, 1, 1}, 1);
    }
    CGContextRestoreGState(c);
}

} // namespace trk
