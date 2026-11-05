local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Developer = require(ReplicatedStorage.Shared.Modules.Developer)

return function()
    local Lines = {}
    for _, Player in Players:GetPlayers() do
        local Admin = Developer.IsAdmin(Player)
        local Why = if not Admin then "" elseif Developer.IsListed(Player) then " (studio/list/owner)" else " (group rank)"
        table.insert(Lines, `{Player.Name} ({Player.UserId}): {if Admin then "ADMIN" else "player"}{Why}`)
    end
    return table.concat(Lines, "\n")
end
