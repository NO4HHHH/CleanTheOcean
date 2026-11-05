--!strict
--[[
    The ocean you see: a ring of EditableMesh chunks around the camera, displaced every frame by
    the same Gerstner wave field (Shared/Water/WaveField) that the server's buoyancy uses, so a
    crate bobs on exactly the swell drawn under it. Client only; nothing here replicates.

    CHUNKS AND LOD. The sea is a grid of Water.Chunk.Size-stud squares. The camera's chunk is
    ring 0, its 8 neighbours ring 1, and so on out to Chunk.ViewRings. Each ring maps to the
    first entry of Chunk.Lods whose MaxRing covers it: near rings get a fine grid, every wave and
    an update every frame; far rings a coarse grid, only the big swells (the first WaveCount
    waves, the registry sorts them largest first) and an update every few frames. Far chop is
    sub-pixel, and far swells move slowly on screen, so this loses nothing you can see.

    RECYCLE, NEVER REBUILD. Because the ring layout is the same wherever the camera is, the
    number of chunks each LOD needs is constant. All chunks are built once at boot (ring by
    ring, nearest first, spread over frames because CreateMeshPartAsync yields) into a pool per
    LOD. When the camera crosses into another chunk (with a little hysteresis so hovering on a
    border does not thrash), chunks whose slot keeps the same LOD stay put; every other chunk
    goes back to its pool and is handed out again to a slot that needs that LOD: the MeshPart
    is moved and the chunk is flagged Fresh, which puts it at the head of the next update. No
    EditableMesh is ever created or destroyed after boot, so memory is flat and there is no
    GC churn.

    MEMORY BUDGET. CreateEditableMesh returns nil when the device's EditableMesh memory runs
    out (or errors when the place disallows mesh APIs). The ring being built when that happens
    is dropped, the view distance shrinks to the last complete ring, and the surplus chunks are
    destroyed. The sea still works, just closer in.

    FRAME BUDGET. Each Heartbeat collects the chunks that are due (NextFrame reached), sorts
    them most-overdue first (Fresh chunks count as most overdue, then nearer rings first), and
    updates them until FrameBudget seconds of os.clock are spent. Whatever does not fit simply
    stays due and goes first next frame, so overload degrades into a lower update rate for the
    far sea instead of a frame-time spike. Chunks of one LOD are phase-staggered so a LOD with
    UpdateEvery = 4 spends a quarter of its work each frame rather than all of it every fourth.

    COLOUR. The gradient depends on horizontal position only, but crest foam moves with the
    waves, so colours are rewritten every ColorStride-th position update (and immediately for a
    Fresh chunk). See Chunk.luau for the allocation-free details.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaveField = require(Shared:WaitForChild("Water"):WaitForChild("WaveField"))
local MeshBuilder = require(script.MeshBuilder)
local ChunkModule = require(script.Chunk)

type Chunk = MeshBuilder.Chunk

local WaterController = {}

-- Seconds of Luau per frame the ocean may spend on vertex updates (at least one chunk runs).
local FrameBudget = 0.003
-- Colours are rewritten every ColorStride-th position update of a chunk.
local ColorStride = 2
-- Studs past a chunk border the camera must go before the rings re-centre.
local HysteresisFraction = 0.1

local Size = Water.Chunk.Size
local Lods = Water.Chunk.Lods
local ViewRings = Water.Chunk.ViewRings
local SeaLevel = Water.SeaLevel
local Hysteresis = Size * HysteresisFraction

local Pools: { { Chunk } } = {}
for Index = 1, #Lods do
    Pools[Index] = {}
end
local Active: { [number]: Chunk } = {}
local ActiveList: { Chunk } = {}
local DueList: { Chunk } = {}
-- Wave clock per LOD, resampled once per UpdateEvery period (see Chunk.luau "ONE CLOCK PER LOD").
local LodTimes: { number } = table.create(#Lods, 0)
local LodEvery: { number } = table.create(#Lods, 1)
for Index, Lod in Lods do
    LodEvery[Index] = math.max(1, Lod.UpdateEvery)
end

local Folder: Folder? = nil
local Frame = 0
local CamCx, CamCz = 0, 0
local HasCamChunk = false
local EffectiveRings = ViewRings
local NeedsReassign = false
local BuildDone = false

local function LodForRing(Ring: number): number?
    if Ring > EffectiveRings then
        return nil
    end
    for Index, Lod in Lods do
        if Ring <= Lod.MaxRing then
            return Index
        end
    end
    return nil
end

local function KeyOf(Cx: number, Cz: number): number
    return (Cx + 32768) * 65536 + (Cz + 32768)
end

local function RingOf(Cx: number, Cz: number): number
    return math.max(math.abs(Cx - CamCx), math.abs(Cz - CamCz))
end

-- Edge stitching data: which sides border a coarser chunk, and how.
local SideDx = { 0, 0, -1, 1 }
local SideDz = { -1, 1, 0, 0 }

local function RefreshEdges(Target: Chunk)
    for Side = 1, 4 do
        local Ratio, EdgeWaves, EdgeLod = 1, Target.Waves, Target.LodIndex
        local NeighbourLod = LodForRing(RingOf(Target.Cx + SideDx[Side], Target.Cz + SideDz[Side]))
        if NeighbourLod and NeighbourLod > Target.LodIndex then
            local Neighbour = Lods[NeighbourLod]
            if Target.Res % Neighbour.Resolution == 0 then
                Ratio = Target.Res // Neighbour.Resolution
            end
            EdgeWaves = math.min(Target.Waves, Neighbour.WaveCount)
            EdgeLod = NeighbourLod
        end
        Target.EdgeRatio[Side] = Ratio
        Target.EdgeWaves[Side] = EdgeWaves
        Target.EdgeLod[Side] = EdgeLod
    end
end

local function Assign(Target: Chunk, Cx: number, Cz: number, Ring: number)
    Target.Cx = Cx
    Target.Cz = Cz
    Target.Key = KeyOf(Cx, Cz)
    Target.Ring = Ring
    Target.MinX = Cx * Size
    Target.MinZ = Cz * Size
    Target.CenterX = Target.MinX + Size * 0.5
    Target.CenterZ = Target.MinZ + Size * 0.5
    Target.NextFrame = 0
    Target.Fresh = true
    Target.Part.CFrame = CFrame.new(Target.CenterX, SeaLevel, Target.CenterZ)
    Target.Part.Parent = Folder
    Active[Target.Key] = Target
end

local function Release(Target: Chunk)
    Active[Target.Key] = nil
    Target.Part.Parent = nil
    table.insert(Pools[Target.LodIndex], Target)
end

local function Reassign()
    NeedsReassign = false

    for _, Target in ActiveList do
        local Ring = RingOf(Target.Cx, Target.Cz)
        if LodForRing(Ring) == Target.LodIndex then
            Target.Ring = Ring
        else
            Release(Target)
        end
    end

    -- Fill empty slots nearest first, so a short pool (still building) covers the near sea.
    for Ring = 0, EffectiveRings do
        local Lod = LodForRing(Ring)
        local Pool = if Lod then Pools[Lod] else nil
        if Pool then
            for Dz = -Ring, Ring do
                local Edge = Dz == -Ring or Dz == Ring
                local Dx = -Ring
                while Dx <= Ring do
                    local Cx, Cz = CamCx + Dx, CamCz + Dz
                    if not Active[KeyOf(Cx, Cz)] then
                        local Target = table.remove(Pool)
                        if Target then
                            Assign(Target, Cx, Cz, Ring)
                        end
                    end
                    Dx += if Edge then 1 else 2 * Ring
                end
            end
        end
    end

    table.clear(ActiveList)
    for _, Target in Active do
        table.insert(ActiveList, Target)
        RefreshEdges(Target)
    end

    -- Once every chunk exists, anything still pooled is surplus (a dropped partial ring).
    if BuildDone then
        for _, Pool in Pools do
            for _, Target in Pool do
                MeshBuilder.Destroy(Target)
            end
            table.clear(Pool)
        end
    end
end

local function UpdateCamChunk(Position: Vector3)
    local X, Z = Position.X, Position.Z
    if not HasCamChunk then
        HasCamChunk = true
        CamCx = X // Size
        CamCz = Z // Size
        NeedsReassign = true
        return
    end
    local MinX, MinZ = CamCx * Size, CamCz * Size
    if X < MinX - Hysteresis or X >= MinX + Size + Hysteresis or Z < MinZ - Hysteresis or Z >= MinZ + Size + Hysteresis then
        CamCx = X // Size
        CamCz = Z // Size
        NeedsReassign = true
    end
end

local function ByDue(A: Chunk, B: Chunk): boolean
    if A.NextFrame ~= B.NextFrame then
        return A.NextFrame < B.NextFrame
    end
    return A.Ring < B.Ring
end

local function Step()
    Frame += 1
    local Camera = workspace.CurrentCamera
    if not Camera then
        return
    end
    UpdateCamChunk(Camera.CFrame.Position)
    if NeedsReassign then
        Reassign()
    end

    local Now = WaveField.Now()
    for Index = 1, #Lods do
        if Frame % LodEvery[Index] == 0 or LodTimes[Index] == 0 then
            LodTimes[Index] = Now
        end
    end

    table.clear(DueList)
    for _, Target in ActiveList do
        if Target.NextFrame <= Frame then
            table.insert(DueList, Target)
        end
    end
    if #DueList == 0 then
        return
    end
    table.sort(DueList, ByDue)

    local UseBatch = MeshBuilder.UseBatch
    local Start = os.clock()
    for Index, Target in DueList do
        if Index > 1 and os.clock() - Start > FrameBudget then
            break
        end
        local DoColor = Target.Fresh or Target.ColorCountdown <= 0
        local Ok, Error = (pcall :: any)(ChunkModule.Update, Target, LodTimes, DoColor, UseBatch)
        if not Ok then
            -- A batch write that fails mid-game: drop to per-element calls from now on.
            if UseBatch then
                warn(`[WaterController] batched vertex write failed, falling back: {Error}`)
                MeshBuilder.UseBatch = false
                UseBatch = false
            else
                warn(`[WaterController] chunk update failed: {Error}`)
            end
        end
        local Every = Target.UpdateEvery
        if Target.Fresh then
            -- Stagger chunks of one LOD across the frames of their period.
            Target.NextFrame = Frame + 1 + (Target.Cx + Target.Cz * 3) % Every
            Target.Fresh = false
        else
            Target.NextFrame = Frame + Every
        end
        Target.ColorCountdown = if DoColor then ColorStride - 1 else Target.ColorCountdown - 1
    end
end

-- Builds the pools ring by ring; shrinks the view if the mesh budget runs out.
local function Build()
    for Ring = 0, ViewRings do
        local Lod = LodForRing(Ring)
        if not Lod then
            break
        end
        local Count = if Ring == 0 then 1 else 8 * Ring
        for _ = 1, Count do
            local Target = MeshBuilder.Build(Lod, ChunkModule.SkirtDepth)
            if not Target then
                EffectiveRings = Ring - 1
                if EffectiveRings < 0 then
                    warn("[WaterController] no EditableMesh available; the ocean is disabled")
                else
                    warn(`[WaterController] EditableMesh budget reached: view limited to {EffectiveRings} rings`)
                end
                BuildDone = true
                NeedsReassign = true
                return
            end
            table.insert(Pools[Lod], Target)
            NeedsReassign = true
            task.wait()
        end
    end
    BuildDone = true
    NeedsReassign = true
end

function WaterController:Start()
    if not RunService:IsClient() then
        return
    end
    local Existing = workspace:FindFirstChild("Ocean")
    local OceanFolder: Folder
    if Existing and Existing:IsA("Folder") then
        OceanFolder = Existing
    else
        OceanFolder = Instance.new("Folder")
        OceanFolder.Name = "Ocean"
        OceanFolder.Parent = workspace
    end
    Folder = OceanFolder

    RunService.Heartbeat:Connect(Step)
    task.spawn(Build)
end

return WaterController
