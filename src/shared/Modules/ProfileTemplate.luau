--[[
    The save shape -- every field a player's profile can hold, and its value for a new player.

    ADDING A FIELD IS FREE. ProfileStore's Reconcile backfills anything declared here onto saves
    that predate it, so a new field needs no migration -- declare it, give it a default, and every
    existing player arrives with it on their next load. Reconcile only ever ADDS, though: a field
    removed from here survives on old saves, declared nowhere and read by nothing.

    NO FIELD MAY SHARE A NAME WITH A REPLICA MEMBER (`SetValue`, `Data`, `Id`, `Tags`,
    `_replication`, ...). The proxy profile is Profile.Data wearing a metatable whose __index is the
    Replica -- see DataService.new -- so a field with one of those names shadows the method, and
    every write routed at it is saved but never replicated, with no error anywhere.

    MAPS START EMPTY. Reconcile re-adds any missing string key, so a seeded map entry would come
    back the moment a player's last one was gone. Keep defaults in the registries, not here.

    Writes go through the proxy: `DataService.ProxyProfiles[UserId]:SetValue({ "Path" }, Value)`.
]]

export type ProfileType = {
    --> The soft currency.
    Cash: number,

    --> Lifetime counters.
    Stats: {
        TimePlayed: number, --> seconds
        Joins: number,
    },

    --> Player settings.
    Settings: {
        MusicVolume: number, --> 0..1
        SfxVolume: number, --> 0..1
    },
}

local ProfileTemplate = {
    Cash = 0,

    Stats = {
        TimePlayed = 0,
        Joins = 0,
    },

    Settings = {
        MusicVolume = 0.5,
        SfxVolume = 0.5,
    },
} :: ProfileType

return ProfileTemplate
