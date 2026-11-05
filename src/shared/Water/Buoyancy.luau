--!native
--!optimize 2
--!strict
--[[
    Buoyancy force maths: one assembly, one step. No service state, no tags, no players -- the
    server's BuoyancyService drives it today, and a client could drive the same functions for a
    boat it owns, because the forces only act where the assembly is simulated.

    WHY TWO CONSTRAINTS AND NOT ONE PER SAMPLE POINT. Per assembly there is exactly ONE VectorForce
    (applied at the centre of mass) and ONE Torque, both RelativeTo World. Each step samples a
    SampleGrid x SampleGrid grid of points across the bottom face of the assembly's box (rotated
    with the part), lets each submerged point push up in proportion to its submersion depth, and
    sums those point forces into a net force plus the net torque about the centre of mass. That is
    mathematically the same as N forces at N points, but it is two property writes instead of N,
    and nothing to create or destroy when the grid size changes. Points sit at the CENTRES of the
    grid cells (not the corners), so each one stands for the area it represents and the righting
    torque is the true one for a box, not an overstated corner lever.

    WHY IT FLOATS AT ITS DRAFT. With density D (0..1, "fraction submerged at rest"), full submersion
    gives FullForce = Mass * g / D. A column submerged by depth d of box height H pushes with
    (FullForce / N) * d / H, so the body is in equilibrium exactly when the average submersion is
    D * H: a crate of density 0.45 rides with 45% of its height under water. The engine applies
    gravity itself (workspace.Gravity); these forces are buoyancy and drag only.

    WHY IT TILTS AND BOBS. Every point reads the SAME WaveField the mesh is drawn from (HeightAt,
    first PhysicsWaveCount waves), so a swell lifting one side of a raft lifts those columns more
    and the difference is a torque that rolls the raft with the slope.

    WHY IT IS STABLE AT LOW FRAMERATES. The forces we write persist until the next write, so a slow
    or skipped update must never leave a force that over-corrects:
      * Dt is clamped (MaxDt), and the wave clock is used for the surface velocity estimate.
      * Damping is relative to the water's own vertical motion (the body follows the swell instead
        of being dragged against it) and is scaled from the CRITICAL damping of the buoyancy
        spring, so Data's WaterDrag / AngularDrag are damping RATIOS (1 = critically damped).
      * Every drag term is clamped so that, held for one Dt, it can at most stop the motion it
        opposes, never reverse it (|F| <= m |v| / Dt, |T| <= I |w| / Dt).
      * The net force and torque are clamped relative to Mass * g (MaxAccelG) and to I
        (MaxAngularAccel), so a bad sample or a teleport cannot launch anything.
    Moment of inertia is estimated as a uniform box footprint (m * L^2 / 12) -- Roblox exposes no
    assembly inertia, and the estimate only scales the damping and the clamp.
]]

local WaveField = require(script.Parent.WaveField)
local WaterData = require(script.Parent.Parent.Data.Water)

local Config = WaterData.Buoyancy
local PhysicsWaves = WaterData.PhysicsWaveCount

--> Steps longer than this are treated as this long (forces are re-written next step anyway).
local MaxDt = 1 / 15
local MinDt = 1 / 480
--> Net force cap, in multiples of the assembly's weight.
local MaxAccelG = 6
--> Net torque cap, as an angular acceleration (rad/s^2) times the inertia estimate.
local MaxAngularAccel = 25
--> Horizontal water drag as a fraction of the vertical one (water resists sinking more than
--> sliding; a raft should drift, a crate should not skate).
local HorizontalDragScale = 0.35
--> Cap on the estimated surface vertical speed, studs/s (guards a clock jump).
local MaxSurfaceSpeed = 40
local MinDensity = 0.05
local MaxDensity = 0.98

local DefaultDensity: number = Config.DefaultDensity or 0.5
local LinearRatio: number = math.clamp(Config.WaterDrag or 1, 0, 3)
local AngularRatio: number = math.clamp(Config.AngularDrag or 1, 0, 3)
local SampleGrid: number = math.max(1, math.floor(Config.SampleGrid or 2))

local Buoyancy = {}

export type State = {
    Root: BasePart,
    Attachment: Attachment,
    Force: VectorForce,
    Torque: Torque,
    --> The buoyant box, in the root part's space: its centre and half extents.
    BoxOffset: CFrame,
    HalfSize: Vector3,
    --> Bottom-face sample points in box space (cell centres).
    LocalPoints: { Vector3 },
    Density: number,
    --> Average surface height and wave time of the previous step (surface velocity estimate).
    LastSurfaceY: number?,
    LastTime: number?,
    --> Average submerged fraction 0..1 after the last step.
    Submerged: number,
}

local function BuildPoints(HalfSize: Vector3): { Vector3 }
    local Points = table.create(SampleGrid * SampleGrid)
    for GX = 0, SampleGrid - 1 do
        local U = ((GX + 0.5) / SampleGrid) * 2 - 1
        for GZ = 0, SampleGrid - 1 do
            local V = ((GZ + 0.5) / SampleGrid) * 2 - 1
            table.insert(Points, Vector3.new(U * HalfSize.X, -HalfSize.Y, V * HalfSize.Z))
        end
    end
    return Points
end

--[[
    Creates the attachment + VectorForce + Torque on Root and returns the State that Step needs.
    BoxOffset / BoxSize describe the buoyant box in Root's space (default: Root's own box).
]]
function Buoyancy.Attach(Root: BasePart, BoxOffset: CFrame?, BoxSize: Vector3?, Density: number?): State
    local Size = BoxSize or Root.Size
    local HalfSize = Size * 0.5

    local Attachment = Instance.new("Attachment")
    Attachment.Name = "BuoyancyAttachment"
    Attachment.Position = Root.CFrame:PointToObjectSpace(Root.AssemblyCenterOfMass)
    Attachment.Parent = Root

    local Force = Instance.new("VectorForce")
    Force.Name = "BuoyancyForce"
    Force.Attachment0 = Attachment
    Force.RelativeTo = Enum.ActuatorRelativeTo.World
    Force.ApplyAtCenterOfMass = true
    Force.Force = Vector3.zero
    Force.Parent = Root

    local Torque = Instance.new("Torque")
    Torque.Name = "BuoyancyTorque"
    Torque.Attachment0 = Attachment
    Torque.RelativeTo = Enum.ActuatorRelativeTo.World
    Torque.Torque = Vector3.zero
    Torque.Parent = Root

    return {
        Root = Root,
        Attachment = Attachment,
        Force = Force,
        Torque = Torque,
        BoxOffset = BoxOffset or CFrame.identity,
        HalfSize = HalfSize,
        LocalPoints = BuildPoints(HalfSize),
        Density = Density or DefaultDensity,
        LastSurfaceY = nil,
        LastTime = nil,
        Submerged = 0,
    }
end

--> Removes everything Attach created. Safe on an already-destroyed root.
function Buoyancy.Detach(State: State)
    State.Force:Destroy()
    State.Torque:Destroy()
    State.Attachment:Destroy()
end

--> Zeroes the forces (the body falls / drifts under the engine alone).
function Buoyancy.Clear(State: State)
    State.Force.Force = Vector3.zero
    State.Torque.Torque = Vector3.zero
    State.LastSurfaceY = nil
    State.LastTime = nil
    State.Submerged = 0
end

--[[
    Parks the body: force exactly cancels its weight, no torque, velocities zeroed. Used for
    assemblies nobody is near, so they neither sink nor drift while not simulated properly.
]]
function Buoyancy.Hold(State: State)
    local Root = State.Root
    State.Force.Force = Vector3.new(0, Root.AssemblyMass * workspace.Gravity, 0)
    State.Torque.Torque = Vector3.zero
    Root.AssemblyLinearVelocity = Vector3.zero
    Root.AssemblyAngularVelocity = Vector3.zero
    State.LastSurfaceY = nil
    State.LastTime = nil
end

local function ClampMagnitude(V: Vector3, Max: number): Vector3
    local M = V.Magnitude
    if M > Max then
        return V * (Max / M)
    end
    return V
end

--> Drag that, held for Dt, can at most cancel the velocity it opposes (never reverse it).
local function ClampDrag(Drag: number, Velocity: number, Inertia: number, Dt: number): number
    local Limit = Inertia * math.abs(Velocity) / Dt
    if Drag > Limit then
        return Limit
    elseif Drag < -Limit then
        return -Limit
    end
    return Drag
end

--[[
    Computes and writes this step's buoyancy force and torque. Assembly is the root part the
    State was attached to; Time is the shared wave clock (WaveField.Now()).
]]
function Buoyancy.Step(Assembly: BasePart, State: State, Dt: number, Time: number)
    if Dt < MinDt then
        Dt = MinDt
    elseif Dt > MaxDt then
        Dt = MaxDt
    end

    local Mass = Assembly.AssemblyMass
    if Mass <= 0 then
        return
    end
    local Gravity = workspace.Gravity
    local Density = math.clamp(State.Density, MinDensity, MaxDensity)
    local HalfSize = State.HalfSize
    local Height = HalfSize.Y * 2
    if Height <= 1e-3 then
        return
    end

    local FullForce = Mass * Gravity / Density
    local Points = State.LocalPoints
    local Count = #Points
    local PerPoint = FullForce / Count
    local InvHeight = 1 / Height

    local BoxCFrame = Assembly.CFrame * State.BoxOffset
    local Com = Assembly.AssemblyCenterOfMass
    local ComX, ComZ = Com.X, Com.Z

    local LiftY = 0
    local TorqueX, TorqueZ = 0, 0
    local SurfaceSum = 0
    local SubmergedSum = 0

    for Index = 1, Count do
        local Point = BoxCFrame * Points[Index]
        local PX, PZ = Point.X, Point.Z
        local SurfaceY = WaveField.HeightAt(PX, PZ, Time, PhysicsWaves)
        SurfaceSum += SurfaceY
        local Depth = SurfaceY - Point.Y
        if Depth > 0 then
            local Fraction = Depth * InvHeight
            if Fraction > 1 then
                Fraction = 1
            end
            local Lift = PerPoint * Fraction
            LiftY += Lift
            SubmergedSum += Fraction
            -- r x (0, Lift, 0) = (-rz * Lift, 0, rx * Lift)
            TorqueX -= (PZ - ComZ) * Lift
            TorqueZ += (PX - ComX) * Lift
        end
    end

    local SurfaceY = SurfaceSum / Count
    local SurfaceVelocity = 0
    local LastSurfaceY, LastTime = State.LastSurfaceY, State.LastTime
    if LastSurfaceY and LastTime and Time > LastTime then
        SurfaceVelocity = math.clamp((SurfaceY - LastSurfaceY) / (Time - LastTime), -MaxSurfaceSpeed, MaxSurfaceSpeed)
    end
    State.LastSurfaceY = SurfaceY
    State.LastTime = Time

    local Submerged = SubmergedSum / Count
    State.Submerged = Submerged
    if Submerged <= 0 then
        State.Force.Force = Vector3.zero
        State.Torque.Torque = Vector3.zero
        return
    end

    -- Linear drag: a ratio of the buoyancy spring's critical damping, 2 * sqrt(k * m), with
    -- k = FullForce / H, faded in by how much of the body is wet.
    local Stiffness = FullForce * InvHeight
    local SqrtKM = math.sqrt(Stiffness * Mass)
    local LinearC = 2 * SqrtKM * LinearRatio * Submerged
    local Velocity = Assembly.AssemblyLinearVelocity
    local RelativeVY = Velocity.Y - SurfaceVelocity
    local DragY = ClampDrag(-LinearC * RelativeVY, RelativeVY, Mass, Dt)
    local HorizontalC = LinearC * HorizontalDragScale
    local DragX = ClampDrag(-HorizontalC * Velocity.X, Velocity.X, Mass, Dt)
    local DragZ = ClampDrag(-HorizontalC * Velocity.Z, Velocity.Z, Mass, Dt)

    local NetForce = ClampMagnitude(Vector3.new(DragX, LiftY + DragY, DragZ), Mass * Gravity * MaxAccelG)

    -- Angular drag: footprint L^2 = mean of the squared sides; rotational stiffness k L^2 / 12,
    -- inertia m L^2 / 12, so critical damping 2 sqrt(kRot I) = 2 (L^2 / 12) sqrt(k m).
    local SideX, SideZ = HalfSize.X * 2, HalfSize.Z * 2
    local LengthSq = (SideX * SideX + SideZ * SideZ + Height * Height) / 3
    local Inertia = Mass * LengthSq / 12
    local AngularC = 2 * (LengthSq / 12) * SqrtKM * AngularRatio * Submerged
    local Spin = Assembly.AssemblyAngularVelocity
    local SpinDragX = ClampDrag(-AngularC * Spin.X, Spin.X, Inertia, Dt)
    local SpinDragY = ClampDrag(-AngularC * Spin.Y, Spin.Y, Inertia, Dt)
    local SpinDragZ = ClampDrag(-AngularC * Spin.Z, Spin.Z, Inertia, Dt)

    local NetTorque = ClampMagnitude(
        Vector3.new(TorqueX + SpinDragX, SpinDragY, TorqueZ + SpinDragZ),
        Inertia * MaxAngularAccel
    )

    State.Force.Force = NetForce
    State.Torque.Torque = NetTorque
end

return table.freeze(Buoyancy)
