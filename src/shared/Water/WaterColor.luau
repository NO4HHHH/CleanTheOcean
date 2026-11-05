--!native
--!optimize 2
--!strict
--[[
    Ocean colour: a gradient over HORIZONTAL distance from the world origin (the starter island),
    light turquoise near spawn fading to deep navy far out. Depth below the surface plays no part
    -- the user's rule is that water keeps its colour however deep it gets -- so the colour of a
    vertex is a function of (X, Z) and the crest foam factor only.

    The gradient stops from Data/Water are unpacked once into flat number arrays, and
    Components returns three numbers rather than a Color3 so the mesh can colour tens of
    thousands of vertices without allocating. Between stops the blend is smoothstepped so the
    bands never show a visible kink. Past the last stop the colour clamps.
]]

local Water = require(script.Parent.Parent.Data.Water)

local Sqrt = math.sqrt

local Stops = Water.Gradient
local StopCount = #Stops

local StopD = table.create(StopCount, 0) :: { number }
local StopR = table.create(StopCount, 0) :: { number }
local StopG = table.create(StopCount, 0) :: { number }
local StopB = table.create(StopCount, 0) :: { number }
local StopInv = table.create(StopCount, 0) :: { number } -- 1 / (D[i+1] - D[i])

for Index, Stop in Stops do
    StopD[Index] = Stop.Distance
    StopR[Index] = Stop.Color.R
    StopG[Index] = Stop.Color.G
    StopB[Index] = Stop.Color.B
end
for Index = 1, StopCount - 1 do
    local Span = StopD[Index + 1] - StopD[Index]
    StopInv[Index] = if Span > 0 then 1 / Span else 0
end

local FirstD = StopD[1] or 0
local LastD = StopD[StopCount] or 0

local FoamR = Water.FoamColor.R
local FoamG = Water.FoamColor.G
local FoamB = Water.FoamColor.B

local function Base(X: number, Z: number): (number, number, number)
    if StopCount == 0 then
        return 0, 0, 0
    end
    local Distance = Sqrt(X * X + Z * Z)
    if Distance <= FirstD then
        return StopR[1], StopG[1], StopB[1]
    elseif Distance >= LastD then
        return StopR[StopCount], StopG[StopCount], StopB[StopCount]
    end
    local Index = 1
    while StopD[Index + 1] < Distance do
        Index += 1
    end
    local T = (Distance - StopD[Index]) * StopInv[Index]
    T = T * T * (3 - 2 * T)
    local Next = Index + 1
    local R, G, B = StopR[Index], StopG[Index], StopB[Index]
    return R + (StopR[Next] - R) * T, G + (StopG[Next] - G) * T, B + (StopB[Next] - B) * T
end

local WaterColor = {}

function WaterColor.At(X: number, Z: number): Color3
    local R, G, B = Base(X, Z)
    return Color3.new(R, G, B)
end

-- The gradient colour at (X, Z) with no foam. Constant per world point, so callers can cache it.
WaterColor.Base = Base

-- Blends a cached base colour toward FoamColor by Crest (0..1, smoothstepped).
function WaterColor.MixFoam(R: number, G: number, B: number, Crest: number): (number, number, number)
    if Crest > 0 then
        local T = if Crest > 1 then 1 else Crest
        T = T * T * (3 - 2 * T)
        R += (FoamR - R) * T
        G += (FoamG - G) * T
        B += (FoamB - B) * T
    end
    return R, G, B
end

function WaterColor.Components(X: number, Z: number, Crest: number): (number, number, number)
    local R, G, B = Base(X, Z)
    if Crest > 0 then
        local T = if Crest > 1 then 1 else Crest
        T = T * T * (3 - 2 * T)
        R += (FoamR - R) * T
        G += (FoamG - G) * T
        B += (FoamB - B) * T
    end
    return R, G, B
end

return table.freeze(WaterColor)
