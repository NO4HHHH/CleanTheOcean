--[[
    The admin console's client half: loads Cmdr's UI for admins only. Both places.

    WHO GETS IT. The server decides who is an admin (Developer.IsAdmin) and writes the `Developer`
    Player attribute on join. This controller waits for that attribute and requires
    ReplicatedStorage.CmdrClient only when it is true -- a non-admin never loads the console, never
    binds a key and never sees a button. That is cosmetic, not security: the server's BeforeRun
    hook (CmdrService) re-checks every command. A failed rank lookup can flip the attribute to true
    later, so the controller keeps listening until it has loaded once.

    HOW TO OPEN IT. F2 on a keyboard (Cmdr's activation key, set explicitly here). On a phone or a
    gamepad there is no F2, so admins also get a small "Console" icon in Roblox's top bar through
    TopbarPlus (already used for the Settings gear), which toggles the window. One icon, adopted by
    name if it already exists, so the Studio simulation's single client never gets two.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CmdrController = {}

local Attribute = "Developer" --> Shared/Modules/Developer.Attribute
local IconName = "AdminConsole"
local Loaded = false

local function AddIcon(Cmdr: any)
    local Ok, Error = pcall(function()
        local TopbarPlus = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Topbarplus")) :: any
        local Icon = TopbarPlus.getIcon(IconName)
        if Icon then
            return
        end
        Icon = TopbarPlus.new()
        Icon:setName(IconName)
        Icon:setLabel("Console")
        Icon:oneClick(true)
        Icon.selected:Connect(function()
            Cmdr:Toggle()
        end)
    end)
    if not Ok then
        warn(`[CmdrController] console icon failed: {Error}`)
    end
end

local function Load()
    if Loaded then
        return
    end
    Loaded = true
    local Cmdr = require(ReplicatedStorage:WaitForChild("CmdrClient")) :: any
    Cmdr:SetActivationKeys({ Enum.KeyCode.F2 })
    Cmdr:SetPlaceName("Clean The Ocean")
    AddIcon(Cmdr)
end

function CmdrController:Start()
    local Player = Players.LocalPlayer
    local function Check()
        if not Loaded and Player:GetAttribute(Attribute) == true then
            task.spawn(Load)
        end
    end
    Player:GetAttributeChangedSignal(Attribute):Connect(Check)
    Check()
end

return CmdrController
