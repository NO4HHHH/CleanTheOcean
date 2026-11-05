return {
    Name = "spawnfloat",
    Aliases = { "floats" },
    Description = "Spawn buoyant test objects (crate or raft) in the water in front of you, or at the origin.",
    Group = "Admin",
    Args = {
        { Type = "integer", Name = "count", Description = "How many (default 6 crates / 1 raft, max 40)", Optional = true },
        { Type = "string", Name = "kind", Description = "crate | raft (default crate)", Optional = true },
    },
}
