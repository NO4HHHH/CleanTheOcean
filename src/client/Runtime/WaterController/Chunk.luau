--!native
--!optimize 2
--!strict
--[[
    One wave chunk: a Chunk.Size-stud square of the 3x3 around the camera, built once, then moved
    between cells and re-displaced every update tick.

    A FLAT PANE, NO SKIRTS. The surface is a single grid sheet. Earlier versions hung a wall
    ("skirt") under every edge to hide cracks; with a see-through sea those walls showed as a
    line along every chunk edge. They are gone because the cracks cannot happen: every chunk has
    the same Resolution, sums every wave, and is updated with the tick's single Time and camera
    position, and the controller always writes all nine chunks of a tick in the SAME frame. Its
    vertices sit on ONE world grid -- vertex (I, J) of cell (Cx, Cz) is world grid index
    (Cx * Res + I, Cz * Res + J), at X = index * Step -- so the edge two neighbours share is the
    same grid indices, the same X and Z bit for bit, the same Time and the same fade: identical
    inputs, identical outputs, edges that meet exactly.

    FADE. Each vertex's displacement (DX, Y - SeaLevel, DZ) and foam are multiplied by
    F = 1 - smoothstep(Fade.Inner, Fade.Outer, horizontal distance from the camera), so the waves
    melt into the flat far ring at the 3x3 border. The fade follows the camera continuously, so
    a cell re-assignment pops nothing.

    ONLY WHAT MOVES IS WRITTEN (the lag fix). Within a chunk, only vertices inside Fade.Outer of
    the camera wave; everything else is the flat grid and stays put. Each update walks the
    union of this tick's waving rectangle and last tick's, writes the vertices that wave now plus
    the ones that just stopped (back to flat), and skips the rest -- one BatchSetValues of just
    those. Colours likewise: only that rectangle, every few ticks (foam follows the crests), and
    the whole chunk only when it lands on a new cell. Colour is the gradient at the vertex's world
    grid point plus its faded foam, which at the faded edge is exactly the far ring's colour.

    COLOUR CACHE. A vertex's gradient colour depends only on its world point, so it is computed
    once when the chunk lands on a cell (BaseR/G/B) and reused; per tick only the foam is mixed
    in, and a vertex's colour is written only when its foam level (Crest quantised to 1/32)
    actually changed. Colour passes are staggered across chunks by the controller.

    UNDERSIDE NORMALS. The underside faces (so the sea is visible from below) share one explicit
    straight-down normal instead of a second set of engine-computed normals: the engine
    recomputes auto normals every time a mesh is written, so this halves that work.

    UVS (for a surface texture). Each surface vertex gets U, V = cell-local X, Z / Texture
    TileStuds. TileStuds divides Chunk.Size, so a chunk's right-edge U is a whole number of tiles
    and the next chunk starts at 0 on the same texel of a tiling texture: seamless, and never
    rewritten when a chunk moves cell. The UVs ride the wave's sideways shift, so the texture
    moves with the water for free.

    LOCAL SPACE. The part sits at the cell centre, Y = SeaLevel. The mesh's bounds are pinned by
    never-written anchors (MeshBuilder header), so the scale is 1 and the bounds centre is the
    part origin: local position = World - (CenterX, SeaLevel, CenterZ).

    WINDING. Grid corners A = (I, J), B = (I+1, J), C = (I, J+1), D = (I+1, J+1), quad side s.
    Top faces (A, C, B) and (B, C, D):
        (C - A) x (B - A) = (0, 0, s) x (s, 0, 0) = (0, s^2, 0)
        (C - B) x (D - B) = (-s, 0, s) x (0, 0, s) = (0, s^2, 0)
    i.e. +Y. Underside faces (A, B, C) and (B, D, C) are the same triangles reversed so the sea is
    visible from below; they reuse vertices and colours but have their own auto-normal slots.

    BUDGET (per mesh: 60,000 vertices / 20,000 triangles). Resolution R: (R+1)^2 + 3 vertices,
    4R^2 + 1 triangles with the underside (dropped if that would pass 20,000, R >= 71). R = 64:
    4,228 vertices, 16,385 triangles.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaveField = require(Shared:WaitForChild("Water"):WaitForChild("WaveField"))
local WaterColor = require(Shared:WaitForChild("Water"):WaitForChild("WaterColor"))
local MeshBuilder = require(script.Parent.MeshBuilder)

local DisplaceGrid = WaveField.DisplaceGrid
local BaseColor = WaterColor.Base
local MixFoam = WaterColor.MixFoam
local Quantise = MeshBuilder.Quantise
local Sqrt = math.sqrt
local Max = math.max
local Min = math.min

local SeaLevel = Water.SeaLevel
local Size = Water.Chunk.Size
local Half = Size * 0.5
local Res = math.clamp(math.floor(Water.Chunk.Resolution), 1, 99)
local N = Res + 1
local Step = Size / Res
local Surface = N * N
local Underside = 4 * Res * Res + 1 <= 20000

local MaxHeight = 0
local MaxShift = 0
for _, Wave in Water.Waves do
    MaxHeight += Wave.Amplitude
    MaxShift += Wave.Steepness * Wave.Wavelength / (2 * math.pi)
end
local Extent = Vector3.new(Half + MaxShift + 1, MaxHeight + 1, Half + MaxShift + 1)

-- Fade radii (Outer <= Size so the 3x3 border is always flat; Inner < Outer).
local FadeOuter = Min(Water.Fade.Outer, Size)
local FadeInner = math.clamp(Water.Fade.Inner, 0, FadeOuter * 0.999)
local OuterSq = FadeOuter * FadeOuter
local InnerSq = FadeInner * FadeInner
local InvSpan = 1 / (FadeOuter - FadeInner)

-- Foam is compared in 1/FoamLevels steps: finer than 8-bit colour can show over the blend.
local FoamLevels = 32
local TileStuds = Water.Texture.TileStuds

export type Chunk = {
    Mesh: EditableMesh,
    Part: MeshPart,
    VIds: { any }, -- surface vertex ids (never the anchors)
    CIds: { any }, -- colour slot per surface vertex
    Waved: { boolean }, -- vertex currently displaced (not on the flat grid)
    Crest: { number }, -- faded foam per vertex at the last write
    BaseR: { number }, -- gradient colour per vertex for the current cell (no foam)
    BaseG: { number },
    BaseB: { number },
    LastFoam: { number }, -- quantised foam level last written as a colour (-1 = unwritten)
    -- Last tick's waving rectangle (local indices); I0 > I1 = none.
    I0: number,
    I1: number,
    J0: number,
    J1: number,
    -- Area walked since the last colour write (it still needs recolouring); CI0 > CI1 = none.
    CI0: number,
    CI1: number,
    CJ0: number,
    CJ1: number,
    Cx: number,
    Cz: number,
    Rank: number, -- slot priority in the 3x3 (1 = centre)
    Assigned: boolean,
    Shown: boolean,
    Pending: boolean, -- assigned to a new cell, not yet written there
}

local ChunkModule = {}

ChunkModule.Res = Res
ChunkModule.FadeOuter = FadeOuter
ChunkModule.Underside = Underside

-- Flat local positions, identical for every chunk (the grid is cell-relative).
local FlatLocal = table.create(Surface) :: { Vector3 }
for J = 0, Res do
    for I = 0, Res do
        FlatLocal[J * N + I + 1] = Vector3.new(I * Step - Half, 0, J * Step - Half)
    end
end

-- Scratch shared by every chunk (one chunk is written at a time). Cleared, never reallocated.
local SX = table.create(Surface, 0) :: { number }
local SY = table.create(Surface, 0) :: { number }
local SZ = table.create(Surface, 0) :: { number }
local SC = table.create(Surface, 0) :: { number }
local WriteIds = table.create(Surface) :: { any }
local WritePos = table.create(Surface) :: { Vector3 }
local ColorIds = table.create(Surface) :: { any }
local ColorVals = table.create(Surface) :: { Color3 }

--[[
    Builds one chunk (unassigned, unparented). Returns nil when the mesh budget is exhausted.
    Yields.
]]
function ChunkModule.Build(): Chunk?
    local Positions = table.create(Surface + 3) :: { Vector3 }
    for Index = 1, Surface do
        Positions[Index] = FlatLocal[Index]
    end
    local Colors = table.create(Surface, Color3.new(1, 1, 1)) :: { Color3 }
    local UVs = table.create(Surface) :: { Vector2 }
    for J = 0, Res do
        for I = 0, Res do
            UVs[J * N + I + 1] = Vector2.new(I * Step / TileStuds, J * Step / TileStuds)
        end
    end

    local Triangles = 2 * Res * Res * (if Underside then 2 else 1) + 1
    local FaceVerts = table.create(Triangles) :: { { number } }
    local FaceColors = table.create(Triangles) :: { { number } }
    local FaceNormals = table.create(Triangles) :: { { number } }
    for J = 0, Res - 1 do
        for I = 0, Res - 1 do
            local A = J * N + I + 1
            local B = A + 1
            local C = A + N
            local D = C + 1
            -- Top, +Y (see WINDING).
            table.insert(FaceVerts, { A, C, B })
            table.insert(FaceColors, { A, C, B })
            table.insert(FaceNormals, { A, C, B })
            table.insert(FaceVerts, { B, C, D })
            table.insert(FaceColors, { B, C, D })
            table.insert(FaceNormals, { B, C, D })
            if Underside then
                -- One shared explicit straight-down normal (see UNDERSIDE NORMALS).
                local Down = Surface + 1
                table.insert(FaceVerts, { A, B, C })
                table.insert(FaceColors, { A, B, C })
                table.insert(FaceNormals, { Down, Down, Down })
                table.insert(FaceVerts, { B, D, C })
                table.insert(FaceColors, { B, D, C })
                table.insert(FaceNormals, { Down, Down, Down })
            end
        end
    end

    local Spec: MeshBuilder.MeshSpec = {
        Positions = Positions,
        Colors = Colors,
        AutoNormals = Surface,
        ExtraNormal = -Vector3.yAxis, -- the underside normal (also the anchors' zero-area face)
        FaceVerts = FaceVerts,
        FaceColors = FaceColors,
        FaceNormals = FaceNormals,
        UVs = UVs,
        FaceUVs = FaceColors, -- one UV per surface vertex, same indices as the colours
    }
    MeshBuilder.AddAnchors(Spec, Extent)

    local Built = MeshBuilder.Build(Spec)
    if not Built then
        return nil
    end
    local Part = MeshBuilder.MakePart(Built.Mesh, Extent, "OceanChunk")
    if not Part then
        Built.Mesh:Destroy()
        return nil
    end

    local VIds = table.create(Surface) :: { any }
    table.move(Built.VIds, 1, Surface, 1, VIds)

    return {
        Mesh = Built.Mesh,
        Part = Part,
        VIds = VIds,
        CIds = Built.CIds,
        Waved = table.create(Surface, false),
        Crest = table.create(Surface, 0),
        BaseR = table.create(Surface, 0),
        BaseG = table.create(Surface, 0),
        BaseB = table.create(Surface, 0),
        LastFoam = table.create(Surface, -1),
        I0 = 1,
        I1 = 0,
        J0 = 1,
        J1 = 0,
        CI0 = 1,
        CI1 = 0,
        CJ0 = 1,
        CJ1 = 0,
        Cx = 0,
        Cz = 0,
        Rank = 0,
        Assigned = false,
        Shown = false,
        Pending = false,
    }
end

-- Smallest horizontal distance from (CamX, CamZ) to the chunk's cell square.
function ChunkModule.Distance(Target: Chunk, CamX: number, CamZ: number): number
    local MinX, MinZ = Target.Cx * Size, Target.Cz * Size
    local DX = Max(MinX - CamX, 0, CamX - (MinX + Size))
    local DZ = Max(MinZ - CamZ, 0, CamZ - (MinZ + Size))
    return Sqrt(DX * DX + DZ * DZ)
end

-- Whether the chunk has anything to write this tick (waves near the camera, or leftovers).
function ChunkModule.NeedsUpdate(Target: Chunk, CamX: number, CamZ: number): boolean
    return Target.Pending
        or Target.I0 <= Target.I1 -- waved last tick: those vertices go back to flat
        or Target.CI0 <= Target.CI1 -- colours still owed for an area that changed
        or ChunkModule.Distance(Target, CamX, CamZ) < FadeOuter
end

--[[
    Re-displaces `Target` at the tick's Time and camera position and writes the vertices that
    changed; with DoColor also rewrites the colours of the area that waves (the whole chunk when
    it has just been moved). UseBatch picks BatchSetValues over per-element calls.
]]
function ChunkModule.Update(Target: Chunk, Time: number, CamX: number, CamZ: number, DoColor: boolean, UseBatch: boolean)
    local MinI, MinJ = Target.Cx * Res, Target.Cz * Res
    local CenterX, CenterZ = (Target.Cx + 0.5) * Size, (Target.Cz + 0.5) * Size
    local Full = Target.Pending
    local Waved = Target.Waved
    local Crest = Target.Crest
    local VIds = Target.VIds

    -- This tick's waving rectangle: vertices within Fade.Outer of the camera (local indices).
    local I0 = Max(0, math.ceil((CamX - FadeOuter) / Step) - MinI)
    local I1 = Min(Res, math.floor((CamX + FadeOuter) / Step) - MinI)
    local J0 = Max(0, math.ceil((CamZ - FadeOuter) / Step) - MinJ)
    local J1 = Min(Res, math.floor((CamZ + FadeOuter) / Step) - MinJ)
    local Waving = I0 <= I1 and J0 <= J1
    local CountX = I1 - I0 + 1
    if Waving then
        debug.profilebegin("Ocean.DisplaceGrid")
        DisplaceGrid(MinI + I0, MinJ + J0, Step, CountX, J1 - J0 + 1, Time, nil, SX, SY, SZ, SC)
        debug.profileend()
    end

    -- Area to walk: everything on a fresh cell, else this rectangle united with last tick's.
    local WI0, WI1, WJ0, WJ1
    if Full then
        WI0, WI1, WJ0, WJ1 = 0, Res, 0, Res
    else
        WI0, WI1, WJ0, WJ1 = I0, I1, J0, J1
        if Target.I0 <= Target.I1 then
            if Waving then
                WI0, WI1 = Min(WI0, Target.I0), Max(WI1, Target.I1)
                WJ0, WJ1 = Min(WJ0, Target.J0), Max(WJ1, Target.J1)
            else
                WI0, WI1, WJ0, WJ1 = Target.I0, Target.I1, Target.J0, Target.J1
            end
        end
    end

    debug.profilebegin("Ocean.Walk")
    table.clear(WriteIds)
    table.clear(WritePos)
    local Count = 0
    local NewI0, NewI1, NewJ0, NewJ1 = Res + 1, -1, Res + 1, -1
    if WI0 <= WI1 and WJ0 <= WJ1 then
        for J = WJ0, WJ1 do
            local GZ = (MinJ + J) * Step
            local DZc = GZ - CamZ
            local DZc2 = DZc * DZc
            local Row = J * N
            local InRows = Waving and J >= J0 and J <= J1
            for I = WI0, WI1 do
                local K = Row + I + 1
                local F = 0
                if InRows and I >= I0 and I <= I1 then
                    local GX = (MinI + I) * Step
                    local DXc = GX - CamX
                    local D2 = DXc * DXc + DZc2
                    if D2 < OuterSq then
                        if D2 <= InnerSq then
                            F = 1
                        else
                            local T = (Sqrt(D2) - FadeInner) * InvSpan
                            F = 1 - T * T * (3 - 2 * T)
                        end
                    end
                    if F > 0 then
                        local L = (J - J0) * CountX + (I - I0) + 1
                        Count += 1
                        WriteIds[Count] = VIds[K]
                        WritePos[Count] = Vector3.new(GX - CenterX + SX[L] * F, (SY[L] - SeaLevel) * F, GZ - CenterZ + SZ[L] * F)
                        Crest[K] = SC[L] * F
                        Waved[K] = true
                        if I < NewI0 then
                            NewI0 = I
                        end
                        if I > NewI1 then
                            NewI1 = I
                        end
                        if J < NewJ0 then
                            NewJ0 = J
                        end
                        if J > NewJ1 then
                            NewJ1 = J
                        end
                    end
                end
                if F <= 0 and Waved[K] then
                    -- Just stopped waving: back to the flat grid. (Not every vertex on a fresh
                    -- cell: positions are cell-relative, so a flat vertex is already right.)
                    Count += 1
                    WriteIds[Count] = VIds[K]
                    WritePos[Count] = FlatLocal[K]
                    Crest[K] = 0
                    Waved[K] = false
                end
            end
        end
    end

    debug.profileend()

    if Count > 0 then
        debug.profilebegin("Ocean.WritePositions")
        local Mesh = Target.Mesh
        if UseBatch then
            (Mesh :: any):BatchSetValues(WriteIds, WritePos)
        else
            for Index = 1, Count do
                Mesh:SetPosition(WriteIds[Index], WritePos[Index])
            end
        end
        debug.profileend()
    end

    -- A fresh cell: cache the gradient colour of every vertex there, and mark every colour
    -- unwritten so the pass below repaints the whole chunk.
    local BaseR, BaseG, BaseB, LastFoam = Target.BaseR, Target.BaseG, Target.BaseB, Target.LastFoam
    if Full then
        for J = 0, Res do
            local GZ = (MinJ + J) * Step
            local Row = J * N
            for I = 0, Res do
                local K = Row + I + 1
                BaseR[K], BaseG[K], BaseB[K] = BaseColor((MinI + I) * Step, GZ)
                LastFoam[K] = -1
            end
        end
    end

    -- Colours: everything walked since the last colour write (foam moves with the crests, and a
    -- vertex that went flat on a tick without a colour write still carries old foam), or the
    -- whole chunk on a new cell.
    if WI0 <= WI1 and WJ0 <= WJ1 then
        if Target.CI0 <= Target.CI1 and not Full then
            Target.CI0, Target.CI1 = Min(Target.CI0, WI0), Max(Target.CI1, WI1)
            Target.CJ0, Target.CJ1 = Min(Target.CJ0, WJ0), Max(Target.CJ1, WJ1)
        else
            Target.CI0, Target.CI1, Target.CJ0, Target.CJ1 = WI0, WI1, WJ0, WJ1
        end
    end
    if DoColor and Target.CI0 <= Target.CI1 then
        debug.profilebegin("Ocean.Colors")
        WI0, WI1, WJ0, WJ1 = Target.CI0, Target.CI1, Target.CJ0, Target.CJ1
        Target.CI0, Target.CI1 = 1, 0
        table.clear(ColorIds)
        table.clear(ColorVals)
        local CIds = Target.CIds
        local CCount = 0
        for J = WJ0, WJ1 do
            local Row = J * N
            for I = WI0, WI1 do
                local K = Row + I + 1
                -- Only vertices whose foam level changed (or that were never painted here).
                local Level = (Crest[K] * FoamLevels + 0.5) // 1
                if Level ~= LastFoam[K] then
                    LastFoam[K] = Level
                    local R, G, B = MixFoam(BaseR[K], BaseG[K], BaseB[K], Level / FoamLevels)
                    CCount += 1
                    ColorIds[CCount] = CIds[K]
                    ColorVals[CCount] = Quantise(R, G, B)
                end
            end
        end
        if CCount > 0 then
            local Mesh = Target.Mesh
            if UseBatch then
                (Mesh :: any):BatchSetValues(ColorIds, ColorVals)
            else
                for Index = 1, CCount do
                    Mesh:SetColor(ColorIds[Index], ColorVals[Index])
                end
            end
        end
        debug.profileend()
    end

    Target.I0, Target.I1, Target.J0, Target.J1 = NewI0, NewI1, NewJ0, NewJ1
end

function ChunkModule.Destroy(Target: Chunk)
    Target.Part:Destroy()
    Target.Mesh:Destroy()
end

return ChunkModule
