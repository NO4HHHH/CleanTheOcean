--!strict
--[[
    The ocean you see. Client only; nothing here replicates.

    THREE LAYERS, ALL FOLLOWING THE CAMERA'S CELL (cells are Water.Chunk.Size studs; the camera's
    cell is (floor(CamX / Size), floor(CamZ / Size))):
      * nine wave chunks (Chunk.luau) on that cell and its eight neighbours -- the only part that
        waves. When the camera changes cell, chunks still in the 3x3 stay; the ones that left are
        handed to the newly entered cells (moved, rewritten in full, then shown).
      * the far ring (FarPlane.luau): one flat EditableMesh around the 3x3, recoloured per cell.
      * the horizon tiles (Horizon.luau): plain flat Parts out to ~10,000 studs.
    So the sea reaches the horizon in every direction, waves or not, with ten EditableMeshes in
    total (the ~8-10 a device can reliably afford). Nothing is created or destroyed after boot.

    SYNC WITHOUT NETWORKING. A chunk's geometry is a pure function of its cell position and the
    server clock: WaveField evaluated at WORLD coordinates at WaveField.Now()
    (workspace:GetServerTimeNow). Every client draws the same sea at the same moment, and the
    server's buoyancy (same WaveField, same clock) floats crates on exactly that sea.

    SEAMLESS, AND WHY A TICK IS NEVER SPLIT. Each update tick samples Time and the camera ONCE
    and writes all nine chunks with them IN THE SAME FRAME, so the edges two neighbours share are
    bit-identical (Chunk.luau) and there are no cracks to hide -- which is why the chunks no
    longer need skirts. An earlier version spread a slow tick over several frames under a time
    budget; neighbours then showed different moments and cracked. Instead the tick RATE is
    capped (Chunk.UpdateHz) and each tick only touches the vertices that wave (Chunk.luau), so a
    whole tick is cheap enough for one frame.

    DEGRADING. The far ring is built first, then the centre chunk, then the neighbours, edge
    neighbours before corners. If CreateEditableMesh returns nil or errors, building stops with
    one warn; the horizon tiles are plain Parts and always exist.

    SIBLINGS STEPPED FROM THE SAME HEARTBEAT: Underwater.luau (tint / blur / fog when the camera
    dips below the surface) and PlayerFloat.luau (the local character floats when it is in the
    water and not standing on ground). Both are optional and disabled on their first error.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaveField = require(Shared:WaitForChild("Water"):WaitForChild("WaveField"))
local MeshBuilder = require(script.MeshBuilder)
local FarPlane = require(script.FarPlane)
local Horizon = require(script.Horizon)
local ChunkModule = require(script.Chunk)

type Chunk = ChunkModule.Chunk

type StepModule = {
    Init: () -> (),
    Step: (Dt: number) -> (),
}

local WaterController = {}

-- Seconds between wave ticks.
local TickInterval = 1 / math.max(1, Water.Chunk.UpdateHz)
-- Colours of a waving chunk are rewritten every ColorStride-th tick (foam moves with crests).
local ColorStride = 3

local Size = Water.Chunk.Size
local SeaLevel = Water.SeaLevel

-- 3x3 slots in build / priority order: centre, edge neighbours, corners.
local SlotDx = { 0, 1, -1, 0, 0, 1, -1, 1, -1 }
local SlotDz = { 0, 0, 0, 1, -1, 1, 1, -1, -1 }

-- Optional sibling modules stepped every frame, in this order.
local StepperNames = { "Underwater", "PlayerFloat" }

local Chunks: { Chunk } = {}
local Folder: Folder? = nil
local Steppers: { [string]: StepModule } = {}
local SinceTick = math.huge

local HasCell = false
local CamCx, CamCz = 0, 0
local NeedsAssign = false

local Queue: { Chunk } = {}

local function Hide(Target: Chunk)
    if Target.Shown then
        Target.Part.Parent = nil
        Target.Shown = false
    end
    Target.Assigned = false
    Target.Pending = false
end

local function Show(Target: Chunk)
    Target.Part.CFrame = CFrame.new((Target.Cx + 0.5) * Size, SeaLevel, (Target.Cz + 0.5) * Size)
    Target.Part.Parent = Folder
    Target.Shown = true
    Target.Pending = false
end

-- Re-deals the chunks over the 3x3 around (CamCx, CamCz). Only ever runs at the start of a tick.
local function Assign()
    NeedsAssign = false

    local WantCx: { number } = table.create(9, 0)
    local WantCz: { number } = table.create(9, 0)
    for Slot = 1, 9 do
        WantCx[Slot], WantCz[Slot] = CamCx + SlotDx[Slot], CamCz + SlotDz[Slot]
    end

    -- Keep chunks whose cell is still wanted; free the rest.
    local Covered: { boolean } = table.create(9, false)
    for _, Target in Chunks do
        if Target.Assigned then
            local Kept = false
            for Slot = 1, 9 do
                if not Covered[Slot] and WantCx[Slot] == Target.Cx and WantCz[Slot] == Target.Cz then
                    Covered[Slot] = true
                    Target.Rank = Slot
                    Kept = true
                    break
                end
            end
            if not Kept then
                Hide(Target)
            end
        end
    end

    -- Hand free chunks to uncovered cells, centre first.
    local Free = 1
    for Slot = 1, 9 do
        if not Covered[Slot] then
            while Chunks[Free] and Chunks[Free].Assigned do
                Free += 1
            end
            local Target = Chunks[Free]
            if not Target then
                break
            end
            Target.Cx, Target.Cz = WantCx[Slot], WantCz[Slot]
            Target.Rank = Slot
            Target.Assigned = true
            Target.Pending = true -- shown only once written at the new cell
        end
    end
end

local function ByRank(A: Chunk, B: Chunk): boolean
    return A.Rank < B.Rank
end

local function RunChunk(Target: Chunk, Time: number, CamX: number, CamZ: number)
    local DoColor = Target.Pending or Target.ColorCountdown <= 0
    local UseBatch = MeshBuilder.UseBatch
    local Ok, Error = (pcall :: any)(ChunkModule.Update, Target, Time, CamX, CamZ, DoColor, UseBatch)
    if not Ok then
        if UseBatch then
            -- A batch write that fails mid-game: drop to per-element calls from now on.
            warn(`[WaterController] batched vertex write failed, falling back: {Error}`)
            MeshBuilder.UseBatch = false
        else
            warn(`[WaterController] chunk update failed: {Error}`)
        end
        return
    end
    Target.ColorCountdown = if DoColor then ColorStride - 1 else Target.ColorCountdown - 1
    if Target.Pending then
        Show(Target)
    end
end

-- One wave tick: re-deals cells if needed, samples Time and camera once, writes every chunk
-- that has something to change -- all in this frame (see SEAMLESS).
local function RunTick()
    local Camera = workspace.CurrentCamera
    if not Camera then
        return
    end
    local Position = Camera.CFrame.Position
    local Cx, Cz = Position.X // Size, Position.Z // Size
    if not HasCell or Cx ~= CamCx or Cz ~= CamCz then
        HasCell = true
        CamCx, CamCz = Cx, Cz
        NeedsAssign = true
        FarPlane.MoveTo(Cx, Cz)
        Horizon.MoveTo(Cx, Cz)
    end
    if NeedsAssign then
        Assign()
    end

    local Time = WaveField.Now()
    local CamX, CamZ = Position.X, Position.Z
    table.clear(Queue)
    for _, Target in Chunks do
        if Target.Assigned and ChunkModule.NeedsUpdate(Target, CamX, CamZ) then
            table.insert(Queue, Target)
        end
    end
    table.sort(Queue, ByRank)
    for _, Target in Queue do
        RunChunk(Target, Time, CamX, CamZ)
    end
end

local function Step(Dt: number)
    for _, Name in StepperNames do
        local Module = Steppers[Name]
        if Module then
            local Ok, Error = (pcall :: any)(Module.Step, Dt)
            if not Ok then
                warn(`[WaterController] {Name}.Step failed, disabling it: {Error}`)
                Steppers[Name] = nil
            end
        end
    end

    SinceTick += Dt
    if SinceTick >= TickInterval then
        SinceTick = 0
        RunTick()
    end
end

-- Far ring first, then chunks centre-first; stops at the first mesh the device refuses.
local function Build(OceanFolder: Folder)
    if not FarPlane.Build(OceanFolder) then
        warn("[WaterController] no EditableMesh available for the far ring; trying the wave chunks")
    end
    HasCell = false -- place the far ring on the next tick
    for _ = 1, 9 do
        local Target = ChunkModule.Build()
        if not Target then
            warn(`[WaterController] EditableMesh budget reached: {#Chunks} of 9 wave chunks`)
            return
        end
        table.insert(Chunks, Target)
        NeedsAssign = true
        task.wait()
    end
end

local function StartStepper(Name: string)
    local Found = script:FindFirstChild(Name)
    if not Found or not Found:IsA("ModuleScript") then
        return
    end
    local Ok, Result = pcall(require, Found)
    if not Ok or type(Result) ~= "table" then
        warn(`[WaterController] {Name} module failed to load: {Result}`)
        return
    end
    local Module = Result :: StepModule
    local InitOk, InitError = (pcall :: any)(Module.Init)
    if not InitOk then
        warn(`[WaterController] {Name}.Init failed: {InitError}`)
        return
    end
    Steppers[Name] = Module
end

function WaterController:Start()
    if not RunService:IsClient() then
        return
    end
    if Water.Fade.Outer > Size then
        warn(`[WaterController] Water.Fade.Outer ({Water.Fade.Outer}) > Chunk.Size ({Size}); clamped so the 3x3 border stays flat`)
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

    -- Plain Parts, no EditableMesh budget: the sea reaches the horizon even if every mesh fails.
    Horizon.Build(OceanFolder, FarPlane.Span)

    for _, Name in StepperNames do
        StartStepper(Name)
    end
    RunService.Heartbeat:Connect(Step)
    task.spawn(Build, OceanFolder)
end

return WaterController
