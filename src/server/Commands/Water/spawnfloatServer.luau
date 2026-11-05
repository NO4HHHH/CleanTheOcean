--[[
    Debug spawner for the buoyancy system: drops unanchored, tagged test bodies a few studs above
    the wave surface so they splash in, settle at their draft and ride the swell.

    Crates get a random size and density (0.3..0.75), so a batch shows the range from high-riding
    to barely awash. The raft is a deck with a mast and a crate welded on top: only the DECK is
    tagged, so the buoyant box is the deck (a whole-Model box would include the mast and float it
    far too deep), while the mast's mass raises the centre of mass and makes the raft rock.
    Everything goes in workspace.Floats so `cleanfloats` can remove it in one go.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WaterData = require(Shared.Data.Water)
local WaveField = require(Shared.Water.WaveField)

local Tag = WaterData.Buoyancy.Tag
local MaxCount = 40
local DropHeight = 4

local function FloatsFolder(): Folder
    local Existing = workspace:FindFirstChild("Floats")
    if Existing and Existing:IsA("Folder") then
        return Existing
    end
    local Folder = Instance.new("Folder")
    Folder.Name = "Floats"
    Folder.Parent = workspace
    return Folder
end

local function Origin(Executor: Player?): (Vector3, Vector3)
    local Character = Executor and Executor.Character
    local Primary = Character and Character.PrimaryPart
    if Primary then
        local Look = Primary.CFrame.LookVector
        local Flat = Vector3.new(Look.X, 0, Look.Z)
        Flat = if Flat.Magnitude > 1e-3 then Flat.Unit else Vector3.zAxis
        return Primary.Position + Flat * 30, Flat
    end
    return Vector3.new(0, 0, 40), Vector3.zAxis
end

local function SurfaceCFrame(X: number, Z: number, Lift: number, Yaw: number): CFrame
    local Y = WaveField.HeightAt(X, Z, WaveField.Now()) + Lift
    return CFrame.new(X, Y, Z) * CFrame.Angles(0, Yaw, 0)
end

local function MakePart(Name: string, Size: Vector3, Color: Color3, Material: Enum.Material): Part
    local Part = Instance.new("Part")
    Part.Name = Name
    Part.Size = Size
    Part.Color = Color
    Part.Material = Material
    Part.Anchored = false
    Part.TopSurface = Enum.SurfaceType.Smooth
    Part.BottomSurface = Enum.SurfaceType.Smooth
    return Part
end

local function SpawnCrate(Folder: Folder, At: Vector3, Rng: Random)
    local Side = Rng:NextNumber(3, 6)
    local Size = Vector3.new(Side, Side * Rng:NextNumber(0.7, 1.1), Side * Rng:NextNumber(0.8, 1.2))
    local Crate = MakePart("Crate", Size, Color3.fromRGB(150, 105, 60), Enum.Material.WoodPlanks)
    Crate.CFrame = SurfaceCFrame(At.X, At.Z, Size.Y * 0.5 + DropHeight, Rng:NextNumber(0, math.pi * 2))
    Crate:SetAttribute("BuoyancyDensity", math.floor(Rng:NextNumber(0.3, 0.75) * 100 + 0.5) / 100)
    CollectionService:AddTag(Crate, Tag)
    Crate.Parent = Folder
end

local function Weld(A: BasePart, B: BasePart)
    local Constraint = Instance.new("WeldConstraint")
    Constraint.Part0 = A
    Constraint.Part1 = B
    Constraint.Parent = A
end

local function SpawnRaft(Folder: Folder, At: Vector3, Yaw: number)
    local Model = Instance.new("Model")
    Model.Name = "Raft"

    local DeckSize = Vector3.new(16, 1.6, 10)
    local Deck = MakePart("Deck", DeckSize, Color3.fromRGB(160, 120, 75), Enum.Material.WoodPlanks)
    local DeckCFrame = SurfaceCFrame(At.X, At.Z, DeckSize.Y * 0.5 + DropHeight, Yaw)
    Deck.CFrame = DeckCFrame
    Deck:SetAttribute("BuoyancyDensity", 0.4)
    Deck.Parent = Model

    local Mast = MakePart("Mast", Vector3.new(0.8, 10, 0.8), Color3.fromRGB(110, 80, 50), Enum.Material.Wood)
    Mast.CFrame = DeckCFrame * CFrame.new(2, DeckSize.Y * 0.5 + 5, 0)
    Mast.Parent = Model
    Weld(Deck, Mast)

    local Sail = MakePart("Sail", Vector3.new(0.2, 6, 6), Color3.fromRGB(235, 230, 215), Enum.Material.Fabric)
    Sail.CFrame = DeckCFrame * CFrame.new(2, DeckSize.Y * 0.5 + 6.5, 0) * CFrame.Angles(0, math.pi / 2, 0)
    Sail.Massless = true
    Sail.Parent = Model
    Weld(Deck, Sail)

    local Cargo = MakePart("Cargo", Vector3.new(3, 3, 3), Color3.fromRGB(130, 90, 55), Enum.Material.WoodPlanks)
    Cargo.CFrame = DeckCFrame * CFrame.new(-4, DeckSize.Y * 0.5 + 1.5, 1.5)
    Cargo.Parent = Model
    Weld(Deck, Cargo)

    Model.PrimaryPart = Deck
    -- Tag the deck, not the model: the buoyant box must be the hull, not the mast's bounding box.
    CollectionService:AddTag(Deck, Tag)
    Model.Parent = Folder
end

return function(Context, Count: number?, Kind: string?)
    local Executor: Player? = Context.Executor
    local Which = string.lower(Kind or "crate")
    if Which ~= "crate" and Which ~= "raft" then
        return `Unknown kind "{Which}" (use crate or raft)`
    end
    local Wanted = math.clamp(math.floor(Count or (if Which == "raft" then 1 else 6)), 1, MaxCount)

    local Folder = FloatsFolder()
    local Center, Forward = Origin(Executor)
    local Right = Vector3.new(-Forward.Z, 0, Forward.X)
    local Rng = Random.new()
    local Spacing = if Which == "raft" then 22 else 9
    local PerRow = math.ceil(math.sqrt(Wanted))

    for Index = 0, Wanted - 1 do
        local Column = Index % PerRow
        local Row = Index // PerRow
        local At = Center + Right * ((Column - (PerRow - 1) / 2) * Spacing) + Forward * (Row * Spacing)
        if Which == "raft" then
            SpawnRaft(Folder, At, math.atan2(Forward.X, Forward.Z))
        else
            SpawnCrate(Folder, At, Rng)
        end
    end
    return `Spawned {Wanted} {Which}(s) in workspace.Floats`
end
