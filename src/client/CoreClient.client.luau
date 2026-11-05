---> globals
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Packages = ReplicatedStorage:WaitForChild("Packages")
--> Not bound: the wait is the point -- Loader.Shared below must not index Shared before it replicates.
ReplicatedStorage:WaitForChild("Shared")

---> dependencies
local Loader = require(Packages.Loader)
local Promise = require(Packages.Promise)

--> Where the seconds between joining and playing go. Every call below is a no-op unless
--> FFlags.BootTiming is on, and the loading itself is unchanged either way -- see its header.
--> Required and begun BEFORE the rest, so what those requires cost is inside the measurement
--> rather than in front of it.
local BootTimer = require(Loader.Shared.Utility.BootTimer)
BootTimer.Begin("Client")

local ReplicaController = require(Loader.Shared.Utility.ReplicaController)


---> runtime
local function acquireClientModulesAndRunInNewThread()
    return Promise.new(function(resolveAfterStart, _)
        return Promise.new(function(resolveAfterInit, _)
            --> Times each require, and leaves them cached so LoadChildren below is unchanged.
            BootTimer.Requires(script.Parent.Runtime)

            local modules = Loader.LoadChildren(script.Parent.Runtime)
            Loader.Controllers = modules

            --> Loader.SpawnAll, one module at a time when the flag is on and untouched when it is
            --> off. Init runs in THIS thread, so anything that yields in one holds up the rest.
            BootTimer.SpawnAll(Loader, modules, "Init", false)

            resolveAfterInit(modules)
        end):andThen(function(modules)
            BootTimer.SpawnAll(Loader, modules, "Start", true)
            resolveAfterStart()
        end)
    end)
end

acquireClientModulesAndRunInNewThread():andThen(function()
    ReplicaController.RequestData()
    game:SetAttribute("ClientLoaded", true)

    --> The same claim as the ClientLoaded milestone two lines down, said in prose for whoever is
    --> watching the output rather than reading the report -- so it rides on the same switch. The
    --> ATTRIBUTE above is what anything in code should be waiting on; this was never the signal,
    --> only the announcement, and on a live client it announced to nobody.
    if BootTimer.Enabled() then
        print("Client modules loaded successfully!")
    end

    BootTimer.Mark("ClientLoaded")
    BootTimer.Report()
end):catch(function(...)
    --> warn, not print: nothing after this catch runs -- no controller has Started -- and this
    --> string is the only evidence. Warned, it is the one coloured line in the output.
    warn("[CRITICAL - CoreClient]: Failed to load:", ...)
end)
