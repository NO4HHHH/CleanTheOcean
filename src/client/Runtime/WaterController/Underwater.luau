--!strict
--[[
    The underwater look: when the camera dips below the wave surface, tint, blur and fog the view
    in the colour of the water above it -- bright, clear turquoise in the shallows by the starter
    island, dark murky navy far out. A plain child module of WaterController (not Loader-walked):
    the controller calls Init once and Step(Dt) every frame.

    WHY IT IS SHAPED LIKE THIS
      * One WaveField.HeightAt per frame, with the full wave count, so the switch happens exactly
        where the near mesh draws the surface. SurfaceBias keeps it from flickering when the camera
        sits right on the waterline.
      * "Shallowness" is the same horizontal-distance gradient that colours the mesh: the tint is
        WaterColor.At(CamX, CamZ), and a depth factor D = distance / last Gradient stop lerps
        visibility and brightness between the shallow and deep tunings. Underwater always looks like
        the water seen from above at that spot.
      * The blend factor Alpha moves LINEARLY toward 0/1 at 1/FadeTime per second (frame-rate
        independent, and it lands on exactly 0, which an exponential ease never does), then is
        smoothstepped for display.
      * The effects (ColorCorrection, Blur) are created once and parented to Lighting only while
        Alpha > 0; nothing is recreated per frame, and the only per-frame allocations are the
        Color3 lerps.
      * Lighting belongs to the place, not to this module. While Alpha == 0 nothing is touched, so
        Studio edits to fog and Atmosphere keep working above water. The snapshot of
        FogStart/FogEnd/FogColor (and the Atmosphere's Density/Offset/Color/Decay/Haze) is taken at
        the moment the camera starts going under -- i.e. the latest above-water state, which is a
        strict improvement over snapshotting at Init -- and restored exactly when Alpha returns
        to 0.
      * An Atmosphere overrides the Fog* properties, so when one exists it is the thing driven
        (Density from visibility, Color/Decay = water colour, Haze/Offset flattened); otherwise the
        legacy Fog* is driven. Fog distance blends in reciprocal space (1/FogEnd is a density), so
        halfway through the fade the view is genuinely half-fogged instead of still ~clear.
        Lighting's Atmosphere is re-checked every active frame: one added mid-dive is snapshotted
        then and driven from that frame on; one removed (or moved out of Lighting) is dropped and
        the Fog* path takes over, so the look never silently stops matching what renders.
      * The sea is drawn to the horizon everywhere, so a camera below the surface is underwater
        anywhere (OceanSize is only the playable area).
      * Step restores Lighting itself if its update throws, because the controller disables the
        module on the first error and a half-applied dive would otherwise stick forever. Destroy
        does the same restore for teardown.

    Tuning: Data/Water.Underwater; any missing field falls back to the defaults below.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaveField = require(Shared:WaitForChild("Water"):WaitForChild("WaveField"))
local WaterColor = require(Shared:WaitForChild("Water"):WaitForChild("WaterColor"))

-- Defaults, used when Data/Water.Underwater (or one of its fields) is missing.
local DEFAULT_SHALLOW_VISIBILITY = 260 -- studs
local DEFAULT_DEEP_VISIBILITY = 55
local DEFAULT_SHALLOW_BRIGHTNESS = 0.06
local DEFAULT_DEEP_BRIGHTNESS = -0.18
local DEFAULT_TINT_STRENGTH = 0.55
local DEFAULT_BLUR_SIZE = 4
local DEFAULT_FADE_TIME = 0.25
local DEFAULT_SURFACE_BIAS = 0.3

-- Look constants not worth exposing as tuning.
local SHALLOW_SATURATION = 0.15
local DEEP_SATURATION = -0.25
local CONTRAST = 0.08
local FOG_START_FRACTION = 0.05 -- FogStart as a fraction of visibility
local ATMOSPHERE_DENSITY_SCALE = 45 -- Density = scale / visibility (220 studs ~ 0.2, 50 ~ 0.9)

local Tuning = ((Water :: any).Underwater or {}) :: { [string]: any }

local function Number(Name: string, Default: number): number
    local Value = Tuning[Name]
    return if type(Value) == "number" then Value else Default
end

local ShallowVisibility = Number("ShallowVisibility", DEFAULT_SHALLOW_VISIBILITY)
local DeepVisibility = Number("DeepVisibility", DEFAULT_DEEP_VISIBILITY)
local ShallowBrightness = Number("ShallowBrightness", DEFAULT_SHALLOW_BRIGHTNESS)
local DeepBrightness = Number("DeepBrightness", DEFAULT_DEEP_BRIGHTNESS)
local TintStrength = math.clamp(Number("TintStrength", DEFAULT_TINT_STRENGTH), 0, 1)
local BlurSize = Number("BlurSize", DEFAULT_BLUR_SIZE)
local FadeTime = Number("FadeTime", DEFAULT_FADE_TIME)
local SurfaceBias = Number("SurfaceBias", DEFAULT_SURFACE_BIAS)

-- A visibility of 0 would divide by zero in the fog/density maps.
ShallowVisibility = math.max(ShallowVisibility, 1)
DeepVisibility = math.max(DeepVisibility, 1)

-- Depth factor reaches 1 at the last gradient stop, where the mesh colour stops changing too.
local Gradient = Water.Gradient
local LastStop = Gradient[#Gradient]
local DeepDistance = if LastStop and LastStop.Distance > 0 then LastStop.Distance else 2500
local InvDeepDistance = 1 / DeepDistance

local White = Color3.new(1, 1, 1)

local Correction: ColorCorrectionEffect? = nil
local Blur: BlurEffect? = nil
local Alpha = 0
local Active = false -- effects parented and Lighting snapshotted

-- Snapshot of the above-water Lighting, taken when the camera starts going under.
local SnapFogStart = 0
local SnapFogEnd = 100000
local SnapFogColor = White
local SnapAtmosphere: Atmosphere? = nil
local SnapDensity = 0
local SnapOffset = 0
local SnapAtmosphereColor = White
local SnapDecay = White
local SnapHaze = 0

local function SnapshotAtmosphere(Atmosphere: Atmosphere?)
    SnapAtmosphere = Atmosphere
    if Atmosphere then
        SnapDensity = Atmosphere.Density
        SnapOffset = Atmosphere.Offset
        SnapAtmosphereColor = Atmosphere.Color
        SnapDecay = Atmosphere.Decay
        SnapHaze = Atmosphere.Haze
    end
end

local function Snapshot()
    SnapFogStart = Lighting.FogStart
    SnapFogEnd = Lighting.FogEnd
    SnapFogColor = Lighting.FogColor
    SnapshotAtmosphere(Lighting:FindFirstChildOfClass("Atmosphere"))
end

local function Restore()
    Lighting.FogStart = SnapFogStart
    Lighting.FogEnd = SnapFogEnd
    Lighting.FogColor = SnapFogColor
    local Atmosphere = SnapAtmosphere
    if Atmosphere and Atmosphere.Parent == Lighting then
        Atmosphere.Density = SnapDensity
        Atmosphere.Offset = SnapOffset
        Atmosphere.Color = SnapAtmosphereColor
        Atmosphere.Decay = SnapDecay
        Atmosphere.Haze = SnapHaze
    end
    SnapAtmosphere = nil
end

local function Activate()
    Active = true
    Snapshot()
    local CorrectionEffect = Correction :: ColorCorrectionEffect
    local BlurEffect = Blur :: BlurEffect
    CorrectionEffect.Enabled = true
    BlurEffect.Enabled = true
    CorrectionEffect.Parent = Lighting
    BlurEffect.Parent = Lighting
end

local function Deactivate()
    Active = false
    local CorrectionEffect = Correction :: ColorCorrectionEffect
    local BlurEffect = Blur :: BlurEffect
    CorrectionEffect.Enabled = false
    BlurEffect.Enabled = false
    CorrectionEffect.Parent = nil
    BlurEffect.Parent = nil
    Restore()
end

local Underwater = {}

function Underwater.Init()
    if Correction then
        return
    end
    local CorrectionEffect = Instance.new("ColorCorrectionEffect")
    CorrectionEffect.Name = "UnderwaterCorrection"
    CorrectionEffect.Enabled = false
    Correction = CorrectionEffect

    local BlurEffect = Instance.new("BlurEffect")
    BlurEffect.Name = "UnderwaterBlur"
    BlurEffect.Size = 0
    BlurEffect.Enabled = false
    Blur = BlurEffect
end

local function Update(CorrectionEffect: ColorCorrectionEffect, BlurEffect: BlurEffect, Dt: number)
    local Camera = workspace.CurrentCamera
    local CamX, CamY, CamZ = 0, 0, 0
    local Submerged = false
    if Camera then
        local Position = Camera.CFrame.Position
        CamX, CamY, CamZ = Position.X, Position.Y, Position.Z
        local SurfaceY = WaveField.HeightAt(CamX, CamZ, WaveField.Now())
        Submerged = CamY < SurfaceY - SurfaceBias
    end

    -- Linear, frame-rate independent fade that lands on exactly 0 or 1.
    local Target = if Submerged then 1 else 0
    if FadeTime <= 0 then
        Alpha = Target
    elseif Alpha < Target then
        Alpha = math.min(Target, Alpha + Dt / FadeTime)
    elseif Alpha > Target then
        Alpha = math.max(Target, Alpha - Dt / FadeTime)
    end

    if Alpha <= 0 then
        if Active then
            Deactivate()
        end
        return
    end
    if not Active then
        Activate()
    end

    local Blend = Alpha * Alpha * (3 - 2 * Alpha)
    local D = math.clamp(math.sqrt(CamX * CamX + CamZ * CamZ) * InvDeepDistance, 0, 1)
    local Visibility = ShallowVisibility + (DeepVisibility - ShallowVisibility) * D
    local Brightness = ShallowBrightness + (DeepBrightness - ShallowBrightness) * D
    local Saturation = SHALLOW_SATURATION + (DEEP_SATURATION - SHALLOW_SATURATION) * D
    local WaterTint = WaterColor.At(CamX, CamZ)

    CorrectionEffect.TintColor = White:Lerp(WaterTint, TintStrength * Blend)
    CorrectionEffect.Brightness = Brightness * Blend
    CorrectionEffect.Contrast = CONTRAST * Blend
    CorrectionEffect.Saturation = Saturation * Blend
    BlurEffect.Size = BlurSize * Blend

    -- Track the Atmosphere Lighting actually renders with: adopt one added mid-dive (snapshotting
    -- its above-water values now), drop one that was removed -- after putting its snapshot back,
    -- so it is clean if it is ever re-parented into Lighting.
    local Current = Lighting:FindFirstChildOfClass("Atmosphere")
    local Previous = SnapAtmosphere
    if Current ~= Previous then
        if Previous then
            Previous.Density = SnapDensity
            Previous.Offset = SnapOffset
            Previous.Color = SnapAtmosphereColor
            Previous.Decay = SnapDecay
            Previous.Haze = SnapHaze
        end
        SnapshotAtmosphere(Current)
    end

    local Atmosphere = SnapAtmosphere
    if Atmosphere then
        local TargetDensity = math.clamp(ATMOSPHERE_DENSITY_SCALE / Visibility, 0, 1)
        Atmosphere.Density = SnapDensity + (TargetDensity - SnapDensity) * Blend
        Atmosphere.Offset = SnapOffset * (1 - Blend)
        Atmosphere.Haze = SnapHaze * (1 - Blend)
        Atmosphere.Color = SnapAtmosphereColor:Lerp(WaterTint, Blend)
        Atmosphere.Decay = SnapDecay:Lerp(WaterTint, Blend)
    else
        -- Reciprocal blend: 1/FogEnd behaves like a fog density.
        local InvEnd = 1 / math.max(SnapFogEnd, 1)
        local FogEnd = 1 / (InvEnd + (1 / Visibility - InvEnd) * Blend)
        local FogStart = SnapFogStart + (Visibility * FOG_START_FRACTION - SnapFogStart) * Blend
        Lighting.FogEnd = FogEnd
        Lighting.FogStart = math.min(FogStart, FogEnd)
        Lighting.FogColor = SnapFogColor:Lerp(WaterTint, Blend)
    end
end

function Underwater.Step(Dt: number)
    local CorrectionEffect = Correction
    local BlurEffect = Blur
    if not CorrectionEffect or not BlurEffect then
        return
    end
    local Ok, Error = (pcall :: any)(Update, CorrectionEffect, BlurEffect, Dt)
    if not Ok then
        -- The controller disables this module on error; never leave Lighting half-dived.
        Alpha = 0
        if Active then
            pcall(Deactivate)
        end
        error(Error, 0)
    end
end

-- Restores the above-water Lighting and destroys the effects. Init may be called again after.
function Underwater.Destroy()
    if Active then
        Deactivate()
    end
    Alpha = 0
    if Correction then
        Correction:Destroy()
        Correction = nil
    end
    if Blur then
        Blur:Destroy()
        Blur = nil
    end
end

return table.freeze(Underwater)
