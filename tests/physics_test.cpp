#include "emotephysics.h"
#include <cassert>
#include <iostream>
#include <map>
#include <limits>
using namespace emoteplayer;
namespace emoteplayer { bustControl::~bustControl() = default; uniControl::~uniControl() = default; }

struct Test
{
    bustControl bust;
    uniControl hair;
    EmotePhysics engine;
    std::map<std::string, double> values;
    Test()
    {
        // Coefficients and equilibrium state from this game's front hair/bust.
        bust.baseLayer = "bust"; bust.var_lr = "bust_x"; bust.var_ud = "bust_y";
        bust.gravity = .1; bust.spring = .03125; bust.friction = .06;
        bust.param.ofs = bust.gravity / bust.spring; bust.param.p.y = bust.param.ofs;
        hair.baseLayer = "hair"; hair.var_lr = "hair_x"; hair.var_lrm = "hair_tip"; hair.var_ud = "hair_y";
        hair.b_rate = .0037109374534; hair.gravity = .6; hair.friction_x = .046875; hair.friction_y = .09375;
        hair.bend_vol = 3; hair.bend_spd = .2; hair.ofs = -hair.gravity / hair.b_rate;
        for (int i = 0; i < 2; ++i)
        {
            uniSegment s; s.bp.y = i ? 112 : 64; s.p.y = s.bp.y - hair.ofs;
            s.length = i ? 48 : 64; s.scale_x = i ? .25 : .75;
            hair.segments.push_back(s);
        }
        engine.reset({&bust}, {&hair}, {});
    }
    void step(double dt, double x = 0, double y = 0)
    {
        engine.beginAnchors(); engine.setAnchor("bust",{x,y}); engine.setAnchor("hair",{x,y});
        engine.update(dt,[&](const std::string& key, double v) { assert(std::isfinite(v)); values[key]=v; });
    }
};
int main()
{
    // A boundary pose plus breathing used to produce a negative tick and
    // intermittently drop the head's parent transform in multiple models.
    for (float offset : {-3.75f, -0.001f, 0.0f, 0.001f, 3.75f})
    {
        const float low = emoteParameterTick(-30 + offset, -30, 30, 60);
        const float high = emoteParameterTick(30 + offset, -30, 30, 60);
        assert(low >= 0 && low <= 60 && high >= 0 && high <= 60);
        if (offset <= 0) assert(low == 0);
        if (offset >= 0) assert(high == 60);
    }
    assert(emoteParameterTick(-15, -30, 30, 60) == 15);
    assert(emoteParameterTick(2.5f, 0, 5, 60) == 30);
    assert(emoteParameterTick(-40, 30, -30, 60) == 60);
    assert(emoteParameterTick(5, 5, 5, 60) == 0);
    assert(emoteParameterTick(std::numeric_limits<float>::quiet_NaN(), -30, 30, 60) == 0);

    EmoteTween tween; tween.set(10, 20, 5, 10);
    assert(tween.value(0)==10 && tween.value(10)==15 && tween.value(15)==20);
    tween.set(10,20,5,10,1); assert(tween.value(10)==12.5);
    tween.set(10,20,5,10,-1); assert(std::abs(tween.value(10)-17.071067811865)<1e-9);
    // Original player: progress(500 ms) advances 30 frames of a 1000-frame
    // variable transition. These values include its easing convention.
    tween.set(0,30,0,1000,-1); assert(std::abs(tween.value(30)-5.1961522102356)<1e-6);
    tween.set(0,30,0,1000,0); assert(std::abs(tween.value(30)-.900000035762787)<1e-6);
    tween.set(0,30,0,1000,1); assert(std::abs(tween.value(30)-.0270000007003546)<1e-6);
    Test golden;
    golden.bust.scale_y=2;
    golden.bust.param.ofs=3.1996304988861084;
    golden.bust.param.p.y=3.2002079486846924;
    golden.bust.param.pv.y=9.272695024264976e-6;
    golden.engine.reset({&golden.bust}, {}, {});
    golden.engine.bustScale=3;
    golden.step(1);
    // Captured from the original DLL, using the same saved PSB state/scales.
    assert(std::abs(golden.values["bust_y"]-13.3484764099121)<.001);
    Test stationary;
    for (int i=0;i<600;++i) stationary.step(1);
    assert(std::abs(stationary.values["bust_x"])<1e-9 && std::abs(stationary.values["bust_y"])<1e-9);
    double lo=1e9,hi=-1e9;
    for(int i=0;i<240;++i) { stationary.step(1); lo=std::min(lo,stationary.values["hair_x"]); hi=std::max(hi,stationary.values["hair_x"]); }
    assert(hi-lo<1e-8); // Motion excites sway; resting anchors do not manufacture it.
    Test moved; moved.step(1); moved.step(1,20);
    assert(moved.values["bust_x"] < -10);
    for(int i=0;i<1200;++i) moved.step(1,20);
    assert(std::abs(moved.values["bust_x"]) < 1e-6);
    Test slow,fast;
    slow.engine.hairForce.x=fast.engine.hairForce.x=.1;
    for(int i=0;i<300;++i) slow.step(2);
    for(int i=0;i<1200;++i) fast.step(.5);
    for(auto& v:slow.values) assert(std::abs(v.second-fast.values[v.first])<1e-9);
    Test zero,scaled;
    zero.engine.bustScale=zero.engine.hairScale=0;
    scaled.engine.bustScale=3;
    zero.step(1);scaled.step(1);zero.step(1,20);scaled.step(1,20);
    assert(zero.values["bust_x"]==0 && zero.values["hair_x"]==0);
    Test reference;reference.step(1);reference.step(1,20);
    assert(std::abs(scaled.values["bust_x"])>std::abs(reference.values["bust_x"]));
    assert(std::abs(scaled.values["bust_x"])<40);
    assert(std::abs(scaled.values["bust_x"])<3*std::abs(reference.values["bust_x"]));
    Test wind;
    wind.engine.startWind(-5,50,1,2,3);
    double peak=0;
    for(int i=0;i<600;++i) { wind.step(1);peak=std::max(peak,std::abs(wind.values["hair_x"])); }
    assert(peak>1);
    wind.engine.stopWind();
    for(int i=0;i<1200;++i) wind.step(1);
    assert(std::abs(wind.values["hair_x"])<1);
    Test isolated;
    assert(isolated.values.empty()); isolated.step(1);
    assert(std::abs(isolated.values["bust_x"])<1e-9);
    assert(isolated.bust.param.p.x==0 && isolated.hair.segments[0].p.x==0);
    Test parts;
    parts.engine.reset({}, {}, {&parts.hair}); parts.engine.partsForce.x=.1;
    for(int i=0;i<100;++i) parts.step(1);
    assert(std::abs(parts.values["hair_x"])>1);
    Test rotated; rotated.engine.rotation=1.5707963267948966;
    for(int i=0;i<300;++i) rotated.step(1);
    assert(rotated.values["bust_x"]>1);
    isolated.step(1000000,200); isolated.step(std::numeric_limits<double>::infinity());
    EmotePhysics missing;missing.reset({&isolated.bust},{},{});
    bool wrote=false;missing.update(1,[&](auto&,double){wrote=true;});assert(!wrote);
    std::cout << "Physics: native golden value, rest, inertia/recovery, 30/120 Hz, scales/limits, wind/stop, independent state, missing anchors and pause passed\n";
}
