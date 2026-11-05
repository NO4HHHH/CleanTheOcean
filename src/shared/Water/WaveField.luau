--!native
--!optimize 2
--!strict
--[[
    The ocean surface as pure maths: a sum of Gerstner waves (see Data/Water for the formula and
    tuning). Server and client run this same module against the same clock
    (workspace:GetServerTimeNow), so buoyant objects simulated on the server ride exactly the
    swell the client's chunked mesh draws -- there is nothing to replicate.

    WHY IT IS SHAPED LIKE THIS -- it is the hottest code in the game. The mesh calls Displace for
    every vertex every update (tens of thousands of calls a frame), so:
      * every per-wave constant (k*Dx, k*Dz, horizontal amplitude, Jacobian weights...) is
        precomputed once into flat upvalue arrays; the inner loop is multiply-adds and one
        sin/cos pair per wave, no table or Vector3 created;
      * the time term (omega*t + phase) is the same for every vertex of a frame, so it is
        computed once per distinct Time and cached, then reduced mod 2*pi -- server time is
        ~1.7e9 s and wrapping it keeps the phase precise;
      * results come back as multiple returns, not tables.

    HeightAt has to answer "how high is the water ABOVE this world point", but Gerstner moves
    points sideways as well as up. It inverts the horizontal shift by fixed-point iteration
    (P0 <- Target - Shift(P0)); the map's contraction factor is about the summed Steepness
    (< 1), so three corrections land within a fraction of a stud of the rendered surface.

    Crest is the foam factor: one minus the determinant of the horizontal Jacobian. Points
    bunch up (determinant falls) on sharp crests, so this lights foam exactly on the peaks and
    never in troughs; it is rescaled from FoamThreshold..(0.75 * sum of Steepness) to 0..1.
]]

local Water = require(script.Parent.Parent.Data.Water)

local TAU = 2 * math.pi
local Sin = math.sin
local Cos = math.cos
local Sqrt = math.sqrt

local SeaLevel = Water.SeaLevel

-- Sort a copy largest amplitude first: WaveCount arguments take the first N.
local Sorted = table.clone(Water.Waves)
table.sort(Sorted, function(A, B)
    return A.Amplitude > B.Amplitude
end)

local WaveTotal = #Sorted

local KDx = table.create(WaveTotal, 0) :: { number } -- k * Dx
local KDz = table.create(WaveTotal, 0) :: { number } -- k * Dz
local Omega = table.create(WaveTotal, 0) :: { number }
local Phase0 = table.create(WaveTotal, 0) :: { number }
local Amp = table.create(WaveTotal, 0) :: { number }
local HDx = table.create(WaveTotal, 0) :: { number } -- horizontal amplitude (S/k) * Dx
local HDz = table.create(WaveTotal, 0) :: { number }
local SDxx = table.create(WaveTotal, 0) :: { number } -- Jacobian weights S * Dx^2 etc.
local SDzz = table.create(WaveTotal, 0) :: { number }
local SDxz = table.create(WaveTotal, 0) :: { number }
local Steep = table.create(WaveTotal, 0) :: { number }
local KADx = table.create(WaveTotal, 0) :: { number } -- normal weights k * A * Dx
local KADz = table.create(WaveTotal, 0) :: { number }
local PhaseT = table.create(WaveTotal, 0) :: { number } -- per-frame cache: omega*t + phase0

local SteepSum = 0
for Index, Wave in Sorted do
    local Radians = math.rad(Wave.Angle)
    local Dx, Dz = Cos(Radians), Sin(Radians)
    local K = TAU / Wave.Wavelength
    local S = Wave.Steepness

    KDx[Index] = K * Dx
    KDz[Index] = K * Dz
    Omega[Index] = Sqrt(Water.Gravity * K)
    -- Deterministic per-wave phase so the waves don't all crest together at the origin.
    Phase0[Index] = (Index * 2.39996323) % TAU
    Amp[Index] = Wave.Amplitude
    HDx[Index] = (S / K) * Dx
    HDz[Index] = (S / K) * Dz
    SDxx[Index] = S * Dx * Dx
    SDzz[Index] = S * Dz * Dz
    SDxz[Index] = S * Dx * Dz
    Steep[Index] = S
    KADx[Index] = K * Wave.Amplitude * Dx
    KADz[Index] = K * Wave.Amplitude * Dz
    SteepSum += S
end

local FoamThreshold = Water.FoamThreshold
-- Full foam at 75% of the steepness sum, not at the sum itself: all waves cresting in phase at
-- one point never happens (sampled maximum of Fold with the shipped waves is ~0.64 of 0.82), so
-- scaling to the sum would leave the brightest crests at about two thirds foam.
local FoamPeak = SteepSum * 0.75
local FoamScale = if FoamPeak > FoamThreshold then 1 / (FoamPeak - FoamThreshold) else 0

--[[
    CALM NEAR SPAWN (Data/Water.Calm). The whole displacement of a calm-grid point -- sideways
    shift, height above SeaLevel and foam -- is multiplied by M(X, Z), which is Calm.Min within
    Calm.Inner of the origin and rises by smoothstep to 1 at Calm.Outer. It is evaluated at the
    CALM point (the grid point before it is displaced), so the mesh, which only knows grid points,
    and HeightAt, which inverts to the calm point, see the same factor. M varies over hundreds of
    studs while the shift is at most ~34, so the fixed-point inversion still converges.
]]
local CalmInner = Water.Calm.Inner
local CalmOuter = math.max(Water.Calm.Outer, CalmInner + 1)
local CalmMin = math.clamp(Water.Calm.Min, 0, 1)
local CalmInnerSq = CalmInner * CalmInner
local CalmOuterSq = CalmOuter * CalmOuter
local CalmInvSpan = 1 / (CalmOuter - CalmInner)

local function CalmAt(X: number, Z: number): number
    local D2 = X * X + Z * Z
    if D2 >= CalmOuterSq then
        return 1
    elseif D2 <= CalmInnerSq then
        return CalmMin
    end
    local T = (Sqrt(D2) - CalmInner) * CalmInvSpan
    return CalmMin + (1 - CalmMin) * (T * T * (3 - 2 * T))
end

local CachedTime = -math.huge

local function Refresh(Time: number)
    if Time ~= CachedTime then
        CachedTime = Time
        for Index = 1, WaveTotal do
            PhaseT[Index] = (Omega[Index] * Time + Phase0[Index]) % TAU
        end
    end
end

local function Count(WaveCount: number?): number
    if WaveCount == nil or WaveCount > WaveTotal then
        return WaveTotal
    elseif WaveCount < 0 then
        return 0
    end
    return WaveCount
end

-- Horizontal shift and height of the calm point (X, Z). Phase cache must be fresh.
local function Shift(X: number, Z: number, N: number): (number, number, number)
    local DX, DZ, Y = 0, 0, SeaLevel
    for Index = 1, N do
        local Theta = KDx[Index] * X + KDz[Index] * Z - PhaseT[Index]
        local C = Cos(Theta)
        DX += HDx[Index] * C
        DZ += HDz[Index] * C
        Y += Amp[Index] * Sin(Theta)
    end
    local M = CalmAt(X, Z)
    return DX * M, DZ * M, SeaLevel + (Y - SeaLevel) * M
end

-- Calm-grid point whose displaced position lies above world (X, Z).
local function Invert(X: number, Z: number, N: number): (number, number, number)
    local X0, Z0 = X, Z
    local DX, DZ, Y = Shift(X0, Z0, N)
    for _ = 1, 3 do
        X0 = X - DX
        Z0 = Z - DZ
        DX, DZ, Y = Shift(X0, Z0, N)
    end
    return X0, Z0, Y
end

local WaveField = {}

WaveField.WaveTotal = WaveTotal

function WaveField.Now(): number
    return workspace:GetServerTimeNow()
end

function WaveField.Displace(X: number, Z: number, Time: number, WaveCount: number?): (number, number, number, number)
    Refresh(Time)
    local N = Count(WaveCount)
    local DX, DZ, Y = 0, 0, SeaLevel
    local Sxx, Szz, Sxz = 0, 0, 0
    for Index = 1, N do
        local Theta = KDx[Index] * X + KDz[Index] * Z - PhaseT[Index]
        local S = Sin(Theta)
        local C = Cos(Theta)
        DX += HDx[Index] * C
        DZ += HDz[Index] * C
        Y += Amp[Index] * S
        Sxx += SDxx[Index] * S
        Szz += SDzz[Index] * S
        Sxz += SDxz[Index] * S
    end
    local M = CalmAt(X, Z)
    -- Foam from the FULL-size wave shape, then faded by the calming. Scaling the fold first
    -- (as before) pushed it under FoamThreshold everywhere near spawn: no foam at all there.
    local Fold = 1 - ((1 - Sxx) * (1 - Szz) - Sxz * Sxz)
    local Crest = (Fold - FoamThreshold) * FoamScale
    if Crest < 0 then
        Crest = 0
    elseif Crest > 1 then
        Crest = 1
    end
    return DX * M, SeaLevel + (Y - SeaLevel) * M, DZ * M, Crest * M
end

function WaveField.HeightAt(X: number, Z: number, Time: number, WaveCount: number?): number
    Refresh(Time)
    local _, _, Y = Invert(X, Z, Count(WaveCount))
    return Y
end

function WaveField.SurfaceAt(X: number, Z: number, Time: number, WaveCount: number?): (number, Vector3)
    Refresh(Time)
    local N = Count(WaveCount)
    local X0, Z0, Y = Invert(X, Z, N)
    local Nx, Ny, Nz = 0, 1, 0
    for Index = 1, N do
        local Theta = KDx[Index] * X0 + KDz[Index] * Z0 - PhaseT[Index]
        local C = Cos(Theta)
        Nx -= KADx[Index] * C
        Nz -= KADz[Index] * C
        Ny -= Steep[Index] * Sin(Theta)
    end
    -- Calming scales every slope term (Ny's deviation from 1 included) by the same factor.
    local M = CalmAt(X0, Z0)
    Nx *= M
    Nz *= M
    Ny = 1 + (Ny - 1) * M
    local Length = Sqrt(Nx * Nx + Ny * Ny + Nz * Nz)
    if Length < 1e-6 then
        return Y, Vector3.yAxis
    end
    return Y, Vector3.new(Nx / Length, Ny / Length, Nz / Length)
end

-- Per-wave column / row phase tables for DisplaceGrid, grown on demand and reused.
local GridCapA = 0
local GridCapB = 0
local GridCosA: { number } = {}
local GridSinA: { number } = {}
local GridCosB: { number } = {}
local GridSinB: { number } = {}

--[[
    Displace for a whole regular, world-aligned grid at once, without trig per vertex.

    The grid point (I, J) is X = (StartI + I) * Step, Z = (StartJ + J) * Step for I = 0..CountX-1,
    J = 0..CountZ-1. Points are addressed by INTEGER grid index times Step (not X0 + I * Step) so
    two callers that share a grid point (neighbouring ocean chunks) feed bit-identical X and Z.

    Each wave's phase is separable on such a grid:
        theta(I, J) = k Dx X + k Dz Z - (omega t + phase) = A_I + B_J
        A_I = k Dx X_I - (omega t + phase)   (one per column)
        B_J = k Dz Z_J                        (one per row)
    so cos/sin are taken CountX + CountZ times per wave instead of CountX * CountZ times, and
    each vertex combines them with cos(A+B) = cosA cosB - sinA sinB,
    sin(A+B) = sinA cosB + cosA sinB: four multiplies and two adds instead of two trig calls.

    Output (row-major, J outer, I inner, 1-based: Index = J * CountX + I + 1) goes into the
    caller-owned arrays: OutX/OutZ = horizontal shift DX/DZ, OutY = absolute height (SeaLevel
    included), OutCrest = foam factor -- exactly what Displace returns for that point. Nothing
    is allocated once the phase tables have grown to the largest grid.

    Equivalence with Displace: the only difference is cos(A+B) by the angle-sum identity versus
    cos of the summed angle. Checked by porting both functions line for line to Python (IEEE
    doubles, as Luau): over a 65x65 grid at X, Z up to +-10,000 studs and server time ~1.7e9 s,
    the largest difference in DX/Y/DZ was ~7e-13 studs and in Crest ~7e-14.
]]
function WaveField.DisplaceGrid(
    StartI: number,
    StartJ: number,
    Step: number,
    CountX: number,
    CountZ: number,
    Time: number,
    WaveCount: number?,
    OutX: { number },
    OutY: { number },
    OutZ: { number },
    OutCrest: { number }
)
    Refresh(Time)
    local N = Count(WaveCount)

    local NeedA = N * CountX
    if NeedA > GridCapA then
        GridCosA = table.create(NeedA, 0)
        GridSinA = table.create(NeedA, 0)
        GridCapA = NeedA
    end
    local NeedB = N * CountZ
    if NeedB > GridCapB then
        GridCosB = table.create(NeedB, 0)
        GridSinB = table.create(NeedB, 0)
        GridCapB = NeedB
    end
    local CosA, SinA, CosB, SinB = GridCosA, GridSinA, GridCosB, GridSinB

    for W = 1, N do
        local Kx = KDx[W]
        local Kz = KDz[W]
        local P = PhaseT[W]
        local BaseA = (W - 1) * CountX
        for I = 0, CountX - 1 do
            local A = Kx * ((StartI + I) * Step) - P
            CosA[BaseA + I + 1] = Cos(A)
            SinA[BaseA + I + 1] = Sin(A)
        end
        local BaseB = (W - 1) * CountZ
        for J = 0, CountZ - 1 do
            local B = Kz * ((StartJ + J) * Step)
            CosB[BaseB + J + 1] = Cos(B)
            SinB[BaseB + J + 1] = Sin(B)
        end
    end

    -- Calming: skip the per-vertex factor when the whole grid lies beyond Calm.Outer.
    local GX0, GX1 = StartI * Step, (StartI + CountX - 1) * Step
    local GZ0, GZ1 = StartJ * Step, (StartJ + CountZ - 1) * Step
    local NearX = math.max(GX0, 0, -GX1)
    local NearZ = math.max(GZ0, 0, -GZ1)
    local AnyCalm = NearX * NearX + NearZ * NearZ < CalmOuterSq

    local Index = 0
    for J = 1, CountZ do
        local GZ = (StartJ + J - 1) * Step
        for I = 1, CountX do
            Index += 1
            local DX, DZ, Y = 0, 0, SeaLevel
            local Sxx, Szz, Sxz = 0, 0, 0
            local IA = I
            local IB = J
            for W = 1, N do
                local Ca, Sa = CosA[IA], SinA[IA]
                local Cb, Sb = CosB[IB], SinB[IB]
                local C = Ca * Cb - Sa * Sb
                local S = Sa * Cb + Ca * Sb
                DX += HDx[W] * C
                DZ += HDz[W] * C
                Y += Amp[W] * S
                Sxx += SDxx[W] * S
                Szz += SDzz[W] * S
                Sxz += SDxz[W] * S
                IA += CountX
                IB += CountZ
            end
            local M = if AnyCalm then CalmAt((StartI + I - 1) * Step, GZ) else 1
            local Fold = 1 - ((1 - Sxx) * (1 - Szz) - Sxz * Sxz) -- full-size shape (see Displace)
            local Crest = (Fold - FoamThreshold) * FoamScale
            if Crest < 0 then
                Crest = 0
            elseif Crest > 1 then
                Crest = 1
            end
            OutX[Index] = DX * M
            OutY[Index] = SeaLevel + (Y - SeaLevel) * M
            OutZ[Index] = DZ * M
            OutCrest[Index] = Crest * M
        end
    end
end

return table.freeze(WaveField)
