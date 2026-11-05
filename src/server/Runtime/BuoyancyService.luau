--!optimize 2
--[[
    Floats things. Anything tagged `Buoyant` (Data/Water.Buoyancy.Tag) in Workspace -- a BasePart,
    or a Model (its PrimaryPart, else its first BasePart) -- gets a Buoyancy State and is stepped
    every frame against the same WaveField the client draws, so it tilts and bobs with the waves
    players see.

    SERVER-OWNED ON PURPOSE. Network ownership is pinned to the server (SetNetworkOwner(nil)) so
    every client sees one authoritative bob, and the forces are applied where the body is actually
    simulated. A client-owned boat later can run Shared/Water/Buoyancy itself.

    WHAT IS TRACKED IS THE TAGGED INSTANCE, WHAT GETS FORCES IS ITS ASSEMBLY ROOT. The buoyant box
    is the tagged part's own box, or the Model's bounding box, expressed in the root's space. If
    welds change and the root moves, the entry re-tracks itself onto the new root.

    BUDGETED, ROUND-ROBIN. Steps run on PostSimulation with an os.clock budget; an entry not
    reached this frame keeps last frame's forces (Buoyancy clamps them so a stale force cannot
    overshoot) and is first in line next frame, with its own elapsed Dt.

    FAR = PARKED, NOT FROZEN. An assembly farther than MaxSimDistance from every character is
    "held": its force cancels its weight and its velocity is zeroed once, so it neither sinks nor
    drifts away while nobody looks, and costs nothing per frame. Anchored ones are skipped.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WaterData = require(Shared.Data.Water)
local WaveField = require(Shared.Water.WaveField)
local Buoyancy = require(Shared.Water.Buoyancy)

local Config = WaterData.Buoyancy
local Tag: string = Config.Tag or "Buoyant"
local MaxSimDistanceSq: number = (Config.MaxSimDistance or 600) ^ 2
--> Seconds of server frame time the stepping may use per frame.
local FrameBudget = 0.002
--> How often (seconds) the far/near test is re-run per entry.
local RangeCheckEvery = 0.5

type Entry = {
    Instance: Instance,
    Root: BasePart,
    State: Buoyancy.State,
    LastClock: number,
    NextRangeCheck: number,
    Far: boolean,
    --> Server network ownership has been pinned (deferred while the root is anchored).
    Owned: boolean,
    Connections: { RBXScriptConnection },
    Index: number,
}

local BuoyancyService = {}

local Entries: { Entry } = {}
local ByInstance: { [Instance]: Entry } = {}
local Cursor = 1
local CharacterPositions: { Vector3 } = {}

local function DensityOf(Inst: Instance, Root: BasePart): number?
    local Value = Inst:GetAttribute("BuoyancyDensity")
    if typeof(Value) ~= "number" then
        Value = Root:GetAttribute("BuoyancyDensity")
    end
    if typeof(Value) == "number" then
        return Value
    end
    return nil
end

--> The part whose assembly floats, plus the buoyant box in the assembly root's space.
local function Resolve(Inst: Instance): (BasePart?, CFrame, Vector3)
    local BoxCFrame: CFrame, BoxSize: Vector3, Part: BasePart?
    if Inst:IsA("BasePart") then
        Part = Inst
        BoxCFrame, BoxSize = Inst.CFrame, Inst.Size
    elseif Inst:IsA("Model") then
        Part = Inst.PrimaryPart or Inst:FindFirstChildWhichIsA("BasePart", true)
        if Part == nil then
            return nil, CFrame.identity, Vector3.zero
        end
        BoxCFrame, BoxSize = Inst:GetBoundingBox()
    else
        return nil, CFrame.identity, Vector3.zero
    end
    local Root = (Part :: BasePart).AssemblyRootPart or Part :: BasePart
    return Root, Root.CFrame:ToObjectSpace(BoxCFrame), BoxSize
end

local Untrack: (Inst: Instance) -> ()

local function Track(Inst: Instance)
    if ByInstance[Inst] or not Inst:IsDescendantOf(workspace) then
        return
    end
    local Root, BoxOffset, BoxSize = Resolve(Inst)
    if Root == nil then
        warn(`BuoyancyService: {Inst:GetFullName()} is tagged {Tag} but has no BasePart`)
        return
    end
    local RootPart = Root :: BasePart

    local State = Buoyancy.Attach(RootPart, BoxOffset, BoxSize, DensityOf(Inst, RootPart))

    local Entry: Entry = {
        Instance = Inst,
        Root = RootPart,
        State = State,
        LastClock = os.clock(),
        NextRangeCheck = 0,
        Far = false,
        Owned = false,
        Connections = {},
        Index = #Entries + 1,
    }
    Entries[Entry.Index] = Entry
    ByInstance[Inst] = Entry

    table.insert(
        Entry.Connections,
        Inst:GetAttributeChangedSignal("BuoyancyDensity"):Connect(function()
            State.Density = DensityOf(Inst, RootPart) or Config.DefaultDensity
        end)
    )
    table.insert(
        Entry.Connections,
        Inst.AncestryChanged:Connect(function()
            if not Inst:IsDescendantOf(workspace) then
                Untrack(Inst)
            end
        end)
    )
end

function Untrack(Inst: Instance)
    local Entry = ByInstance[Inst]
    if Entry == nil then
        return
    end
    ByInstance[Inst] = nil
    for _, Connection in Entry.Connections do
        Connection:Disconnect()
    end
    Buoyancy.Detach(Entry.State)

    -- Swap-remove from the stepping array.
    local Last = #Entries
    local Moved = Entries[Last]
    Entries[Entry.Index] = Moved
    Moved.Index = Entry.Index
    Entries[Last] = nil
    if Cursor > #Entries then
        Cursor = 1
    end
end

local function Retrack(Inst: Instance)
    Untrack(Inst)
    Track(Inst)
end

local function GatherCharacters()
    table.clear(CharacterPositions)
    for _, Player in Players:GetPlayers() do
        local Character = Player.Character
        local Primary = Character and Character.PrimaryPart
        if Primary then
            table.insert(CharacterPositions, Primary.Position)
        end
    end
end

local function IsNear(Position: Vector3): boolean
    for _, Other in CharacterPositions do
        local DX, DZ = Position.X - Other.X, Position.Z - Other.Z
        if DX * DX + DZ * DZ <= MaxSimDistanceSq then
            return true
        end
    end
    return false
end

local Stale: { Instance } = {}

local function StepEntry(Entry: Entry, Clock: number, Time: number)
    local Root = Entry.Root
    local Dt = Clock - Entry.LastClock
    Entry.LastClock = Clock

    if Root.Parent == nil or Root.AssemblyRootPart ~= Root then
        table.insert(Stale, Entry.Instance)
        return
    end
    if Root.Anchored then
        return
    end
    if not Entry.Owned then
        -- Deferred to here so a part tagged while anchored still gets pinned once released.
        -- CanSetNetworkOwnership is false (not an error) for anchored / welded-to-anchored roots.
        Entry.Owned = true
        if Root:CanSetNetworkOwnership() then
            pcall(Root.SetNetworkOwner, Root, nil)
        end
    end

    if Clock >= Entry.NextRangeCheck then
        Entry.NextRangeCheck = Clock + RangeCheckEvery
        local Far = not IsNear(Root.Position)
        if Far ~= Entry.Far then
            Entry.Far = Far
            if Far then
                Buoyancy.Hold(Entry.State)
            else
                Buoyancy.Clear(Entry.State)
            end
        end
    end
    if Entry.Far then
        return
    end

    Buoyancy.Step(Root, Entry.State, Dt, Time)
end

local function OnPostSimulation()
    local Count = #Entries
    if Count == 0 then
        return
    end
    GatherCharacters()

    local Start = os.clock()
    local Time = WaveField.Now()
    if Cursor > Count then
        Cursor = 1
    end
    for _ = 1, Count do
        local Entry = Entries[Cursor]
        Cursor = if Cursor >= Count then 1 else Cursor + 1
        if Entry then
            StepEntry(Entry, os.clock(), Time)
        end
        if os.clock() - Start > FrameBudget then
            break
        end
    end

    if #Stale > 0 then
        for _, Inst in Stale do
            if Inst.Parent ~= nil and CollectionService:HasTag(Inst, Tag) then
                Retrack(Inst)
            else
                Untrack(Inst)
            end
        end
        table.clear(Stale)
    end
end

--> Number of assemblies currently floated (for debug commands).
function BuoyancyService:Count(): number
    return #Entries
end

function BuoyancyService:Start()
    CollectionService:GetInstanceAddedSignal(Tag):Connect(Track)
    CollectionService:GetInstanceRemovedSignal(Tag):Connect(Untrack)
    for _, Inst in CollectionService:GetTagged(Tag) do
        Track(Inst)
    end
    RunService.PostSimulation:Connect(OnPostSimulation)
end

return BuoyancyService
