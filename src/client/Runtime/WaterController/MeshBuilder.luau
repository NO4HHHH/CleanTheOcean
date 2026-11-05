--!strict
--[[
    Builds one pooled ocean chunk: an EditableMesh grid plus the MeshPart that shows it. Runs
    once per chunk at boot and never again -- chunks are recycled, not rebuilt -- so this file
    favours clarity over speed. The per-frame work lives in Chunk.luau.

    LAYOUT. A chunk of resolution R has (R+1)^2 surface vertices in row-major order
    (index = J * (R+1) + I + 1, I along +X, J along +Z), then a SKIRT: one extra vertex under
    every edge vertex, 4 * (R+1) of them, side by side (see SideBase). Skirt quads are added with
    both windings so a crack between two LODs is filled by a wall of water whichever way the
    camera sees it. Colour IDs exist for surface vertices only; a skirt corner reuses the colour
    of the edge vertex above it, so recolouring touches (R+1)^2 colours and nothing else.

    NORMALS are left to the engine: one auto normal per SURFACE vertex, shared by all its faces,
    which gives smooth shading and costs no Luau work when the waves move. A skirt vertex reuses
    the normal of the edge vertex above it: the skirt quads come in both windings, so a normal of
    its own would average to zero (undefined shading), and borrowing the surface normal makes the
    skirt shade like the water it hangs from. The two windings also cancel in the edge vertex's
    own average, so the skirt does not bend the surface shading.

    BOUNDS ARE PINNED. A MeshPart takes its size from the mesh bounds at creation, and the
    scale from Size / MeshSize. The build lays the grid out flat over [-Half, Half] and parks
    the centre vertex at +Pin and the skirt at -Pin, so the bounds are symmetric about the
    part's origin and tall enough for any wave: the scale is exactly 1 and local vertex
    coordinates are world offsets from the part's position. The skirt is also parked MaxShift
    studs outside the chunk's square (the largest sideways Gerstner shift), so the bounds the
    engine culls by still contain the edge vertices when the waves push them past the border.

    BATCH API FIRST. The EditableMesh batching API (BatchAdd / BatchSetFaceAttributes /
    BatchSetValues) is used when present; if it is missing or throws (an older client, or the
    Studio beta toggle off), the build falls back to one call per element and the module
    remembers that, so Chunk.luau writes with SetPosition/SetColor loops instead.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Water = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Water"))

export type Chunk = {
    Mesh: EditableMesh,
    Part: MeshPart,
    LodIndex: number,
    Res: number,
    N: number,
    Step: number,
    Waves: number,
    UpdateEvery: number,
    SurfaceCount: number,
    VertexCount: number,
    VIds: { any },
    CIds: { any },
    Positions: { Vector3 },
    Colors: { Color3 },
    -- Placement (written by the controller on assign).
    Cx: number,
    Cz: number,
    Key: number,
    Ring: number,
    MinX: number,
    MinZ: number,
    CenterX: number,
    CenterZ: number,
    NextFrame: number,
    Fresh: boolean,
    ColorCountdown: number,
    EdgeRatio: { number },
    EdgeWaves: { number },
    -- LOD whose clock and wave count each edge follows (own LOD unless a coarser neighbour).
    EdgeLod: { number },
}

local MeshBuilder = {}

-- Whether the batch API works on this client. Starts optimistic; the first failure clears it.
MeshBuilder.UseBatch = true

local MaxHeight = 0
for _, Wave in Water.Waves do
    MaxHeight += Wave.Amplitude
end
MeshBuilder.MaxHeight = MaxHeight

-- Largest horizontal Gerstner shift: sum of S / k = S * Wavelength / (2*pi).
local MaxShift = 0
for _, Wave in Water.Waves do
    MaxShift += Wave.Steepness * Wave.Wavelength / (2 * math.pi)
end
MeshBuilder.MaxShift = MaxShift

--[[
    First surface index and stride of edge `Side` (1 = -Z row, 2 = +Z row, 3 = -X column,
    4 = +X column). Edge vertex T (0..R) is Base + T * Stride.
]]
function MeshBuilder.SideBase(Res: number, Side: number): (number, number)
    local N = Res + 1
    if Side == 1 then
        return 1, 1
    elseif Side == 2 then
        return Res * N + 1, 1
    elseif Side == 3 then
        return 1, N
    end
    return Res + 1, N
end

local function Material(): Enum.Material
    local Ok, Value = pcall(function()
        return (Enum.Material :: any)[Water.Material]
    end)
    if Ok and typeof(Value) == "EnumItem" then
        return Value :: Enum.Material
    end
    return Enum.Material.SmoothPlastic
end

local OceanMaterial = Material()

-- Geometry as plain arrays, shared by the batch and the fallback paths.
local function Layout(Res: number, Size: number, SkirtDepth: number)
    local N = Res + 1
    local Step = Size / Res
    local Half = Size * 0.5
    local Pin = MaxHeight + SkirtDepth + 1
    local Surface = N * N
    local Mid = (Res // 2) * N + (Res // 2) + 1

    local Positions = table.create(Surface + 4 * N) :: { Vector3 }
    for J = 0, Res do
        for I = 0, Res do
            local Index = J * N + I + 1
            Positions[Index] = Vector3.new(I * Step - Half, if Index == Mid then Pin else 0, J * Step - Half)
        end
    end
    -- Skirt vertices, and for each the surface vertex it hangs under (for its colour).
    local SkirtOwner = table.create(4 * N) :: { number }
    for Side = 1, 4 do
        local Base, Stride = MeshBuilder.SideBase(Res, Side)
        for T = 0, Res do
            local Owner = Base + T * Stride
            local P = Positions[Owner]
            local Index = Surface + (Side - 1) * N + T + 1
            -- Parked outside the square (see BOUNDS ARE PINNED); the first update moves it.
            local X, Z = P.X, P.Z
            if Side == 1 then
                Z = -Half - MaxShift
            elseif Side == 2 then
                Z = Half + MaxShift
            elseif Side == 3 then
                X = -Half - MaxShift
            else
                X = Half + MaxShift
            end
            Positions[Index] = Vector3.new(X, -Pin, Z)
            SkirtOwner[Index - Surface] = Owner
        end
    end

    -- Faces as vertex-index triples (1-based into Positions).
    local Faces = table.create(2 * Res * Res + 16 * Res) :: { { number } }
    for J = 0, Res - 1 do
        for I = 0, Res - 1 do
            local A = J * N + I + 1
            local B = A + 1
            local C = A + N
            local D = C + 1
            -- (A, C, B) and (B, C, D) face +Y in Roblox's right-handed space.
            table.insert(Faces, { A, C, B })
            table.insert(Faces, { B, C, D })
        end
    end
    for Side = 1, 4 do
        local Base, Stride = MeshBuilder.SideBase(Res, Side)
        local SkirtBase = Surface + (Side - 1) * N + 1
        for T = 0, Res - 1 do
            local E0 = Base + T * Stride
            local E1 = E0 + Stride
            local S0 = SkirtBase + T
            local S1 = S0 + 1
            table.insert(Faces, { E0, S0, E1 })
            table.insert(Faces, { E1, S0, S1 })
            table.insert(Faces, { E0, E1, S0 })
            table.insert(Faces, { E1, S1, S0 })
        end
    end

    -- Colour and normal slot of each vertex (surface: itself; skirt: its owner).
    local function ColorOf(Vertex: number): number
        if Vertex <= Surface then
            return Vertex
        end
        return SkirtOwner[Vertex - Surface]
    end

    return Positions, Faces, ColorOf, Surface, Step
end

local function BuildBatch(Mesh: EditableMesh, Positions: { Vector3 }, Faces: { { number } }, ColorOf: (number) -> number, Surface: number)
    local AnyMesh = Mesh :: any
    local VIds = AnyMesh:BatchAdd(Enum.MeshAttribute.Vertex, Positions) :: { any }

    local White = Color3.new(1, 1, 1)
    local Colors = table.create(Surface, White) :: { Color3 }
    local Alphas = table.create(Surface, 1) :: { number }
    local CIds = AnyMesh:BatchAdd(Enum.MeshAttribute.Color, Colors, Alphas) :: { any }

    local NIds = table.create(Surface) :: { any }
    for Index = 1, Surface do
        NIds[Index] = Mesh:AddNormal()
    end

    local FaceVerts = table.create(#Faces) :: { { any } }
    local FaceColors = table.create(#Faces) :: { { any } }
    local FaceNormals = table.create(#Faces) :: { { any } }
    for Index, Face in Faces do
        local A, B, C = Face[1], Face[2], Face[3]
        FaceVerts[Index] = { VIds[A], VIds[B], VIds[C] }
        FaceColors[Index] = { CIds[ColorOf(A)], CIds[ColorOf(B)], CIds[ColorOf(C)] }
        FaceNormals[Index] = { NIds[ColorOf(A)], NIds[ColorOf(B)], NIds[ColorOf(C)] }
    end
    local FIds = AnyMesh:BatchAdd(Enum.MeshAttribute.Face, FaceVerts) :: { any }
    AnyMesh:BatchSetFaceAttributes(FIds, FaceColors)
    AnyMesh:BatchSetFaceAttributes(FIds, FaceNormals)
    return VIds, CIds
end

local function BuildLoop(Mesh: EditableMesh, Positions: { Vector3 }, Faces: { { number } }, ColorOf: (number) -> number, Surface: number)
    local VIds = table.create(#Positions) :: { any }
    local NIds = table.create(Surface) :: { any }
    for Index, Position in Positions do
        VIds[Index] = Mesh:AddVertex(Position)
        if Index <= Surface then
            NIds[Index] = Mesh:AddNormal()
        end
    end
    local White = Color3.new(1, 1, 1)
    local CIds = table.create(Surface) :: { any }
    for Index = 1, Surface do
        CIds[Index] = Mesh:AddColor(White, 1)
    end
    for _, Face in Faces do
        local A, B, C = Face[1], Face[2], Face[3]
        local FaceId = Mesh:AddTriangle(VIds[A], VIds[B], VIds[C])
        Mesh:SetFaceColors(FaceId, { CIds[ColorOf(A)], CIds[ColorOf(B)], CIds[ColorOf(C)] })
        Mesh:SetFaceNormals(FaceId, { NIds[ColorOf(A)], NIds[ColorOf(B)], NIds[ColorOf(C)] })
    end
    return VIds, CIds
end

--[[
    Builds a chunk for LOD `LodIndex`. Returns nil when the device's EditableMesh budget is
    exhausted or the APIs are disabled ("Allow Mesh / Image APIs"); the controller then stops
    growing the view distance. Yields (CreateMeshPartAsync).
]]
function MeshBuilder.Build(LodIndex: number, SkirtDepth: number): Chunk?
    local Lod = Water.Chunk.Lods[LodIndex]
    local Res = Lod.Resolution
    local Size = Water.Chunk.Size

    local Ok, Result = pcall(function()
        return AssetService:CreateEditableMesh()
    end)
    local Mesh = if Ok then Result :: EditableMesh? else nil
    if not Mesh then
        if not Ok then
            warn(`[WaterController] CreateEditableMesh failed: {Result}`)
        end
        return nil
    end

    local Positions, Faces, ColorOf, Surface, Step = Layout(Res, Size, SkirtDepth)

    local VIds, CIds
    if MeshBuilder.UseBatch then
        local BatchOk, A, B = pcall(BuildBatch, Mesh, Positions, Faces, ColorOf, Surface)
        if BatchOk then
            VIds, CIds = A, B
        else
            warn(`[WaterController] EditableMesh batch API unavailable, using per-vertex calls: {A}`)
            MeshBuilder.UseBatch = false
            Mesh:Destroy()
            local RetryOk, Retry = pcall(function()
                return AssetService:CreateEditableMesh()
            end)
            local RetryMesh = if RetryOk then Retry :: EditableMesh? else nil
            if not RetryMesh then
                return nil
            end
            Mesh = RetryMesh
        end
    end
    if not VIds then
        local LoopOk, A, B = pcall(BuildLoop, Mesh :: EditableMesh, Positions, Faces, ColorOf, Surface)
        if not LoopOk then
            warn(`[WaterController] chunk build failed: {A}`)
            local Failed = Mesh :: EditableMesh
            Failed:Destroy()
            return nil
        end
        VIds, CIds = A, B
    end
    local BuiltMesh = Mesh :: EditableMesh

    local PartOk, PartResult = pcall(function()
        return AssetService:CreateMeshPartAsync(Content.fromObject(BuiltMesh), {
            CollisionFidelity = Enum.CollisionFidelity.Box,
            RenderFidelity = Enum.RenderFidelity.Precise,
            FluidFidelity = Enum.FluidFidelity.Automatic,
        })
    end)
    if not PartOk or not PartResult then
        warn(`[WaterController] CreateMeshPartAsync failed: {PartResult}`)
        BuiltMesh:Destroy()
        return nil
    end
    local Part = PartResult :: MeshPart
    Part.Name = "OceanChunk"
    Part.Anchored = true
    Part.CanCollide = false
    Part.CanQuery = false
    Part.CanTouch = false
    Part.CastShadow = false
    Part.Massless = true
    Part.Material = OceanMaterial
    Part.Color = Color3.new(1, 1, 1) -- multiplies the vertex colours
    Part.Transparency = Water.Transparency

    local VertexCount = #Positions
    local Colors = table.create(Surface, Color3.new(1, 1, 1)) :: { Color3 }

    return {
        Mesh = BuiltMesh,
        Part = Part,
        LodIndex = LodIndex,
        Res = Res,
        N = Res + 1,
        Step = Step,
        Waves = Lod.WaveCount,
        UpdateEvery = math.max(1, Lod.UpdateEvery),
        SurfaceCount = Surface,
        VertexCount = VertexCount,
        VIds = VIds,
        CIds = CIds,
        Positions = Positions,
        Colors = Colors,
        Cx = 0,
        Cz = 0,
        Key = 0,
        Ring = 0,
        MinX = 0,
        MinZ = 0,
        CenterX = 0,
        CenterZ = 0,
        NextFrame = 0,
        Fresh = true,
        ColorCountdown = 0,
        EdgeRatio = { 1, 1, 1, 1 },
        EdgeWaves = { Lod.WaveCount, Lod.WaveCount, Lod.WaveCount, Lod.WaveCount },
        EdgeLod = { LodIndex, LodIndex, LodIndex, LodIndex },
    }
end

function MeshBuilder.Destroy(Target: Chunk)
    Target.Part:Destroy()
    Target.Mesh:Destroy()
end

return MeshBuilder
