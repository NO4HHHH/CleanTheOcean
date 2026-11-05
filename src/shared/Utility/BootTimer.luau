--[[
    Where the seconds between joining and playing actually go.

    WHY A TOOL RATHER THAN A READ-THROUGH. Startup is one serial chain -- every module in Runtime
    is required in turn, then every Init is called in turn -- so the cost of the whole boot is the
    sum of a few dozen numbers, and exactly one or two of them are the problem. Reading the code
    tells you which lines COULD block; only measuring tells you which ones DID, and by how much.
    A guess that lands on the wrong module costs an afternoon of optimising something that was
    already fast.

    THREE THINGS ARE TIMED, because the chain has three links and they fail differently:

        Require  the module's top-level code. This is where a WaitForChild on an asset folder
                 lands, and it blocks every module after it in the folder walk
        Init     called on each module in turn, in ONE thread -- see Loader.SpawnAll's
                 shouldRunInNewThread. A yield here stalls every Init that has not run yet
        Start    spawned per module, so a yield only costs that module. What is timed is how long
                 each one runs BEFORE it first yields, which is the part that still blocks

    AND FOLDERS CAN BE WATCHED. A watch is not a cost, it is an arrival: how long after the boot
    began before a watched folder (ReplicatedStorage/Assets, say) existed. Those answer the
    question the timings above cannot -- whether the wait was the game's fault or replication's.
    Watched in their own threads, so nothing here delays what it is measuring.

    OFF IS EXACTLY THE OLD CODE PATH. Every function below falls through to the plain Loader call
    when the flag is off, so a boot with timing disabled loads in the same order, in the same
    threads, doing the same work. The only thing the flag buys is that the loop runs one module at
    a time so each can be timed either side.

    TURNING IT ON is FFlags.BootTiming, which is Studio-only like the rest of that file. A live
    server's boot is a different shape to a Studio one -- no Rojo, a real network, real assets --
    so if the question is about the live game, that flag has to be made to answer true there too.
]]

--> Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--> Constants

--> How many of the slowest entries a bucket prints. The tail of a boot is thirty modules costing
--> a millisecond each, and printing all of them buries the two that matter.
local TOP = 12

--> Below this, an entry is noise rather than a cost, and is folded into the bucket's total.
local FLOOR = 0.001

--> Mods

--> Reached rather than required through Loader: this module is used by the boot script itself,
--> which runs before Loader.Shared is a useful thing to be walking.
local Flags = require(ReplicatedStorage:WaitForChild("FFlags"))

--> Globals
local Enabled = Flags.BootTiming == true

--> When the run began, and what to call it in the output.
local Origin = 0
local Side = "?"

--> [Bucket] = { { Name, Seconds } }, in the order they happened rather than sorted -- Report does
--> the sorting, so the raw order is still there for anything that wants to read it.
local Buckets: { [string]: { { Name: string, Seconds: number } } } = { }
local Order: { string } = { }

--> [Label] = seconds after Origin. Both a milestone and a watch land here; the difference is only
--> that a watch is recorded by a thread rather than by the boot script.
local Marks: { { Label: string, Seconds: number } } = { }

local BootTimer = { }

--> Helpers

local function Now(): number
    return os.clock() - Origin
end

local function Bucket(Name: string)
    local Existing = Buckets[Name]

    if Existing then
        return Existing
    end

    local Made = { }
    Buckets[Name] = Made
    table.insert(Order, Name)

    return Made
end

--> Seconds as something readable at a glance. Milliseconds, because a boot worth investigating is
--> measured in hundreds of them and "0.842" is a number the eye has to parse.
local function Ms(Seconds: number): string
    return `{math.floor(Seconds * 1000 + 0.5)} ms`
end

--> Methods

--> Whether anything below will do anything. Exposed so a caller can skip building a label it
--> would only throw away.
function BootTimer.Enabled(): boolean
    return Enabled
end

--> Starts a run. Everything recorded afterwards is measured from here, so this belongs on the
--> first line of the boot script rather than after its requires.
function BootTimer.Begin(Which: string)
    if not Enabled then
        return
    end

    Origin = os.clock()
    Side = Which

    table.clear(Buckets)
    table.clear(Order)
    table.clear(Marks)
end

--> A milestone: something reached, at this many seconds in. For the points of a boot that are not
--> a module -- data arriving, the first frame drawn.
function BootTimer.Mark(Label: string)
    if not Enabled then
        return
    end

    table.insert(Marks, { Label = Label, Seconds = Now() })
end

--[[
    When something turned up, recorded without waiting for it.

    THE POINT IS THE ONES THAT ARE ALREADY THERE. A watch on a folder that exists resolves on the
    first line and records zero, which is the answer that rules replication out -- and the module
    that waited on it was slow for some other reason. A watch that records four seconds is the
    whole explanation for a module that took four seconds to require.

    In its own thread, so a folder that never arrives at all is a missing line in the report rather
    than a boot that hangs measuring itself.
]]
function BootTimer.Watch(Label: string, Parent: Instance, ChildName: string)
    if not Enabled then
        return
    end

    if Parent:FindFirstChild(ChildName) then
        BootTimer.Mark(`{Label} (already there)`)
        return
    end

    task.spawn(function()
        Parent:WaitForChild(ChildName)
        BootTimer.Mark(`{Label} arrived`)
    end)
end

--[[
    Times each ModuleScript in a folder being required, and leaves them required.

    HARMLESS WHEN IT RUNS, which is what makes this safe to put in front of the loader rather than
    inside it: a require is cached, so LoadChildren doing the same walk a moment later gets every
    module back instantly and builds exactly the table it always did. Nothing is loaded twice and
    nothing is loaded that would not have been.

    PCALLED, because a module that throws at require time is a thing this tool has to survive
    reporting on -- and the loader is about to throw the same error a moment later, in the place
    that has always thrown it.

    `Predicate` is the same filter the boot script hands Loader.LoadChildren (if any): a module the place does not run is skipped here too, so timing a
    boot never requires a service the loader would have left alone.
]]
function BootTimer.Requires(Folder: Instance, Predicate: ((ModuleScript) -> boolean)?)
    if not Enabled then
        return
    end

    local Into = Bucket("Require")

    for _, Child in Folder:GetChildren() do
        if not Child:IsA("ModuleScript") then
            continue
        end
        if Predicate and not Predicate(Child) then
            continue
        end

        local Started = os.clock()
        pcall(require, Child)

        table.insert(Into, { Name = Child.Name, Seconds = os.clock() - Started })
    end
end

--[[
    Loader.SpawnAll, one module at a time so each can be timed.

    IDENTICAL WHEN THE FLAG IS OFF -- the whole call falls through to the loader's own SpawnAll,
    which is the same function with the same arguments. On, it is that function called once per
    module, which walks the same table in the same order and applies the same Disabled check,
    because the check lives inside it rather than out here.

    WHAT THE NUMBER MEANS DEPENDS ON THE THREAD. A serial pass -- Init -- is timed end to end, so
    the number is how long that module made everything after it wait. A spawned pass -- Start -- is
    timed until the thread first yields, so the number is how much of that module's startup is
    still blocking. Both are the figure worth having, and they are not the same figure.
]]
function BootTimer.SpawnAll(Loader, Modules, Method: string, NewThread: boolean)
    if not Enabled then
        return Loader.SpawnAll(Modules, Method, NewThread)
    end

    local Into = Bucket(Method)

    for Name, Module in Modules do
        local Started = os.clock()

        Loader.SpawnAll({ [Name] = Module }, Method, NewThread)

        table.insert(Into, { Name = Name, Seconds = os.clock() - Started })
    end
end

--[[
    The report.

    SORTED BY COST, not by name or by order. The question this answers is "what should I look at
    first", and that is the top line -- everything below the third or fourth is usually noise.

    Printed rather than returned, since the caller is a boot script with nowhere to put it and the
    output window is where somebody investigating a slow load is already looking.
]]
function BootTimer.Report()
    if not Enabled then
        return
    end

    local Lines = { `[BootTimer] {Side} boot, {Ms(Now())} total` }

    for _, Name in Order do
        local Entries = Buckets[Name]

        local Total = 0
        for _, Entry in Entries do
            Total += Entry.Seconds
        end

        table.insert(Lines, `  {Name}: {Ms(Total)} across {#Entries}`)

        --> Copied before sorting: the bucket is kept in the order things happened, and a caller
        --> reading it after a report should still find that rather than this ordering.
        local Sorted = table.clone(Entries)

        table.sort(Sorted, function(A, B)
            return A.Seconds > B.Seconds
        end)

        local Shown = 0
        for _, Entry in Sorted do
            if Shown >= TOP or Entry.Seconds < FLOOR then
                break
            end

            Shown += 1
            table.insert(Lines, `    {Ms(Entry.Seconds)}  {Entry.Name}`)
        end

        if Shown == 0 then
            table.insert(Lines, `    nothing above {Ms(FLOOR)}`)
        end
    end

    if #Marks > 0 then
        table.insert(Lines, "  Milestones:")

        --> In the order they were reached rather than by cost. A milestone is a point on a
        --> timeline, and sorting it by size would take the timeline away.
        table.sort(Marks, function(A, B)
            return A.Seconds < B.Seconds
        end)

        for _, Mark in Marks do
            table.insert(Lines, `    {Ms(Mark.Seconds)}  {Mark.Label}`)
        end
    end

    print(table.concat(Lines, "\n"))
end

--> Whether this is the side that should be reporting at all. Both boot scripts call the same
--> functions, and a server printing a client's watches would be two reports to tell apart.
function BootTimer.IsServer(): boolean
    return RunService:IsServer()
end

return BootTimer
