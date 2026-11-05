--!strict
--[[
    The sea out to the horizon: flat plain Parts beyond the far ring.

    PLAIN PARTS, NOT EDITABLEMESHES. Out here the sea is flat and nearly one colour, so it needs
    no vertices of its own; plain anchored Parts are about the cheapest thing Roblox draws and
    cost no EditableMesh memory (a device affords only ~10 of those). No part may exceed 2048
    studs a side, so the horizon is a grid of tiles the size of the far ring (FarPlane.Span):
    Horizon.Rings rings of them around it, all following the camera's cell.

    Each tile is one colour, WaterColor at its centre, re-set when the camera changes cell.
    Beyond the last Gradient stop (2,500 studs from the island) every tile is the same deep
    blue, so the only visible banding is in tiles near the island seen from far away.

    Tiles sit exactly at SeaLevel: the top face of a 1-stud-thick part is placed at SeaLevel, so
    they meet the far ring edge to edge with no step.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaterColor = require(Shared:WaitForChild("Water"):WaitForChild("WaterColor"))

local Rings = math.max(0, math.floor(Water.Horizon.Rings))
local CellSize = Water.Chunk.Size
local Thickness = 1

local Horizon = {}

type Tile = { Part: Part, Dx: number, Dz: number }

local Tiles: { Tile } = {}
local Span = 0

function Horizon.Build(Folder: Instance, TileSpan: number)
    Span = TileSpan
    for Dz = -Rings, Rings do
        for Dx = -Rings, Rings do
            if Dx ~= 0 or Dz ~= 0 then
                local Tile = Instance.new("Part")
                Tile.Name = "OceanHorizon"
                Tile.Anchored = true
                Tile.CanCollide = false
                Tile.CanQuery = false
                Tile.CanTouch = false
                Tile.CastShadow = false
                Tile.Locked = true
                Tile.Material = Enum.Material.SmoothPlastic
                Tile.TopSurface = Enum.SurfaceType.Smooth
                Tile.BottomSurface = Enum.SurfaceType.Smooth
                Tile.Size = Vector3.new(Span, Thickness, Span)
                Tile.Parent = Folder
                table.insert(Tiles, { Part = Tile, Dx = Dx, Dz = Dz })
            end
        end
    end
end

-- Centres the tile grid on cell (Cx, Cz) and recolours each tile for its new world position.
function Horizon.MoveTo(Cx: number, Cz: number)
    local CenterX, CenterZ = (Cx + 0.5) * CellSize, (Cz + 0.5) * CellSize
    local Y = Water.SeaLevel - Thickness * 0.5
    for _, Tile in Tiles do
        local X, Z = CenterX + Tile.Dx * Span, CenterZ + Tile.Dz * Span
        Tile.Part.CFrame = CFrame.new(X, Y, Z)
        Tile.Part.Color = WaterColor.At(X, Z)
    end
end

return Horizon
