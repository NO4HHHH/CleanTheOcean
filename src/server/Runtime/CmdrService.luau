--[[
    The admin console: Cmdr (evaera/cmdr 1.12.0) wired up, gated, and loaded with the game's own
    commands. Both places.

    WHERE CMDR LIVES. The package is shared (ReplicatedStorage.Packages.Cmdr) but its init is the
    SERVER library: requiring it here moves `CmdrClient` into ReplicatedStorage (with the remotes)
    and puts the Cmdr ScreenGui in StarterGui. Clients only ever require ReplicatedStorage.CmdrClient,
    and only admins do (CmdrController). Command DEFINITIONS are moved into CmdrClient.Commands for
    autocomplete; the `<name>Server` halves stay in ServerScriptService and never replicate.

    WHAT IS REGISTERED, IN ORDER, IN INIT. Cmdr's default commands (help, tp, kill, kick, announce,
    bind, alias, ...), then every command under Server/Commands (one
    folder per group, each a definition + Server pair). Init, so the console is there as soon as a
    client can ask; no command touches a service at require, only when run.

    THE GATE IS SERVER-SIDE AND RUNS EVERY TIME. A BeforeRun hook refuses any command whose executor
    is not `Developer.IsAdmin` -- re-asked on every run (cached per player inside Developer), never
    trusted from the client. Hiding the console from non-admins (CmdrController) is cosmetic: any
    client can find the CmdrFunction remote, and this hook is what stops it. Commands with no
    server half (bind, alias, blink, ...) only act on the caller's own client.

    THE ATTRIBUTE. On join the server decides once and writes the `Developer` Player attribute
    (true/false), which is all the client reads to decide whether to load the console UI. A rank
    lookup that FAILED is retried a few times before settling on false (Developer header).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Developer = require(ReplicatedStorage.Shared.Modules.Developer)

local CmdrService = {}

local Server = script.Parent.Parent
--> Re-tries of a failed rank lookup on join, seconds apart.
local PublishRetries = { 5, 15, 45 }

--> The Cmdr server object (nil before Init). Tests run commands through `Cmdr.Dispatcher`.
CmdrService.Cmdr = nil :: any

local function Refusal(Context: any): string?
    local Executor = Context.Executor
    if Executor == nil then
        return nil --> a run from server code (tests) has no executor and no client behind it
    end
    if Developer.IsAdmin(Executor) then
        return nil
    end
    return "You do not have permission to run console commands."
end

function CmdrService:Init()
    local Cmdr = require(ReplicatedStorage.Packages.Cmdr) :: any
    CmdrService.Cmdr = Cmdr

    Cmdr:RegisterDefaultCommands()
    Cmdr:RegisterCommandsIn(Server.Commands)
    Cmdr.Registry:RegisterHook("BeforeRun", Refusal)
end

--[[
    Runs one command line as Executor and returns its reply, exactly as the console would
    (BeforeRun gate included). For tests and server code.
]]
function CmdrService:Run(Text: string, Executor: Player?): string
    return CmdrService.Cmdr.Dispatcher:EvaluateAndRun(Text, Executor)
end

function CmdrService.PlayerAdded(Player: Player)
    if Developer.Publish(Player) or Developer.Known(Player) then
        return
    end
    for _, Delay in PublishRetries do
        task.wait(Delay)
        if Player.Parent ~= Players then
            return
        end
        if Developer.Publish(Player) or Developer.Known(Player) then
            return
        end
    end
end

return CmdrService
