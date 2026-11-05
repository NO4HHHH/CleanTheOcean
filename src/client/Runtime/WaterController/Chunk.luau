--!native
--!optimize 2
--!strict
--[[
    The per-frame hot path: re-displace one chunk's grid with the shared wave field and push the
    result to its EditableMesh in one batched write.

    WHY THIS SHAPE.
    - Displacement goes into flat module-level scratch arrays (SX/SY/SZ/SC), reused by every
      chunk, so the loop allocates nothing: WaveField.Displace returns four numbers, Vector3 is
      a value type in Luau, and the Positions array is the chunk's own, filled in place.
    - One BatchSetValues per chunk per update (and one more for colours on colour frames)
      replaces thousands of SetPosition calls -- the whole point of the batching API.
    - Colours are refreshed on a stride (the controller decides), because Color3 is a heap
      object. Colours are quantised to the 8 bits per channel the GPU stores anyway and looked
      up in a cache, so in steady state recolouring allocates nothing either.

    LOD SEAMS. Neighbouring chunks of different LOD differ in grid resolution and in how many
    waves they sum. For each edge that borders a coarser chunk, the edge is evaluated the way
    the coarse neighbour evaluates it: the vertices the two grids share are recomputed with the
    neighbour's wave count, and the in-between fine vertices are lerped between them, so the
    fine edge lies exactly on the coarse edge (no T-junction cracks, no height step).

    ONE CLOCK PER LOD. The controller hands in LodTimes: each LOD samples the wave clock once per
    UpdateEvery period (an epoch), and every chunk of that LOD displaces at its epoch's time
    whichever staggered frame it runs on. Two neighbours of one LOD therefore always agree,
    and the swell moves sideways at ~10 studs/s, so per-chunk times would open visible cracks.
    A stitched edge is evaluated at the COARSE neighbour's epoch time too, so it matches that
    neighbour exactly. What is left (corner vertices, chunks deferred past an epoch by the frame
    budget) is hidden by the skirt that hangs SkirtDepth below every edge.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaveField = require(Shared:WaitForChild("Water"):WaitForChild("WaveField"))
local WaterColor = require(Shared:WaitForChild("Water"):WaitForChild("WaterColor"))
local MeshBuilder = require(script.Parent.MeshBuilder)

type Chunk = MeshBuilder.Chunk

local Displace = WaveField.Displace
local Components = WaterColor.Components
local SideBase = MeshBuilder.SideBase
local SeaLevel = Water.SeaLevel

local ChunkModule = {}

ChunkModule.SkirtDepth = 4

-- Scratch arrays, grown to the largest chunk on first use.
local Capacity = 0
local SX: { number } = {}
local SY: { number } = {}
local SZ: { number } = {}
local SC: { number } = {}

local function Reserve(Count: number)
    if Count > Capacity then
        SX = table.create(Count, 0)
        SY = table.create(Count, 0)
        SZ = table.create(Count, 0)
        SC = table.create(Count, 0)
        Capacity = Count
    end
end

-- 8-bit colour cache. A cleared cache only costs re-creating Color3s; the cap bounds memory.
local ColorCache: { [number]: Color3 } = {}
local CacheCount = 0
local CacheLimit = 65536

local function Quantise(R: number, G: number, B: number): Color3
    local R8 = (R * 255 + 0.5) // 1
    local G8 = (G * 255 + 0.5) // 1
    local B8 = (B * 255 + 0.5) // 1
    if R8 < 0 then
        R8 = 0
    elseif R8 > 255 then
        R8 = 255
    end
    if G8 < 0 then
        G8 = 0
    elseif G8 > 255 then
        G8 = 255
    end
    if B8 < 0 then
        B8 = 0
    elseif B8 > 255 then
        B8 = 255
    end
    local Key = R8 * 65536 + G8 * 256 + B8
    local Cached = ColorCache[Key]
    if Cached then
        return Cached
    end
    if CacheCount >= CacheLimit then
        table.clear(ColorCache)
        CacheCount = 0
    end
    local Made = Color3.fromRGB(R8, G8, B8)
    ColorCache[Key] = Made
    CacheCount += 1
    return Made
end

-- Makes edge `Side` match a coarser neighbour (see header).
local function Stitch(Target: Chunk, Side: number, LodTimes: { number })
    local EdgeLod = Target.EdgeLod[Side]
    if EdgeLod == Target.LodIndex then
        return
    end
    local Ratio = Target.EdgeRatio[Side]
    local EdgeWaves = Target.EdgeWaves[Side]
    local Time = LodTimes[EdgeLod]
    local Res = Target.Res
    local N = Target.N
    local Step = Target.Step
    local X0, Z0 = Target.MinX, Target.MinZ
    local Base, Stride = SideBase(Res, Side)
    local Every = if Ratio > 1 then Ratio else 1

    -- Shared vertices, evaluated with the neighbour's wave count at the neighbour's clock.
    for T = 0, Res, Every do
        local Index = Base + T * Stride
        local Flat = Index - 1
        local GX = X0 + (Flat % N) * Step
        local GZ = Z0 + (Flat // N) * Step
        local DX, Y, DZ, Crest = Displace(GX, GZ, Time, EdgeWaves)
        SX[Index] = GX + DX
        SY[Index] = Y
        SZ[Index] = GZ + DZ
        SC[Index] = Crest
    end
    -- In-between vertices lie on the coarse neighbour's straight edge.
    if Ratio > 1 then
        local InvRatio = 1 / Ratio
        for T = 1, Res - 1 do
            local M = T % Ratio
            if M ~= 0 then
                local Index = Base + T * Stride
                local A = Base + (T - M) * Stride
                local B = A + Ratio * Stride
                local F = M * InvRatio
                SX[Index] = SX[A] + (SX[B] - SX[A]) * F
                SY[Index] = SY[A] + (SY[B] - SY[A]) * F
                SZ[Index] = SZ[A] + (SZ[B] - SZ[A]) * F
                SC[Index] = SC[A] + (SC[B] - SC[A]) * F
            end
        end
    end
end

--[[
    Re-displaces `Target` at its LOD's epoch time (LodTimes[LodIndex]) and writes its vertices;
    with `DoColor` also rewrites its vertex colours. `UseBatch` picks BatchSetValues over
    per-element calls.
]]
function ChunkModule.Update(Target: Chunk, LodTimes: { number }, DoColor: boolean, UseBatch: boolean)
    local Time = LodTimes[Target.LodIndex]
    local Res = Target.Res
    local N = Target.N
    local Step = Target.Step
    local Waves = Target.Waves
    local X0, Z0 = Target.MinX, Target.MinZ
    local Surface = Target.SurfaceCount
    Reserve(Surface)

    local Index = 0
    for J = 0, Res do
        local GZ = Z0 + J * Step
        for I = 0, Res do
            local GX = X0 + I * Step
            Index += 1
            local DX, Y, DZ, Crest = Displace(GX, GZ, Time, Waves)
            SX[Index] = GX + DX
            SY[Index] = Y
            SZ[Index] = GZ + DZ
            SC[Index] = Crest
        end
    end

    for Side = 1, 4 do
        Stitch(Target, Side, LodTimes)
    end

    local CX, CZ = Target.CenterX, Target.CenterZ
    local Positions = Target.Positions
    for K = 1, Surface do
        Positions[K] = Vector3.new(SX[K] - CX, SY[K] - SeaLevel, SZ[K] - CZ)
    end
    local Depth = ChunkModule.SkirtDepth
    for Side = 1, 4 do
        local Base, Stride = SideBase(Res, Side)
        local SkirtBase = Surface + (Side - 1) * N + 1
        for T = 0, Res do
            local E = Base + T * Stride
            Positions[SkirtBase + T] = Vector3.new(SX[E] - CX, SY[E] - SeaLevel - Depth, SZ[E] - CZ)
        end
    end

    local Mesh = Target.Mesh
    local VIds = Target.VIds
    if UseBatch then
        Mesh:BatchSetValues(VIds, Positions)
    else
        for K = 1, Target.VertexCount do
            Mesh:SetPosition(VIds[K], Positions[K])
        end
    end

    if DoColor then
        local Colors = Target.Colors
        local K = 0
        for J = 0, Res do
            local GZ = Z0 + J * Step
            for I = 0, Res do
                K += 1
                local R, G, B = Components(X0 + I * Step, GZ, SC[K])
                Colors[K] = Quantise(R, G, B)
            end
        end
        local CIds = Target.CIds
        if UseBatch then
            Mesh:BatchSetValues(CIds, Colors)
        else
            for C = 1, Surface do
                Mesh:SetColor(CIds[C], Colors[C])
            end
        end
    end
end

return ChunkModule
