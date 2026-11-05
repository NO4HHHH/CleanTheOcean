return {
    Name = "speed",
    Aliases = { "walkspeed" },
    Description = "Set players' WalkSpeed (default 16). The game may reset it (sprint, respawn).",
    Group = "Admin",
    Args = {
        { Type = "players", Name = "players", Description = "Who" },
        { Type = "number", Name = "walkspeed", Description = "Studs per second (default 16)", Optional = true },
    },
}
