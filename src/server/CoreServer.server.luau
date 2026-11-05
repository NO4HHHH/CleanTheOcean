---> globals
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")

---> dependencies
local Loader = require(Packages.Loader)
local Promise = require(Packages.Promise)

--> Where the seconds go. Every call is a no-op unless FFlags.BootTiming is on, and the loading
--> itself is unchanged either way -- see Utility/BootTimer's header.
local BootTimer = require(Loader.Shared.Utility.BootTimer)
BootTimer.Begin("Server")


--[[
    THE INTERFACE IS BUILT ONCE PER SESSION, AND THIS IS THE LINE THAT LETS IT BE.

    UI authored in StarterGui and wired up by code at load is wired exactly once. A PlayerGui that
    is emptied and re-cloned on respawn does not "reset" that interface, it DESTROYS it: what comes
    back is the inert mockup with none of the wiring. ResetOnSpawn = false on each ScreenGui is not
    enough once the guis arrive inside a package Model, because the reset destroys the container.

    HERE, ON THE SERVER, BECAUSE THE PROPERTY IS SERVER-AUTHORITATIVE. Set from a LocalScript it
    changes the client's own copy and the engine goes on resetting regardless. In code rather than
    ticked in the place, so a routine re-import of StarterGui cannot quietly flip it back.
]]
game:GetService("StarterGui").ResetPlayerGuiOnSpawn = false

local CallTime = workspace:GetServerTimeNow()
workspace:SetAttribute("StartTime", CallTime)
--workspace:SetAttribute("RawStartTime", CallTime)

---> runtime
local function acquireServerModulesAndRunInNewThread()
    return Promise.new(function(resolveAfterStart, _)
        return Promise.new(function(resolveAfterInit, _)
            --> Times each require, and leaves them cached so LoadChildren below is unchanged.
            BootTimer.Requires(script.Parent.Runtime)

            local modules = Loader.LoadChildren(script.Parent.Runtime)
            Loader.Services = modules

            --> Init runs in THIS thread, so anything that yields in one holds up every service
            --> whose Init has not been reached yet.
            BootTimer.SpawnAll(Loader, modules, "Init", false)

            --> Handed on rather than re-walked. Start used to call LoadChildren a SECOND time and
            --> iterate the fresh table it returned: the requires were cached so it cost little,
            --> but it meant the table Start walked was not the one registered as Loader.Services.
            resolveAfterInit(modules)
        end):andThen(function(modules)
            BootTimer.SpawnAll(Loader, modules, "Start", true)

            BootTimer.Mark("ServicesStarted")
            BootTimer.Report()

            resolveAfterStart()
        end)
    end)
end

--[[
    The one service whose PlayerRemoving has to run AFTER everybody else's.

    IT IS THE ONE THAT ENDS THE PROFILE SESSION, and a write that lands after that is a write that
    replicates, mutates the table in memory, and is never saved -- silently, with nothing to say it
    went missing. Any service that stamps something on the way out (a last-seen time, say) needs
    the profile still open when its PlayerRemoving runs.

    The handlers below are collected by iterating Loader.Services, a dictionary keyed by module
    name, so without this rule the order would be whatever Lua happened to hand back.

    EVERY OTHER HANDLER RUNS CONCURRENTLY AND IS WAITED FOR, then this one runs. Spawning them all at
    once (as this used to) put DataService in the same race as the rest: any handler that yielded
    before its write -- a DataStore call, a task.wait -- lost it to the session ending. The wait is
    capped at RemovingTimeout so one handler that never returns cannot hold a save hostage; it
    warns, and the session ends without it.

    BY NAME rather than by a flag on the service, because the rule is about THIS service and not
    about a category: nothing else ends a session, and inventing a "goes last" marker would invite a
    second thing to claim it and put the ordering question straight back.
]]
local LastRemover = "DataService"
local RemovingTimeout = 10 --> Seconds the other PlayerRemoving handlers get before DataService runs.

--> Runs every handler in its own thread and returns once all of them have, or at the timeout.
--> A handler that throws counts as finished, so one error cannot stall the save behind it.
local function RunConcurrently(Handlers: { (Player) -> () }, Player: Player)
    local Remaining = #Handlers
    local Waiting = false
    local Thread = coroutine.running()

    local function Finish()
        Remaining -= 1

        if Remaining == 0 and Waiting then
            Waiting = false
            task.spawn(Thread)
        end
    end

    for _, Handler in Handlers do
        task.spawn(function()
            local Ok, Error = pcall(Handler, Player)

            if not Ok then
                warn(`[CoreServer]: a PlayerRemoving handler threw for {Player.Name}:`, Error)
            end

            Finish()
        end)
    end

    --> Every handler may already have returned without yielding; only park if one is still out.
    if Remaining > 0 then
        Waiting = true

        local Timer = task.delay(RemovingTimeout, function()
            if Waiting then
                Waiting = false
                warn(`[CoreServer]: {Remaining} PlayerRemoving handler(s) for {Player.Name} still running`
                    .. ` after {RemovingTimeout}s -- ending the session without them`)
                task.spawn(Thread)
            end
        end)

        coroutine.yield()

        --> Suspended only when Finish woke us; when the timer did, it is the thread that resumed us.
        if coroutine.status(Timer) == "suspended" then
            task.cancel(Timer)
        end
    end
end

function addPlayerAddedFunctions()
    return Promise.new(function(Resolve)
        local PlayerAddedProcesses = { }
        local PlayerRemovingProcesses = { }

        --> Held out of the list and appended once the walk is done -- see LastRemover.
        local Closing = nil

        for Name, Services in Loader.Services do
            local PlayerAdded = Services["PlayerAdded"]
            local PlayerRemoving = Services["PlayerRemoving"]

            if typeof(PlayerAdded) == "function" then
                table.insert(PlayerAddedProcesses, PlayerAdded)
            end

            if typeof(PlayerRemoving) == "function" then
                if Name == LastRemover then
                    Closing = PlayerRemoving
                else
                    table.insert(PlayerRemovingProcesses, PlayerRemoving)
                end
            end
        end

        if not Closing then
            warn(`[CoreServer]: no {LastRemover}.PlayerRemoving to run last -- if that service still`
                .. ` owns the profile session, a rename has broken the ordering rule above`)
        end

        for _, Player in Players:GetPlayers() do
            for _, PlrFunc in PlayerAddedProcesses do
                task.spawn(PlrFunc, Player)
            end
        end

        Players.PlayerAdded:Connect(function(Player : Player)
            for _, PlrFunc in PlayerAddedProcesses do
                task.spawn(PlrFunc, Player)
            end
        end)

        Players.PlayerRemoving:Connect(function(Player : Player)
            RunConcurrently(PlayerRemovingProcesses, Player)

            if Closing then
                Closing(Player)
            end
        end)

        Resolve(true)
    end):catch(function(...)
        --> warn, not print: a CRITICAL at the same weight as every other line is one nobody sees.
        warn("[CRITICAL - CoreServer]: Failed to load:", ...)
    end)
end

--> Without this catch, anything that threw between here and the last service starting -- a module
--> erroring at require -- is swallowed by a promise nobody is listening to, and the server comes up
--> silently doing nothing.
acquireServerModulesAndRunInNewThread():andThen(function()
    addPlayerAddedFunctions()
end):catch(function(...)
    warn("[CRITICAL - CoreServer]: Failed to load:", ...)
end)
