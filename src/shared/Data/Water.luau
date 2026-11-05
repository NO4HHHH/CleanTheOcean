--!strict
--[[
    The ocean registry: every tuning number the wave maths, the chunked mesh and the buoyancy
    solver share. One table, read by server and client alike, so the crate a player sees bobbing
    rides exactly the swell the mesh draws.

    WAVES (Gerstner / trochoidal). Each wave i moves the calm grid point P = (X, Z) to
        X' = X + Dx * (S_i / k_i) * cos(theta),   Z' = Z + Dz * (S_i / k_i) * cos(theta)
        Y  = SeaLevel + A_i * sin(theta),         theta = k_i * (D . P) - omega_i * t + phase_i
    with k = 2*pi / Wavelength and deep-water dispersion omega = sqrt(Gravity * k).
    `Steepness` is the wave's share of the loop limit: the surface folds over itself (ugly loops)
    once the steepness values of waves in phase sum past 1, so the SUM over all waves is kept
    below 1 (here 0.82). Higher steepness = sharper crests and flatter troughs, the stylised
    "Sea of Thieves" profile; the long swells carry most of it.

    GRAVITY is in studs/s^2 but tuned for the look, not physics: 30 gives the 520-stud swell a
    ~9.3 s period (slow, heavy rolling) and the 38-stud chop ~2.5 s (busy surface detail). Real
    gravity (~35 studs/s^2 at 1 stud = 0.28 m) would be nearly the same; 196.2 makes swells
    look like a bathtub.

    ORDER MATTERS: waves are sorted largest amplitude first, because `WaveCount` arguments
    (physics, far LODs) take only the first N. Physics uses `PhysicsWaveCount` -- the two swells
    and the two biggest chops -- since the tiny chop barely moves a crate but costs as much.

    COLOUR depends on horizontal distance from the world origin (the starter island) only:
    light turquoise in the shallows-look near spawn, deep navy far out, never darker with depth.
    Foam (crest factor from the Jacobian of the displacement) lightens on top.
]]

export type WaveDef = {
    Angle: number,
    Wavelength: number,
    Amplitude: number,
    Steepness: number,
}

export type LodDef = {
    MaxRing: number,
    Resolution: number,
    WaveCount: number,
    UpdateEvery: number,
}

export type GradientStop = {
    Distance: number,
    Color: Color3,
}

export type WaterDef = {
    SeaLevel: number,
    Gravity: number,
    Waves: { WaveDef },
    PhysicsWaveCount: number,
    Chunk: {
        Size: number,
        Lods: { LodDef },
        ViewRings: number,
    },
    Gradient: { GradientStop },
    FoamColor: Color3,
    FoamThreshold: number,
    Transparency: number,
    Material: string,
    Buoyancy: {
        DefaultDensity: number,
        WaterDrag: number,
        AngularDrag: number,
        SampleGrid: number,
        MaxSimDistance: number,
        Tag: string,
    },
}

local Water: WaterDef = {
    SeaLevel = 0,
    Gravity = 30,

    -- Largest amplitude first. Steepness sum = 0.82 (< 1: no loops anywhere).
    Waves = {
        { Angle = 20, Wavelength = 520, Amplitude = 6.5, Steepness = 0.22 }, -- primary swell
        { Angle = -25, Wavelength = 340, Amplitude = 4.0, Steepness = 0.18 }, -- cross swell
        { Angle = 65, Wavelength = 140, Amplitude = 1.6, Steepness = 0.14 }, -- long chop
        { Angle = -55, Wavelength = 95, Amplitude = 1.0, Steepness = 0.12 }, -- chop
        { Angle = 115, Wavelength = 60, Amplitude = 0.55, Steepness = 0.09 }, -- short chop
        { Angle = 5, Wavelength = 38, Amplitude = 0.3, Steepness = 0.07 }, -- ripple
    },
    PhysicsWaveCount = 4,

    Chunk = {
        Size = 192,
        -- Ring 0..1: 6-stud quads (resolves the 38-stud ripple); rings 2..3: 12 studs;
        -- rings 4..6: 24 studs, swells only (far away chop is sub-pixel anyway).
        Lods = {
            { MaxRing = 1, Resolution = 32, WaveCount = 6, UpdateEvery = 1 },
            { MaxRing = 3, Resolution = 16, WaveCount = 4, UpdateEvery = 2 },
            { MaxRing = 6, Resolution = 8, WaveCount = 2, UpdateEvery = 4 },
        },
        ViewRings = 6,
    },

    Gradient = {
        { Distance = 0, Color = Color3.new(0.30, 0.86, 0.82) }, -- starter island turquoise
        { Distance = 250, Color = Color3.new(0.20, 0.76, 0.79) },
        { Distance = 700, Color = Color3.new(0.08, 0.55, 0.72) }, -- open-water teal-blue
        { Distance = 1500, Color = Color3.new(0.04, 0.32, 0.54) },
        { Distance = 2500, Color = Color3.new(0.02, 0.16, 0.36) }, -- deep ocean
    },
    FoamColor = Color3.new(0.93, 0.98, 1.0),
    FoamThreshold = 0.3,
    Transparency = 0.08,
    -- SmoothPlastic shows vertex colours faithfully; Glass tints and darkens them.
    Material = "SmoothPlastic",

    Buoyancy = {
        DefaultDensity = 0.45,
        WaterDrag = 1.2,
        AngularDrag = 1.5,
        SampleGrid = 2,
        MaxSimDistance = 600,
        Tag = "Buoyant",
    },
}

for _, Wave in Water.Waves do
    table.freeze(Wave)
end
for _, Lod in Water.Chunk.Lods do
    table.freeze(Lod)
end
for _, Stop in Water.Gradient do
    table.freeze(Stop)
end
table.freeze(Water.Waves)
table.freeze(Water.Chunk.Lods)
table.freeze(Water.Chunk)
table.freeze(Water.Gradient)
table.freeze(Water.Buoyancy)

return table.freeze(Water)
