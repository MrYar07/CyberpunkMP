#pragma once

struct InterpolationComponent
{
    struct Timepoint
    {
        glm::vec3 Position{};
        glm::vec3 Rotation{};
        float Velocity{0.f};
        uint64_t Tick{0};
    };

    List<Timepoint> TimePoints{};

    // The network sample BEHIND render time. Interpolation runs between this and the first
    // sample ahead of it, which keeps movement at a constant speed across each segment. It
    // used to be overwritten every frame with the pose just drawn, so each frame covered a
    // fraction of the REMAINING distance - an acceleration into every sample that read as
    // other players teleporting. Night City Online 124ce33.
    Timepoint PreviousFrame{};
    bool HasPrevious{false};

    // Render time as of the last frame: the vehicle path needs a frame delta, which used to
    // fall out of PreviousFrame while that was rewritten every frame.
    int64_t LastRenderTick{0};

    // This remote's arrival jitter (RFC 3550 smoothed transit variation). Transit is the
    // local clock at arrival minus the sample's tick; only its change between samples is
    // used, so the clock offset cancels. InterpolateEntity widens only THIS remote's buffer
    // by a bounded margin sized from it. Night City Online 2ccb708.
    int64_t LastTransit{0};
    float ArrivalJitter{0.f};
    bool HasTransit{false};
};
