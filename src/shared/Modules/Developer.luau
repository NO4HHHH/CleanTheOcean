--[[
    Who counts as an admin (a "developer"), authored once so the server and the client cannot
    disagree about the rule.

    FOUR WAYS IN, ANY ONE IS ENOUGH (Bruce, 2026-10-16):
      1. Studio. Every player in a Studio session (Play or Team Test) is an admin, so the console
         can be tested locally without a published place or a group.
      2. The explicit `UserIds` list. NO4HHHH (247928116) owns the game, and the list is the one
         place a named person can be let in before the group exists or without a group rank.
      3. The experience owner: `game.CreatorType == User` and the player is `game.CreatorId`.
         While the experience is user-owned this is the owner with no list edit; once it moves to
         a group, CreatorId is the GROUP's id and this rule simply stops matching.
      4. The group rank: rank in `GroupId` STRICTLY ABOVE MinimumRank (254+). Revoking access is a
         change made in the group, which takes effect on the next server, not a release.

    ONLY THE SERVER'S ANSWER COUNTS. `IsAdmin` is computed on the server and cached per player;
    the server publishes it as the `Developer` Player attribute (true or false, written once per
    join) so a client can find out without being asked to work it out for itself. A client can lie
    about anything it computes, so the client's copy may decide only harmless things (whether to
    load the console UI on that player's own screen); every command is re-checked on the server
    against `IsAdmin` on every run (CmdrService's BeforeRun hook).

    RANK IS A WEB CALL AND WEB CALLS FAIL. Rank returns nil for "we could not find out", which is
    deliberately not 0, "not in the group". A failure must never read as a promotion, so nil is a
    refusal -- but it is NOT cached, so the next command retries the lookup instead of locking a
    real developer out for the whole session. Only a definite answer is cached.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Developer = {}

--> The group whose ranks decide rule 4. 0 = no group yet: rule 4 is off and Rank answers 0.
Developer.GroupId = 0

--> Strictly above, not at least -- see the note above.
Developer.MinimumRank = 253

--> Rule 2: named admins by UserId (UserId -> who, for the reader).
Developer.UserIds = {
    [247928116] = "NO4HHHH", --> the game owner
} :: { [number]: string }

--> The Player attribute the server writes once it has decided (true / false; absent = not yet).
Developer.Attribute = "Developer"

--> Server-side cache of definite answers. Weak keys: a Player that left is collected with it.
local Cache: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

--[[
    Their rank in the group, or nil if the question could not be answered.

    pcall'd because GetRankInGroupAsync is a web call that throws rather than returning zero when the
    group service is having a bad day.
]]
function Developer.Rank(Player: Player): number?
    if Developer.GroupId == 0 then
        return 0
    end

    local Ok, Rank = pcall(Player.GetRankInGroupAsync, Player, Developer.GroupId)

    if not Ok or type(Rank) ~= "number" then
        return nil
    end

    return Rank
end

--> Whether a rank read by Rank above clears the bar. nil does not, which is what makes a failed
--> lookup a refusal rather than a promotion.
function Developer.Allows(Rank: number?): boolean
    return type(Rank) == "number" and Rank > Developer.MinimumRank
end

--> Rules 1-3: the answers that need no web call. Never yields.
function Developer.IsListed(Player: Player): boolean
    if RunService:IsStudio() then
        return true
    end
    if Developer.UserIds[Player.UserId] ~= nil then
        return true
    end
    return game.CreatorType == Enum.CreatorType.User and Player.UserId == game.CreatorId
end

--[[
    The answer. On the SERVER: rules 1-4, cached per player once definite (may yield once, for
    the rank). On a CLIENT: only what the server published in the attribute -- the client never
    decides for itself, and the server re-checks every command anyway.
]]
function Developer.IsAdmin(Player: Player): boolean
    if typeof(Player) ~= "Instance" or not Player:IsA("Player") then
        return false
    end
    if not RunService:IsServer() then
        return Player:GetAttribute(Developer.Attribute) == true
    end
    local Known = Cache[Player]
    if Known ~= nil then
        return Known
    end
    if Developer.IsListed(Player) then
        Cache[Player] = true
        return true
    end
    local Rank = Developer.Rank(Player)
    if Rank == nil then
        return false --> unknown: refused now, retried next time (header)
    end
    local Allowed = Developer.Allows(Rank)
    if Player.Parent == Players then
        Cache[Player] = Allowed
    end
    return Allowed
end

--> Server: true once the answer for Player is definite (cached); false after a failed rank lookup.
function Developer.Known(Player: Player): boolean
    return Cache[Player] ~= nil
end

--> Server: decides and writes the attribute (true/false). Yields for the rank lookup.
function Developer.Publish(Player: Player): boolean
    local Allowed = Developer.IsAdmin(Player)
    if Player.Parent == Players then
        Player:SetAttribute(Developer.Attribute, Allowed)
    end
    return Allowed
end

return Developer
