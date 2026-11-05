
return function(_Context, Targets: { Player }, Speed: number?)
    local Value = math.clamp(Speed or 16, 0, 500)
    local Set = 0
    for _, Player in Targets do
        local Humanoid = Player.Character and Player.Character:FindFirstChildOfClass("Humanoid")
        if Humanoid then
            Humanoid.WalkSpeed = Value
            Set += 1
        end
    end
    return `WalkSpeed {Value} on {Set} player(s)`
end
