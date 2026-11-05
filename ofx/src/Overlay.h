#pragma once
#include <CoreGraphics/CoreGraphics.h>
#include <string>
#include "TouchData.h"

namespace trk {

struct RGBA { double r, g, b, a; };

struct OverlayOptions {
    // Fingers (and pointer clicks)
    bool showFingers = true;
    int fingerStyle = 0;          // 0 filled, 1 ring, 2 filled + ring
    double fingerSize = 0.045;    // diameter, fraction of screen height
    RGBA fingerColor{1, 1, 1, 0.55};
    bool tapRipple = true;
    double fingerTrailMs = 0;
    double fadeMs = 250;
    double minTouchMs = 0;        // hide touches shorter than this (curate accidental brushes)
    bool shadow = true;           // soft drop shadow so white touches read on light UIs

    // Pencil
    bool showPencil = true;
    double pencilSize = 0.012;    // stroke width at full pressure, fraction of screen height
    RGBA pencilColor{1, 0.27, 0.23, 0.9};
    double pencilTrailMs = 450;
    bool pressureWidth = true;
    bool showPencilDot = true;

    // Hover (Pencil hover & pointer)
    bool showHover = true;
    bool showPointer = true;

    // Keyboard
    bool showKeys = true;
    int keyMode = 0;              // 0 all keys, 1 shortcuts only (⌘⌃⌥ combos), 2 modifiers only
    int keyPosition = 0;          // 0 bottom center, 1 bottom left, 2 bottom right, 3 top center
    double keySize = 0.05;        // cap height, fraction of frame height
    double keyLingerMs = 600;
    double keyBgOpacity = 0.75;
    std::string ignoreKeys;       // comma separated labels, e.g. "space, delete"

    bool debug = false;
};

/// Draw the overlay for event time `t` (seconds on the TouchRecordKit timeline).
/// `frame` is the full output frame in the context's (y-up) coordinates.
void drawOverlay(CGContextRef ctx, const TouchData& data, double t, CGRect frame,
                 const OverlayOptions& o, const std::string& debugText);

/// Where the iPad picture sits inside `frame` (aspect fit of the video, then of the current screen).
CGRect contentRect(const TouchData& data, double t, CGRect frame);

} // namespace trk
