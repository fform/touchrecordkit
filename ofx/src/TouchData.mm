#import <Foundation/Foundation.h>
#include "TouchData.h"
#include <algorithm>
#include <cmath>
#include <map>
#include <mutex>
#include <sys/stat.h>

namespace trk {

bool isModifierLabel(const std::string& l) {
    return l == "cmd" || l == "shift" || l == "option" || l == "control" || l == "capslock" || l == "fn";
}

double TouchData::screenAspect(double t) const {
    double a = (videoH > 0) ? videoW / videoH : 4.0 / 3.0;
    for (const auto& s : screens) {
        if (s.t > t) break;
        if (s.h > 0) a = s.w / s.h;
    }
    return a;
}

static double num(NSDictionary* d, NSString* k, double def = 0) {
    id v = d[k];
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : def;
}
static std::string str(NSDictionary* d, NSString* k) {
    id v = d[k];
    return [v isKindOfClass:[NSString class]] ? std::string([v UTF8String]) : std::string();
}

static std::shared_ptr<TouchData> parse(NSData* json, std::string* error) {
    NSError* err = nil;
    NSDictionary* root = [NSJSONSerialization JSONObjectWithData:json options:0 error:&err];
    if (![root isKindOfClass:[NSDictionary class]]) {
        if (error) *error = err ? err.localizedDescription.UTF8String : "Not a JSON object";
        return nullptr;
    }
    auto data = std::make_shared<TouchData>();
    NSDictionary* video = root[@"video"];
    if ([video isKindOfClass:[NSDictionary class]]) {
        data->videoW = num(video, @"width");
        data->videoH = num(video, @"height");
        data->fps = num(video, @"fps");
    }
    NSDictionary* device = root[@"device"];
    if ([device isKindOfClass:[NSDictionary class]]) {
        data->device = str(device, @"device");
        data->app = str(device, @"app");
        NSDictionary* scr = device[@"screen"];
        if ([scr isKindOfClass:[NSDictionary class]])
            data->screens.push_back({-1e9, num(scr, @"w"), num(scr, @"h")});
    }

    NSArray* events = root[@"events"];
    if (![events isKindOfClass:[NSArray class]]) events = @[];
    // Network delivery can reorder slightly — sort by time first.
    events = [events sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
        double ta = num(a, @"t"), tb = num(b, @"t");
        return ta < tb ? NSOrderedAscending : (ta > tb ? NSOrderedDescending : NSOrderedSame);
    }];

    std::map<std::pair<int, bool>, size_t> openStrokes; // (id, hover) -> stroke index
    std::map<std::string, size_t> openKeys;              // label -> key index

    for (NSDictionary* e in events) {
        if (![e isKindOfClass:[NSDictionary class]]) continue;
        std::string type = str(e, @"type");
        double t = num(e, @"t");
        data->duration = std::max(data->duration, t);

        if (type == "touch" || type == "hover") {
            bool hover = type == "hover";
            int id = (int)num(e, @"id");
            std::string phase = str(e, @"phase"), kind = str(e, @"kind");
            double maxForce = num(e, @"maxForce", 0);
            Sample s{t, (float)num(e, @"x"), (float)num(e, @"y"),
                     (float)(maxForce > 0 ? num(e, @"force") / maxForce : 0),
                     (float)num(e, @"altitude", M_PI_2), (float)num(e, @"azimuth")};
            auto key = std::make_pair(id, hover);
            auto it = openStrokes.find(key);
            if (phase == "began" || it == openStrokes.end()) {
                if (it != openStrokes.end()) openStrokes.erase(it);
                Stroke st;
                st.id = id; st.hover = hover; st.start = t; st.end = t;
                st.kind = kind == "pencil" ? Kind::Pencil : kind == "finger" ? Kind::Finger : Kind::Pointer;
                data->strokes.push_back(std::move(st));
                it = openStrokes.emplace(key, data->strokes.size() - 1).first;
            }
            Stroke& st = data->strokes[it->second];
            st.samples.push_back(s);
            st.end = t;
            if (phase == "ended" || phase == "cancelled") {
                st.ended = true;
                openStrokes.erase(it);
            }
        } else if (type == "key") {
            std::string label = str(e, @"label");
            if (label.empty()) continue;
            if (str(e, @"phase") == "down") {
                KeyPress k;
                k.down = t; k.up = INFINITY; k.label = label; k.isModifier = isModifierLabel(label);
                NSArray* mods = e[@"modifiers"];
                if ([mods isKindOfClass:[NSArray class]])
                    for (NSString* m in mods) if ([m isKindOfClass:[NSString class]]) k.modifiers.push_back(m.UTF8String);
                data->keys.push_back(k);
                openKeys[label] = data->keys.size() - 1;
            } else {
                auto it = openKeys.find(label);
                if (it != openKeys.end()) { data->keys[it->second].up = t; openKeys.erase(it); }
            }
        } else if (type == "screen") {
            data->screens.push_back({t, num(e, @"w"), num(e, @"h")});
        } else if (type == "hello") {
            NSDictionary* scr = e[@"screen"];
            if ([scr isKindOfClass:[NSDictionary class]]) data->screens.push_back({t, num(scr, @"w"), num(scr, @"h")});
            if (data->app.empty()) data->app = str(e, @"app");
        }
    }
    for (auto& k : data->keys) if (std::isinf(k.up)) k.up = data->duration;
    std::sort(data->strokes.begin(), data->strokes.end(), [](auto& a, auto& b) { return a.start < b.start; });
    return data;
}

std::shared_ptr<const TouchData> loadTouchData(const std::string& path, std::string* error) {
    struct Entry { time_t mtime; off_t size; std::shared_ptr<const TouchData> data; };
    static std::mutex mutex;
    static std::map<std::string, Entry> cache;

    if (path.empty()) { if (error) *error = "No file"; return nullptr; }
    struct stat st;
    if (stat(path.c_str(), &st) != 0) { if (error) *error = "File not found"; return nullptr; }

    std::lock_guard<std::mutex> lock(mutex);
    auto it = cache.find(path);
    if (it != cache.end() && it->second.mtime == st.st_mtime && it->second.size == st.st_size)
        return it->second.data;
    @autoreleasepool {
        NSData* json = [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:path.c_str()]];
        if (!json) { if (error) *error = "Could not read file"; return nullptr; }
        auto data = parse(json, error);
        if (data) cache[path] = {st.st_mtime, st.st_size, data};
        return data;
    }
}

} // namespace trk
