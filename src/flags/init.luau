local RunService = game:GetService("RunService")
local IsStudio = RunService:IsStudio()

--[[
    What a flag is worth here: whatever it says in Studio, and false in a live server.

    WRITTEN OUT RATHER THAN AS `IsStudio and studioValue or false`. That idiom collapses whenever the
    wanted branch is falsy -- `flag(false)` in Studio evaluates the `and` to false and falls through
    to the `or` -- and is only correct while the fallback happens to be the same `false`. Make the
    live-server answer anything else and every `flag(false)` silently inverts. An `if` cannot rot
    that way.
]]
local function flag(studioValue: boolean): boolean
    if not IsStudio then
        return false
    end

    return studioValue
end

return {
    --[[
        Times the boot on both sides and prints where the seconds went -- see Utility/BootTimer.

        STUDIO ONLY, and that is a real limitation: a Studio boot has no network and a Rojo sync in
        the way, so its numbers are the shape of the problem rather than its size. Diagnosing a slow
        LIVE join means making this answer true in a live server.

        Also gates the two arrival lines -- CoreClient's "Client modules loaded successfully!" and
        ReplicaController's "Initial data received". Neither is a signal anything waits on: the
        ClientLoaded attribute and InitialDataReceivedSignal are set and fired either way.
    ]]
    BootTiming = flag(false),

    --[[
        The join-time one-liners, such as whose profile loaded.

        Every line behind this announces a success, so an absent line never means an absent
        problem: the failure paths beside each one warn unconditionally.
    ]]
    JoinReport = flag(true),
}
