--!strict
--[[
    The ocean registry: every tuning number the wave maths, the 3x3 chunk renderer, the far plane,
    the underwater look and the buoyancy solver share. One table, read by server and client alike, so the crate a player sees bobbing
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
    (physics) take only the first N. Physics uses `PhysicsWaveCount` -- the two swells
    and the two biggest chops -- since the tiny chop barely moves a crate but costs as much.

    COLOUR depends on horizontal distance from the world origin (the starter island) only:
    light turquoise in the shallows-look near spawn, deep navy far out, never darker with depth.
    Foam (crest factor from the Jacobian of the displacement) lightens on top.

    THE SEA GOES TO THE HORIZON. Three layers, all following the camera's cell:
      * the 3x3 wave chunks (Chunk.Size cells around the camera) -- the only part that waves;
      * the far ring (FarPlane): one flat, vertex-coloured EditableMesh, (2 * FarPlane.Cells + 1)
        cells square with the 3x3 cut out, so the gradient stays smooth around you;
      * the horizon tiles (Horizon): plain flat Parts, one colour each, Horizon.Rings rings of
        far-ring-sized tiles beyond it. Plain Parts because no part (MeshPart included) may be
        larger than 2048 studs a side, and EditableMeshes are scarce, while flat Parts are cheap.
    All three sit exactly at SeaLevel and only meet edge to edge, never overlap. OceanSize is the
    PLAYABLE sea (gameplay bounds), not where the water stops drawing.
    The waves fade out between Fade.Inner and Fade.Outer studs (horizontal, from the camera).
    Fade.Outer must not exceed Chunk.Size: the camera is always inside the centre cell, so
    Chunk.Size is the closest the 3x3 border can ever be, and the waves must be fully flat there
    or the border would show a step.

    BUDGETS (per EditableMesh: 60,000 vertices / 20,000 triangles). A chunk of Resolution R has
    (R+1)^2 + 3 vertices and 2R^2 (top) + 2R^2 (underside) + 1 triangles: 4,228 / 16,385 at R = 64.
    The far ring is ((2C+1)*S + 1)^2 vertices for C = FarPlane.Cells, S = FarPlane.Subdivide:
    841 vertices / 1,280 triangles at C = 3, S = 4. Ten EditableMeshes in total.
]]

export type WaveDef = {
    Angle: number,
    Wavelength: number,
    Amplitude: number,
    Steepness: number,
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
    OceanSize: number,
    Chunk: {
        Size: number,
        Resolution: number,
        UpdateHz: number,
    },
    Fade: {
        Inner: number,
        Outer: number,
    },
    FarPlane: {
        Cells: number,
        Subdivide: number,
    },
    Horizon: {
        Rings: number,
    },
    PlayerFloat: {
        RootOffset: number,
        Frequency: number,
        DampingRatio: number,
        Drag: number,
        MaxAccel: number,
    },
    Underwater: {
        ShallowVisibility: number,
        DeepVisibility: number,
        ShallowBrightness: number,
        DeepBrightness: number,
        TintStrength: number,
        BlurSize: number,
        FadeTime: number,
        SurfaceBias: number,
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

    -- Square, centred on the origin (the starter island).
    OceanSize = 20000,

    Chunk = {
        -- 256 studs / 64 quads = 4-stud quads: resolves the 38-stud ripple with ~10 quads.
        Size = 256,
        Resolution = 64,
        -- Wave updates per second (all nine chunks together, one shared Time per update).
        UpdateHz = 60,
    },

    -- Wave fade, studs from the camera (horizontal). Outer <= Chunk.Size (see header).
    Fade = {
        Inner = 140,
        Outer = 240,
    },

    FarPlane = {
        -- Ring radius in cells: 3 -> a 7x7-cell (1,792-stud) square around the camera's cell,
        -- minus the 3x3 the chunks cover. (2 * Cells + 1) * Chunk.Size must stay <= 2048.
        Cells = 3,
        -- Quads per cell side (64-stud quads): enough for a smooth colour gradient.
        Subdivide = 4,
    },

    Horizon = {
        -- Rings of far-ring-sized flat tiles beyond the far ring: 5 -> the sea reaches
        -- ~9,900 studs from the camera in every direction (past where Roblox draws detail).
        Rings = 5,
    },

    -- The local character floats when it is in the water and not standing on ground
    -- (WaterController/PlayerFloat). A spring holds the HumanoidRootPart at RootOffset studs
    -- relative to the wave surface under it, so the player bobs with the same swell the mesh
    -- draws and the server floats crates on.
    PlayerFloat = {
        RootOffset = -1.2, -- studs: root just under the surface, head and shoulders above it
        Frequency = 3.5, -- rad/s: how stiffly the body follows the swell
        DampingRatio = 0.75, -- < 1 bobs a little before settling
        Drag = 1.5, -- 1/s: horizontal water resistance
        MaxAccel = 3, -- in units of workspace.Gravity: caps the pull when falling in from height
    },

    -- Read by WaterController/Underwater (the look when the camera dips below the surface).
    Underwater = {
        ShallowVisibility = 260, -- studs, near the starter island
        DeepVisibility = 55, -- studs, past the last Gradient stop
        ShallowBrightness = 0.06, -- ColorCorrection brightness offsets (negative = darker)
        DeepBrightness = -0.18,
        TintStrength = 0.55, -- 0..1
        BlurSize = 4,
        FadeTime = 0.25, -- seconds
        SurfaceBias = 0.3, -- studs: underwater when CameraY < HeightAt - SurfaceBias
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
    -- Opaque: a see-through sea showed the chunk edges and costs sorting on ten big meshes.
    Transparency = 0,
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
for _, Stop in Water.Gradient do
    table.freeze(Stop)
end
table.freeze(Water.Waves)
table.freeze(Water.Chunk)
table.freeze(Water.Fade)
table.freeze(Water.FarPlane)
table.freeze(Water.Horizon)
table.freeze(Water.PlayerFloat)
table.freeze(Water.Underwater)
table.freeze(Water.Gradient)
table.freeze(Water.Buoyancy)

return table.freeze(Water)
