--> A single loaded player session. Created by DataService.new, torn down by DataObject:Destroy.
export type DataObject = {
    _Maid: any, --> owns this session's connections (never the load promise -- see DataService.new)
    _Destroying: boolean?, --> re-entrancy guard; Destroy is reachable from several paths
    _Profile: any?, --> ProfileStore Profile<PlayerData>, nil outside the session
    _Replica: any?, --> the PlayerProfile replica, destroyed in Destroy
    _ProxyProfile: any?, --> ReplicaService proxy over Profile.Data, replicated to the client
    _UserId: number,

    Destroy: (self: DataObject) -> (),
}

--> The DataService module table.
export type DataModule = {
    OnLoadSignals: { [number]: any }, --> [UserId] = signal fired with the proxy once loaded
    Profiles: { [number]: any }, --> [UserId] = loaded Profile, online players on this server
    ProxyProfiles: { [number]: any }, --> [UserId] = replicated proxy profile.
    StoreName: string, --> the ProfileStore name in use ("PlayerData", or "PlayerData_Studio" in Studio)
    ProfileLoaded: any, --> GoodSignal (Player, ProxyProfile): fired once per load, after ProxyProfiles is set

    new: (Player: Player) -> any, --> Promise<(Profile, ProxyProfile)>
    GetDataAsync: (self: DataModule, Player: Player) -> any, --> Promise<ProxyProfile>; rejects, never resolves nil
    GetProfile: (self: DataModule, UserId: number) -> any?,
    MessageHandler: ((Player: Player, Profile: any, Message: { [any]: any }) -> any)?, --> boolean, or a deferred (Processed) -> ()
    SendMessage: (self: DataModule, UserId: number, Message: any) -> boolean,
    ViewDataAsync: (self: DataModule, UserId: number) -> any?, --> saved Data, read-only view mode; nil = unknown. Yields.

    Init: (self: DataModule) -> (),
    PlayerAdded: (Player: Player) -> (),
    PlayerRemoving: (Player: Player) -> (),
}

return { }
