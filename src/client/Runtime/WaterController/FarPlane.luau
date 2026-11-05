--!strict
--[[
    The far ring: the flat sea between the 3x3 wave chunks and the horizon tiles. ONE
    EditableMesh, (2 * Cells + 1) cells square (Cells = FarPlane.Cells), with the centre 3x3 cells
    cut out -- that hole is exactly where the chunks are -- built once and MOVED with the camera's
    cell, never rebuilt.

    WHY IT FOLLOWS THE CAMERA. No part may be larger than 2048 studs a side (a MeshPart built
    from a bigger EditableMesh fails or is clamped), so one static plane over a 20,000-stud ocean
    cannot exist. The v2 attempt was exactly that and was refused at build, which is why the sea
    stopped at the 3x3. Following the camera, the ring is 1,792 studs (7 cells of 256) and the
    plain-Part horizon tiles (Horizon.luau) carry the sea on to the horizon.

    WHY IT HAS A HOLE INSTEAD OF SITTING UNDER THE CHUNKS. The chunks' troughs dip ~14 studs
    below SeaLevel; any plane under them would poke through every trough. The ring and the
    chunks meet only at the 3x3 border, where the waves have faded to flat (Fade.Outer <=
    Chunk.Size), so both sit exactly at SeaLevel and meet edge to edge.

    COLOUR. Vertex colours are WaterColor at each node's WORLD position, rewritten (one
    BatchSetValues of ~840 colours) whenever the ring moves to a new cell, so the gradient stays
    locked to the world while the geometry travels with you. Positions never change after build:
    they are local to the part, which is moved to the camera cell's centre.

    BOUNDS. The grid itself is symmetric about the part origin (the ring is centred on the
    camera cell), plus MeshBuilder's never-written anchors, so the part scale is exactly 1.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaterColor = require(Shared:WaitForChild("Water"):WaitForChild("WaterColor"))
local MeshBuilder = require(script.Parent.MeshBuilder)

local Components = WaterColor.Components
local Quantise = MeshBuilder.Quantise

local CellSize = Water.Chunk.Size
local Cells = math.max(2, math.floor(Water.FarPlane.Cells))
local Subdivide = math.max(1, math.floor(Water.FarPlane.Subdivide))
local Span = (2 * Cells + 1) * CellSize -- studs, side of the whole ring
local Half = Span * 0.5
local Quads = (2 * Cells + 1) * Subdivide
local Nodes = Quads + 1
local QuadStep = CellSize / Subdivide
-- Quad indices [HoleMin, HoleMax) on each axis are the 3x3 hole.
local HoleMin = (Cells - 1) * Subdivide
local HoleMax = (Cells + 2) * Subdivide

if Span > 2048 then
    warn(`[WaterController] far ring is {Span} studs (> 2048 part limit); lower FarPlane.Cells`)
end

local FarPlane = {}

-- Side of the ring in studs (the horizon tiles are this size).
FarPlane.Span = Span

local Part: MeshPart? = nil
local Mesh: EditableMesh? = nil
local CIds: { any } = {}
local Colors: { Color3 } = table.create(Nodes * Nodes) :: { Color3 }

-- Local position of node (I, J), 0-based.
local function NodeLocal(I: number, J: number): (number, number)
    return I * QuadStep - Half, J * QuadStep - Half
end

--[[
    Builds the ring (unparented until the first MoveTo). Returns false when no EditableMesh or
    part could be made. Yields.
]]
function FarPlane.Build(Folder: Instance): boolean
    local Positions = table.create(Nodes * Nodes + 3) :: { Vector3 }
    local White = Color3.new(1, 1, 1)
    for J = 0, Quads do
        for I = 0, Quads do
            local X, Z = NodeLocal(I, J)
            Positions[J * Nodes + I + 1] = Vector3.new(X, 0, Z)
            Colors[J * Nodes + I + 1] = White
        end
    end

    local FaceVerts = {} :: { { number } }
    local FaceColors = {} :: { { number } }
    local FaceNormals = {} :: { { number } }
    local Up = { 1, 1, 1 }
    for J = 0, Quads - 1 do
        local InHoleRow = J >= HoleMin and J < HoleMax
        for I = 0, Quads - 1 do
            if not (InHoleRow and I >= HoleMin and I < HoleMax) then
                local A = J * Nodes + I + 1
                local B = A + 1
                local C = A + Nodes
                local D = C + 1
                -- (C - A) x (B - A) = (0, 0, s) x (s, 0, 0) = (0, s^2, 0): +Y, seen from above.
                table.insert(FaceVerts, { A, C, B })
                table.insert(FaceColors, { A, C, B }) -- one colour slot per node, same index
                table.insert(FaceNormals, Up)
                -- (C - B) x (D - B) = (-s, 0, s) x (0, 0, s) = (0, s^2, 0): +Y.
                table.insert(FaceVerts, { B, C, D })
                table.insert(FaceColors, { B, C, D })
                table.insert(FaceNormals, Up)
            end
        end
    end

    local Spec: MeshBuilder.MeshSpec = {
        Positions = Positions,
        Colors = Colors,
        AutoNormals = 0,
        ExtraNormal = Vector3.yAxis,
        FaceVerts = FaceVerts,
        FaceColors = FaceColors,
        FaceNormals = FaceNormals,
    }
    local Extent = Vector3.new(Half, 1, Half)
    MeshBuilder.AddAnchors(Spec, Extent)

    local Built = MeshBuilder.Build(Spec)
    if not Built then
        return false
    end
    local Made = MeshBuilder.MakePart(Built.Mesh, Extent, "OceanFarRing")
    if not Made then
        Built.Mesh:Destroy()
        return false
    end
    Made.Parent = nil
    Part = Made
    Mesh = Built.Mesh
    CIds = Built.CIds
    FarPlane.Folder = Folder
    return true
end

FarPlane.Folder = nil :: Instance?

--[[
    Centres the ring on cell (Cx, Cz) and recolours it for its new world position.
]]
function FarPlane.MoveTo(Cx: number, Cz: number)
    local Target, TargetMesh = Part, Mesh
    if not Target or not TargetMesh then
        return
    end
    local CenterX, CenterZ = (Cx + 0.5) * CellSize, (Cz + 0.5) * CellSize
    for J = 0, Quads do
        for I = 0, Quads do
            local X, Z = NodeLocal(I, J)
            local R, G, B = Components(CenterX + X, CenterZ + Z, 0)
            Colors[J * Nodes + I + 1] = Quantise(R, G, B)
        end
    end
    local Count = Nodes * Nodes
    if MeshBuilder.UseBatch then
        local Ids = table.create(Count) :: { any }
        table.move(CIds, 1, Count, 1, Ids)
        local Ok = pcall(function()
            (TargetMesh :: any):BatchSetValues(Ids, Colors)
        end)
        if not Ok then
            MeshBuilder.UseBatch = false
        end
    end
    if not MeshBuilder.UseBatch then
        for Index = 1, Count do
            TargetMesh:SetColor(CIds[Index], Colors[Index])
        end
    end
    Target.CFrame = CFrame.new(CenterX, Water.SeaLevel, CenterZ)
    Target.Parent = FarPlane.Folder
end

return FarPlane
