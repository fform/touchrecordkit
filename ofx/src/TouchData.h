#pragma once
#include <memory>
#include <string>
#include <vector>

namespace trk {

enum class Kind { Finger, Pencil, Pointer };

struct Sample {
    double t;
    float x, y;          // normalized screen coords, origin top-left
    float force;         // normalized 0..1 (0 if unknown)
    float altitude, azimuth;
};

struct Stroke {
    int id = 0;
    Kind kind = Kind::Finger;
    bool hover = false;
    bool ended = false;      // got a real ended/cancelled phase
    double start = 0, end = 0;
    std::vector<Sample> samples;
};

struct KeyPress {
    double down = 0, up = 0;
    std::string label;                 // "S", "cmd", "shift", "return", ...
    bool isModifier = false;
    std::vector<std::string> modifiers; // modifiers held when pressed
};

struct ScreenChange { double t; double w, h; };

struct TouchData {
    double videoW = 0, videoH = 0, fps = 0;
    double duration = 0;
    std::string device, app;
    std::vector<Stroke> strokes;        // sorted by start
    std::vector<KeyPress> keys;         // sorted by down
    std::vector<ScreenChange> screens;  // sorted by t

    /// Screen aspect (w/h) at time t, falls back to video aspect.
    double screenAspect(double t) const;
};

/// Loads (and caches by path + modification time) a TouchRecordKit .touches.json file. Thread-safe.
std::shared_ptr<const TouchData> loadTouchData(const std::string& path, std::string* error);

bool isModifierLabel(const std::string& label);

} // namespace trk
