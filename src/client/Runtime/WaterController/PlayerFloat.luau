--!strict
--[[
    The local player floats. When the character is in the water and NOT standing on ground
    (Humanoid.FloorMaterial is Air), a spring holds its HumanoidRootPart at
    Water.PlayerFloat.RootOffset studs from the wave surface under it, so the player bobs on the
    same swell the mesh draws (WaveField at the server clock, all waves).

    WHY ON THE CLIENT. A character is simulated by its own player's client (network owner), so a
    force the server sets would arrive late and fight the owner's simulation. BuoyancyService
    floats server-owned things; this floats the one thing each client owns.

    HOW. One VectorForce (world space, at the centre of mass) on the root, recomputed every frame:
        Accel.Y = Gravity + w^2 * (TargetY - Y) - 2 * zeta * w * VelocityY
    a damped spring on top of exactly cancelling gravity, with w = Frequency and
    zeta = DampingRatio, clamped to 0..MaxAccel * Gravity so a dive from a height is pulled out
    firmly but never launched. A light horizontal drag (-Drag * horizontal velocity) is water
    resistance. Force = AssemblyMass * Accel, so it suits any character size.

    STANDING WINS. On an island, in the shallows or on a deck the Humanoid has a floor, and the
    force switches off: walking is never fought by the float. The character gets the attribute
    `Floating` (true / false) so animation and swimming controls can key off it later.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Water = require(Shared:WaitForChild("Data"):WaitForChild("Water"))
local WaveField = require(Shared:WaitForChild("Water"):WaitForChild("WaveField"))

local Settings = Water.PlayerFloat
local Stiffness = Settings.Frequency * Settings.Frequency
local Damping = 2 * Settings.DampingRatio * Settings.Frequency
-- In the water once the root is below this height above its float target (studs).
local EnterMargin = 1.5

local PlayerFloat = {}

local Root: BasePart? = nil
local Humanoid: Humanoid? = nil
local Force: VectorForce? = nil
local Character: Model? = nil
local Floating = false

local function SetFloating(Value: boolean)
    if Floating == Value then
        return
    end
    Floating = Value
    local Target = Force
    if Target then
        Target.Enabled = Value
        if not Value then
            Target.Force = Vector3.zero
        end
    end
    if Character then
        Character:SetAttribute("Floating", Value)
    end
end

local function Bind(NewCharacter: Model)
    Root, Humanoid, Force, Character = nil, nil, nil, NewCharacter
    Floating = false
    local NewHumanoid = NewCharacter:WaitForChild("Humanoid", 10)
    local NewRoot = NewCharacter:WaitForChild("HumanoidRootPart", 10)
    if Character ~= NewCharacter or not NewHumanoid or not NewRoot then
        return
    end
    local Attachment = Instance.new("Attachment")
    Attachment.Name = "FloatAttachment"
    Attachment.Parent = NewRoot

    local NewForce = Instance.new("VectorForce")
    NewForce.Name = "FloatForce"
    NewForce.Attachment0 = Attachment
    NewForce.RelativeTo = Enum.ActuatorRelativeTo.World
    NewForce.ApplyAtCenterOfMass = true
    NewForce.Force = Vector3.zero
    NewForce.Enabled = false
    NewForce.Parent = NewRoot

    Humanoid = NewHumanoid :: Humanoid
    Root = NewRoot :: BasePart
    Force = NewForce
    NewCharacter:SetAttribute("Floating", false)
end

function PlayerFloat.Init()
    local LocalPlayer = Players.LocalPlayer
    if not LocalPlayer then
        return
    end
    LocalPlayer.CharacterAdded:Connect(function(NewCharacter)
        task.spawn(Bind, NewCharacter)
    end)
    if LocalPlayer.Character then
        task.spawn(Bind, LocalPlayer.Character)
    end
end

function PlayerFloat.Step(_Dt: number)
    local TargetRoot, TargetHumanoid, TargetForce = Root, Humanoid, Force
    if not TargetRoot or not TargetHumanoid or not TargetForce or not TargetRoot.Parent then
        return
    end
    if TargetHumanoid.Health <= 0 or TargetRoot.Anchored then
        SetFloating(false)
        return
    end

    local Position = TargetRoot.Position
    local SurfaceY = WaveField.HeightAt(Position.X, Position.Z, WaveField.Now())
    local TargetY = SurfaceY + Settings.RootOffset
    local OnGround = TargetHumanoid.FloorMaterial ~= Enum.Material.Air
    local InWater = Position.Y < TargetY + EnterMargin
    if OnGround or not InWater then
        SetFloating(false)
        return
    end
    SetFloating(true)

    local Gravity = workspace.Gravity
    local Velocity = TargetRoot.AssemblyLinearVelocity
    local AccelY = Gravity + Stiffness * (TargetY - Position.Y) - Damping * Velocity.Y
    AccelY = math.clamp(AccelY, 0, Settings.MaxAccel * Gravity)
    local Mass = TargetRoot.AssemblyMass
    TargetForce.Force = Vector3.new(-Velocity.X * Settings.Drag * Mass, AccelY * Mass, -Velocity.Z * Settings.Drag * Mass)
end

return PlayerFloat
