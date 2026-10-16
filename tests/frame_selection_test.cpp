#include "emoteframeselect.h"
#include <cassert>
#include <string>
using namespace emoteplayer;

struct Frame { double time; bool hasContent; std::string src; };
int main()
{
    Frame visible{0, true, "src/parts/logo"}, hidden{144, false, ""}, end{241, false, ""};
    std::vector<Frame*> frames{&visible, &hidden, &end};
    assert(selectEmoteNodeFrames(frames, -1, false).first == nullptr);
    assert(selectEmoteNodeFrames(frames, 143, false).first == &visible);
    assert(selectEmoteNodeFrames(frames, 143, false).second == nullptr);
    // The final delimiter must not resurrect the icon hidden at frame 144.
    for (double tick : {144, 240, 241, 242, 360})
        assert(!selectEmoteNodeFrames(frames, tick, false).first->hasContent);

    Frame a{0, true, "src/parts/a"}, b{30, true, "src/parts/b"};
    frames = {&a, &b, &end};
    auto interpolation = selectEmoteNodeFrames(frames, 15, false);
    assert(interpolation.first == &a && interpolation.second == &b);
    assert(selectEmoteNodeFrames(frames, 241, false).first == &end);
    assert(selectEmoteNodeFrames(frames, 242, false).first == &end);

    // Missing-src type-1 shapes, and explicit shape sources, keep hit geometry.
    Frame shape{0, true, "layout"}; frames = {&shape, &end};
    assert(selectEmoteNodeFrames(frames, 360, true).first == &shape);
    // The shape's non-drawing parent must retain the same transform as well.
    for (const char* src : {"layout", "clip", "blank/32:32:16:16", "src/blank/32:32:16:16"})
    {
        shape.src = src;
        assert(selectEmoteNodeFrames(frames, 360, false).first == &shape);
    }
    for (const char* src : {"shape/rect", "src/shape/point"})
    {
        shape.src = src;
        assert(selectEmoteNodeFrames(frames, 360, false).first == &shape);
    }
    frames = {&shape, &hidden, &end};
    assert(!selectEmoteNodeFrames(frames, 200, true).first->hasContent);
    assert(selectEmoteNodeFrames(frames, 360, true).first == &shape);
    assert(selectEmoteNodeFrames<Frame>({}, 0, false).first == nullptr);
}
