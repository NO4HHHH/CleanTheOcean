--!strict
--[[
    The boot-time half of the ocean renderer: turns plain arrays (positions, faces, colour and
    normal slots) into an EditableMesh and the MeshPart that shows it. Runs ten times per session
    (nine chunks and the far plane) and never again, so it favours clarity over speed; the
    per-tick work lives in Chunk.luau.

    FIXED, SYMMETRIC BOUNDS (the v1 "water appears behind the camera and avoids it" bug). A
    MeshPart draws its mesh centred on the mesh's bounding box and scaled by Size / MeshSize.
    v1 got a symmetric box from a "pin": it parked one surface vertex high and the skirt low at
    build time -- and then the first wave update overwrote both, so the box (and with it the
    drawn mesh) shifted and shrank relative to the part. Every mesh here instead carries three
    ANCHOR vertices, (+A), (-A) and the origin, joined by one zero-area triangle (collinear, so it
    rasterises nothing) and NEVER written again. The callers size A to contain every position
    any other vertex can ever reach, so the box is exactly [-A, +A] for the mesh's whole life:
    its centre is the part's origin, MeshSize is 2A, and with Part.Size = MeshSize the scale is
    1. A vertex's local position is then exactly (World - Part.Position). MakePart checks this
    and refuses a part whose bounds or scale came out different.

    BATCH API FIRST. BatchAdd / BatchSetFaceAttributes cut the build to a handful of calls; when
    they are missing or throw, the build falls back to one call per element, and UseBatch is
    cleared so Chunk.luau writes with SetPosition / SetColor loops too.
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Water = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Data"):WaitForChild("Water"))

export type MeshSpec = {
    -- Every vertex (anchors included); 1-based indices below refer to this array.
    Positions: { Vector3 },
    -- Colour slots (one Color3 each).
    Colors: { Color3 },
    -- Normal slots 1..AutoNormals are engine-computed; slot AutoNormals + 1 is ExtraNormal.
    AutoNormals: number,
    ExtraNormal: Vector3,
    -- Per face: vertex, colour-slot and normal-slot index triples.
    FaceVerts: { { number } },
    FaceColors: { { number } },
    FaceNormals: { { number } },
    -- Optional texture coordinates: UV slots and per-face UV-slot triples.
    UVs: { Vector2 }?,
    FaceUVs: { { number } }?,
}

export type Built = {
    Mesh: EditableMesh,
    VIds: { any },
    CIds: { any },
}

local MeshBuilder = {}

-- Whether the batch API works on this client. Starts optimistic; the first failure clears it.
MeshBuilder.UseBatch = true

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

--[[
    Appends the three anchor vertices and their zero-area face to `Spec` (colour slot 1, the
    explicit normal slot so no auto normal ever averages a zero-area face).
]]
function MeshBuilder.AddAnchors(Spec: MeshSpec, Extent: Vector3)
    local Positions = Spec.Positions
    table.insert(Positions, Extent)
    local Plus = #Positions
    table.insert(Positions, -Extent)
    local Minus = #Positions
    table.insert(Positions, Vector3.zero)
    local Mid = #Positions
    local Extra = Spec.AutoNormals + 1
    table.insert(Spec.FaceVerts, { Plus, Mid, Minus })
    table.insert(Spec.FaceColors, { 1, 1, 1 })
    table.insert(Spec.FaceNormals, { Extra, Extra, Extra })
    local FaceUVs = Spec.FaceUVs
    if FaceUVs and FaceUVs ~= Spec.FaceColors then
        table.insert(FaceUVs, { 1, 1, 1 })
    end
end

local function NewMesh(): EditableMesh?
    local Ok, Result = pcall(function()
        return AssetService:CreateEditableMesh()
    end)
    if not Ok then
        warn(`[WaterController] CreateEditableMesh failed: {Result}`)
        return nil
    end
    return Result :: EditableMesh?
end

local function AddNormals(Mesh: EditableMesh, Spec: MeshSpec): { any }
    local NIds = table.create(Spec.AutoNormals + 1) :: { any }
    for Index = 1, Spec.AutoNormals do
        NIds[Index] = Mesh:AddNormal()
    end
    NIds[Spec.AutoNormals + 1] = Mesh:AddNormal(Spec.ExtraNormal)
    return NIds
end

local function BuildBatch(Mesh: EditableMesh, Spec: MeshSpec): ({ any }, { any })
    local AnyMesh = Mesh :: any
    local VIds = AnyMesh:BatchAdd(Enum.MeshAttribute.Vertex, Spec.Positions) :: { any }
    local Alphas = table.create(#Spec.Colors, 1) :: { number }
    local CIds = AnyMesh:BatchAdd(Enum.MeshAttribute.Color, Spec.Colors, Alphas) :: { any }
    local NIds = AddNormals(Mesh, Spec)

    local Count = #Spec.FaceVerts
    local FaceVerts = table.create(Count) :: { { any } }
    local FaceColors = table.create(Count) :: { { any } }
    local FaceNormals = table.create(Count) :: { { any } }
    for Index = 1, Count do
        local V, C, N = Spec.FaceVerts[Index], Spec.FaceColors[Index], Spec.FaceNormals[Index]
        FaceVerts[Index] = { VIds[V[1]], VIds[V[2]], VIds[V[3]] }
        FaceColors[Index] = { CIds[C[1]], CIds[C[2]], CIds[C[3]] }
        FaceNormals[Index] = { NIds[N[1]], NIds[N[2]], NIds[N[3]] }
    end
    local FIds = AnyMesh:BatchAdd(Enum.MeshAttribute.Face, FaceVerts) :: { any }
    AnyMesh:BatchSetFaceAttributes(FIds, FaceColors)
    AnyMesh:BatchSetFaceAttributes(FIds, FaceNormals)
    local UVs, SpecFaceUVs = Spec.UVs, Spec.FaceUVs
    if UVs and SpecFaceUVs then
        local UIds = AnyMesh:BatchAdd(Enum.MeshAttribute.UV, UVs) :: { any }
        local FaceUVs = table.create(Count) :: { { any } }
        for Index = 1, Count do
            local U = SpecFaceUVs[Index]
            FaceUVs[Index] = { UIds[U[1]], UIds[U[2]], UIds[U[3]] }
        end
        AnyMesh:BatchSetFaceAttributes(FIds, FaceUVs)
    end
    return VIds, CIds
end

local function BuildLoop(Mesh: EditableMesh, Spec: MeshSpec): ({ any }, { any })
    local VIds = table.create(#Spec.Positions) :: { any }
    for Index, Position in Spec.Positions do
        VIds[Index] = Mesh:AddVertex(Position)
    end
    local CIds = table.create(#Spec.Colors) :: { any }
    for Index, Color in Spec.Colors do
        CIds[Index] = Mesh:AddColor(Color, 1)
    end
    local NIds = AddNormals(Mesh, Spec)
    local UVs, SpecFaceUVs = Spec.UVs, Spec.FaceUVs
    local UIds: { any }? = nil
    if UVs and SpecFaceUVs then
        local Made = table.create(#UVs) :: { any }
        for Index, UV in UVs do
            Made[Index] = Mesh:AddUV(UV)
        end
        UIds = Made
    end
    for Index, V in Spec.FaceVerts do
        local C, N = Spec.FaceColors[Index], Spec.FaceNormals[Index]
        local FaceId = Mesh:AddTriangle(VIds[V[1]], VIds[V[2]], VIds[V[3]])
        Mesh:SetFaceColors(FaceId, { CIds[C[1]], CIds[C[2]], CIds[C[3]] })
        Mesh:SetFaceNormals(FaceId, { NIds[N[1]], NIds[N[2]], NIds[N[3]] })
        if UIds and SpecFaceUVs then
            local U = SpecFaceUVs[Index]
            Mesh:SetFaceUVs(FaceId, { UIds[U[1]], UIds[U[2]], UIds[U[3]] })
        end
    end
    return VIds, CIds
end

--[[
    Builds an EditableMesh from `Spec`. Returns nil when the device's EditableMesh budget is
    exhausted or the place disallows mesh APIs ("Allow Mesh / Image APIs").
]]
function MeshBuilder.Build(Spec: MeshSpec): Built?
    local Mesh = NewMesh()
    if not Mesh then
        return nil
    end
    if MeshBuilder.UseBatch then
        local Ok, A, B = pcall(BuildBatch, Mesh, Spec)
        if Ok then
            return { Mesh = Mesh, VIds = A, CIds = B }
        end
        warn(`[WaterController] EditableMesh batch API unavailable, using per-element calls: {A}`)
        MeshBuilder.UseBatch = false
        Mesh:Destroy()
        Mesh = NewMesh()
        if not Mesh then
            return nil
        end
    end
    local Fresh = Mesh :: EditableMesh
    local Ok, A, B = pcall(BuildLoop, Fresh, Spec)
    if not Ok then
        warn(`[WaterController] mesh build failed: {A}`)
        Fresh:Destroy()
        return nil
    end
    return { Mesh = Fresh, VIds = A, CIds = B }
end

--[[
    Wraps a built mesh in an anchored, non-colliding MeshPart and checks the fixed-bounds
    contract (see header): MeshSize must be 2 * Extent, and the part is sized to it so the scale
    is exactly 1. Returns nil (and destroys nothing -- the caller owns the mesh) on failure.
    Yields.
]]
function MeshBuilder.MakePart(Mesh: EditableMesh, Extent: Vector3, Name: string): MeshPart?
    local Ok, Result = pcall(function()
        return AssetService:CreateMeshPartAsync(Content.fromObject(Mesh), {
            CollisionFidelity = Enum.CollisionFidelity.Box,
            RenderFidelity = Enum.RenderFidelity.Precise,
            FluidFidelity = Enum.FluidFidelity.Automatic,
        })
    end)
    if not Ok or not Result then
        warn(`[WaterController] CreateMeshPartAsync failed: {Result}`)
        return nil
    end
    local Part = Result :: MeshPart
    local Expected = Extent * 2
    local MeshSize = Part.MeshSize
    if (MeshSize - Expected).Magnitude > 0.05 then
        warn(`[WaterController] {Name}: mesh bounds {MeshSize} differ from the anchors {Expected}`)
    end
    Part.Size = MeshSize
    if (Part.Size - MeshSize).Magnitude > 0.05 then
        -- The engine clamped the part (e.g. a part-size limit): the scale would not be 1 and
        -- every vertex would draw in the wrong place, so refuse rather than draw it wrong.
        warn(`[WaterController] {Name}: part size clamped to {Part.Size} (mesh {MeshSize}); not shown`)
        Part:Destroy()
        return nil
    end
    Part.Name = Name
    Part.Anchored = true
    Part.CanCollide = false
    Part.CanQuery = false
    Part.CanTouch = false
    Part.CastShadow = false
    Part.Massless = true
    Part.Material = OceanMaterial
    Part.Color = Color3.new(1, 1, 1) -- multiplies the vertex colours
    Part.Transparency = Water.Transparency
    -- Surface texture: a SurfaceAppearance authored in Studio (scripts can't set its texture
    -- ids), cloned onto every ocean part if it exists. Needs the mesh UVs (Chunk.luau).
    local Assets = ReplicatedStorage:FindFirstChild("Assets")
    local Look = Assets and Assets:FindFirstChild(Water.Texture.SurfaceAppearance)
    if Look and Look:IsA("SurfaceAppearance") then
        Look:Clone().Parent = Part
    end
    return Part
end

-- 8-bit colour cache shared by the chunks and the far plane. A clear only costs re-creating
-- Color3s; the cap bounds memory.
local ColorCache: { [number]: Color3 } = {}
local CacheCount = 0
local CacheLimit = 65536

local function Byte(Value: number): number
    local V = (Value * 255 + 0.5) // 1
    if V < 0 then
        return 0
    elseif V > 255 then
        return 255
    end
    return V
end

-- Colours are quantised to the 8 bits per channel the GPU stores anyway, then cached.
function MeshBuilder.Quantise(R: number, G: number, B: number): Color3
    local R8, G8, B8 = Byte(R), Byte(G), Byte(B)
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

return MeshBuilder
