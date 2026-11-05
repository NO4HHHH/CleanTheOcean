--> Services
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--> Constants
local Packages = ReplicatedStorage:WaitForChild("Packages")

--> Mods
local Loader = require(ReplicatedStorage.Packages.Loader)
--> Static paths (not the WaitForChild handle or Loader.Shared) so the type checker can follow
--> them to ProfileStore.Profile<T> and ProfileTemplate.ProfileType. Same instances at runtime.
--> ProfileStore is required from _Index, not the wally thunk at Packages.Server.ProfileStore:
--> the thunk is a bare `return require(...)` that does not re-export the package's types, so
--> `ProfileStore.Profile<T>` through it is an unknown type. Same module either way.
local ProfileStore =
    require(ReplicatedStorage.Packages.Server._Index["lm-loleris_profilestore@1.0.3"]["profilestore"])
local ReplicaService = require(Loader.Shared.Utility.ReplicaService)
local Promise = require(Packages:WaitForChild("Promise"))
local Janitor = require(Packages:WaitForChild("Janitor"))
local GoodSignal = require(Packages:WaitForChild("GoodSignal"))

local ProfileTemplate = require(ReplicatedStorage.Shared.Modules.ProfileTemplate)

--> Read for one line only -- see FFlags.JoinReport, and the announcement of a loaded profile
--> further down. The FAILURE alongside it warns and is not gated by anything.
local Flags = require(ReplicatedStorage:WaitForChild("FFlags"))

--> Types
local Types = require(script.Type)
export type PlayerData = ProfileTemplate.ProfileType
export type Profile = ProfileStore.Profile<PlayerData>

--> Globals
local IsMockStoreEnabled = false
--> Studio sessions use their own store, so QA grants and dev hooks in a playtest never reach the live PlayerData store the universe shares, even with Studio
--> API access on.
local ProfileStoreName = if RunService:IsStudio() then "PlayerData_Studio" else "PlayerData"
local GetDataTimeout = 10 --> Seconds GetDataAsync waits for a profile before rejecting.

local ClassToken = ReplicaService.NewClassToken("PlayerProfile")
local PlayerStore = ProfileStore.New(ProfileStoreName, ProfileTemplate)

if RunService:IsStudio() and IsMockStoreEnabled then
    warn("[DataService] Mock store enabled")
    PlayerStore = PlayerStore.Mock
end

--> Live sessions keyed by tostring(UserId), each a DataObject cleaned up on removal. Load
--> signals are parked here too, so one Janitor owns every per-player resource.
local Sessions = Janitor.new()

--> Keyed by tostring(UserId) so lookups, adds and removes always agree on key type.
local function SessionKey(UserId: number): string
    return tostring(UserId)
end

local function LoadSignalKey(UserId: number): string
    return `{UserId}LoadSignal`
end

local function GetProfileKeyById(UserId: number): string
    return `Profile_{UserId}`
end

local function GetPlayerDataKey(Player: Player): string
    return GetProfileKeyById(Player.UserId)
end

--> Constructor
local DataService = {
    OnLoadSignals = { };
    Profiles = { };
    ProxyProfiles = { };

    --> (Player, Profile, Message) -> boolean, set by whichever service owns queued messages. Return
    --> true only once the message is applied, or a function (Processed) -> () that finishes it in
    --> its own thread -- see the MessageHandler in DataService.new.
    MessageHandler = nil;
} :: Types.DataModule
DataService.__index = DataService

--> The store this server saves to ("PlayerData_Studio" in Studio); tests read snapshots through it.
--> Set through `any` because Type.luau's DataModule is frozen for this build.
;(DataService :: any).StoreName = ProfileStoreName

--[[
    ProfileLoaded(Player, Proxy): fired once per load, right after the proxy is in ProxyProfiles
    and GetDataAsync's waiters have been woken. A single GetDataAsync can reject
    while ProfileStore is still waiting out another server's lock, but the load itself keeps going
    and steals at 40 s, so a consumer that does `if ProxyProfiles[UserId] then Apply() end` AND
    listens here can never miss a profile.
]]
;(DataService :: any).ProfileLoaded = GoodSignal.new()

--> Methods
function DataService:Destroy()
    --> Reachable from PlayerRemoving, OnSessionEnd, the load promise's catch, and Sessions:Add
    --> replacing this index -- some of which re-enter while this call is on the stack.
    if self._Destroying then
        return
    end
    self._Destroying = true

    local UserId = self._UserId

    DataService.Profiles[UserId] = nil
    DataService.ProxyProfiles[UserId] = nil

    --[ Remove early load signals ]
    --> Fired with nil first, so anyone parked in GetDataAsync rejects now rather than at its timeout.
    if DataService.OnLoadSignals[UserId] then
        DataService.OnLoadSignals[UserId]:Fire(nil)
        Sessions:Remove(LoadSignalKey(UserId))
        DataService.OnLoadSignals[UserId] = nil
    end

    --> Tear the maid down before ending the session: ProfileStore fires OnSessionEnd
    --> synchronously from inside EndSession, so the connection below has to be gone or it
    --> re-enters this method and clears _Maid out from under us.
    if self._Maid then
        self._Maid:Destroy()
    end

    if self._Profile then
        self._Profile:EndSession()
    end

    --> The player's profile replica. Left alive, it holds Profile.Data and its Tags.Player for the
    --> life of the server -- ReplicaService only drops the player from its replication list.
    if self._Replica then
        self._Replica:Destroy()
    end

    --> Deregister. Via Sessions:Remove this is a no-op re-entry; via a direct self:Destroy()
    --> it stops a dead object being left parked for PlayerRemoving to trip over.
    Sessions:Remove(SessionKey(UserId))

    table.clear(self)
    setmetatable(self, nil)
end

function DataService.new(Player: Player)
    --> A session already parked under this key is the good one. Sessions:Add would Remove it to make
    --> room, which is a Destroy of a profile that has loaded -- so refuse rather than replace, and
    --> let whoever called twice have the object that works. See the note above PlayerAdded.
    --> Resolved rather than bare, so this returns the same shape the real path does -- the only
    --> caller today throws it away, and a future one chaining andThen onto it should not have to
    --> know which branch it got.
    local Existing = Sessions:Get(SessionKey(Player.UserId))

    if Existing then
        return Promise.resolve(Existing)
    end

    local Key = SessionKey(Player.UserId)
    local self = Sessions:Add(setmetatable({ }, DataService), "Destroy", Key) :: Types.DataObject
    self._Maid = Janitor.new()
    self._UserId = Player.UserId

    --[[
        THE LOAD IS NEVER CANCELLED, and that is load-bearing.

        Promise 4.0.0 coroutine.close()s a cancelled executor. This one is parked inside
        StartSessionAsync, so a cancel kills ProfileStore's load job mid-flight: its
        ActiveProfileLoadJobs counter never comes back down (BindToClose spins on it forever) and a
        same-server rejoin waits on a job that will never finish. The Cancel callback below is how a
        leaving player stops the load -- ProfileStore polls it and returns nil cleanly.

        So the session may be DESTROYED while this thread is parked, and Destroy table.clear()s self.
        The profile is held in a local until Sessions confirms this object is still the live one;
        a profile that arrives for a dead session is ended here and never written onto self.
    ]]
    return Promise.new(function(Resolve, Reject)
        --> Setup Player session
        local Profile = PlayerStore:StartSessionAsync(GetPlayerDataKey(Player), {
            Cancel = function()
                return Player:IsDescendantOf(Players) == false
            end,
        })

        if Sessions:Get(Key) ~= self then
            if Profile then
                Profile:EndSession()
            end

            return Reject(`{Player.Name}'s session ended before their profile finished loading`)
        end

        self._Profile = Profile

        --> Two messages for two audiences: the kick text is what the player reads, the reject
        --> reason is what ends up in the console.
        if not self._Profile then
            Player:Kick("We couldn't load your save. Please rejoin -- nothing has been lost!")
            return Reject(`Could not load profile for {Player.Name}`)
        end

        --> The player left mid-load; release it rather than hold a lock for someone gone.
        if Player.Parent ~= Players then
            return Reject(`{Player.Name} left before their profile finished loading`)
        end

        --> Initialize the players profile
        self._Profile:AddUserId(Player.UserId)
        self._Profile:Reconcile()

        --> Session ended externally (stolen, released): tear this object down.
        self._Maid:Add(self._Profile.OnSessionEnd:Connect(function()
            Sessions:Remove(SessionKey(Player.UserId))
        end), "Disconnect")

        --[[
            Register Profile Proxy.

            THE INVARIANT NOBODY HAD WRITTEN DOWN, and the most load-bearing one in the codebase:
            the proxy IS Profile.Data wearing a metatable, not a wrapper around it. Every
            `Proxy:SetValue(...)` in the game works only because `SetValue` MISSES on Profile.Data
            and falls through __index to the Replica. Field reads hit the data table directly and
            never reach the Replica at all -- which is why the same object can be read like data and
            called like a replica.

            SO NO PROFILE FIELD MAY EVER SHARE A NAME WITH A REPLICA MEMBER. The day ProfileTemplate
            gains a `SetValue`, `Data`, `Id`, `Tags` or `_replication`, that name stops falling
            through, and every write routed at it lands on the profile table instead of the replica:
            saved, never sent, no error raised anywhere. The client just goes on showing what it was
            told at load.

            Adding a profile field is otherwise completely free -- ProfileStore's Reconcile backfills
            it onto existing saves -- and that cheapness is exactly what makes this easy to walk into.
        ]]
        self._Replica = ReplicaService.NewReplica({
            ClassToken = ClassToken,
            Tags = { Player = Player },
            Data = self._Profile.Data,
            Replication = Player,
        })

        self._ProxyProfile = setmetatable(self._Profile.Data, {
            __index = self._Replica,
        })

        return Resolve(self._Profile, self._ProxyProfile)
    end):andThen(function(PlayerProfile, ProxyProfile)
        DataService.Profiles[Player.UserId] = PlayerProfile
        DataService.ProxyProfiles[Player.UserId] = ProxyProfile

        --[[
            Messages queued for this player while they were offline or on another server -- see
            SendMessage below.

            REGISTERED HERE, AFTER THE PROXY IS IN ProxyProfiles, so a handler can reach the
            player's data the way every other service does. Installed any earlier, it runs against a
            player who, as far as the rest of the game is concerned, has not loaded yet.

            CALL Processed ONLY ONCE THE MESSAGE IS ACTUALLY APPLIED. It discards the message from
            the queue, and anything not discarded is delivered again on the next load -- so a
            handler that is missing, threw, or refused must leave the message alone. Nothing handles
            messages yet; they stay queued until something does.
        ]]
        PlayerProfile:MessageHandler(function(Message, Processed)
            local Handler = DataService.MessageHandler

            if not Handler or typeof(Message) ~= "table" then
                return
            end

            local Ok, Handled = pcall(Handler, Player, PlayerProfile, Message)

            if not Ok then
                warn(`[DataService] a message for {Player.Name} threw and was left queued: {tostring(Handled)}`)
                return
            end

            --> A handler that cannot decide yet (it must not yield here) returns a function: it
            --> runs in its own thread and calls Processed itself once the message is applied.
            if type(Handled) == "function" then
                task.spawn(Handled, Processed)
            elseif Handled then
                Processed()
            end
        end)

        --> See FFlags.JoinReport.
        if Flags.JoinReport then
            print(`[DataService] {Player.Name}'s profile loaded`)
        end

        --> Wake anyone who called GetDataAsync before the profile finished loading.
        local LoadSignal = DataService.OnLoadSignals[Player.UserId]
        if LoadSignal then
            LoadSignal:Fire(ProxyProfile)
            Sessions:Remove(LoadSignalKey(Player.UserId))
            DataService.OnLoadSignals[Player.UserId] = nil
        end

        ;(DataService :: any).ProfileLoaded:Fire(Player, ProxyProfile)
    end):catch(function(Error)
        warn(`[DataService] Failed to load {Player.Name}'s profile:`, Error)

        --> Unblock any waiters (they receive nil) so their GetDataAsync rejects promptly.
        local LoadSignal = DataService.OnLoadSignals[Player.UserId]
        if LoadSignal then
            LoadSignal:Fire(nil)
        end

        --> Only while this object is still the live session: if it was already destroyed, self is a
        --> cleared table with no Destroy left to call, and a rejoin may own the key now.
        if Sessions:Get(Key) == self then
            self:Destroy()
        end
    end)
end

--> Default Handlers

--> Resolves with the player's replicated proxy profile, waiting on a load signal if it hasn't
--> loaded yet. Rejects after GetDataTimeout, or as soon as the load fails or the session ends --
--> it never resolves nil, so an andThen can index what it is handed.
function DataService:GetDataAsync(Player: Player)
    local UserId = Player.UserId
    local ThreadId = HttpService:GenerateGUID(false)

    return Promise.new(function(Resolve, Reject)
        local Session = Sessions:Get(SessionKey(UserId)) :: Types.DataObject?

        if Session and Session._ProxyProfile then
            Resolve(Session._ProxyProfile)
            return
        end

        --> Not loaded yet: park a one-shot listener on this player's load signal, creating it
        --> if we're the first waiter.
        local LoadSignal = DataService.OnLoadSignals[UserId]
        if not LoadSignal then
            LoadSignal = Sessions:Add(GoodSignal.new(), "DisconnectAll", LoadSignalKey(UserId))
            DataService.OnLoadSignals[UserId] = LoadSignal
        end

        Sessions:Add(LoadSignal:Once(function(ProxyProfile)
            Sessions:Remove(ThreadId)

            if ProxyProfile == nil then
                Reject(`{Player.Name}'s profile failed to load`)
            else
                Resolve(ProxyProfile)
            end
        end), "Disconnect", ThreadId)
        return
    end):timeout(GetDataTimeout, "Player data did not return within a healthy time"):catch(function(Error)
        warn(`[DataService] GetDataAsync for {Player.Name}:`, Error)
        Sessions:Remove(ThreadId)

        --> Re-raised: a catch that returns nothing RESOLVES, and a caller would be handed nil.
        return Promise.reject(Error)
    end)
end

--> The loaded Profile for an online player on this server, or nil. READ-ONLY for callers: a write
--> to Profile.Data persists but never replicates -- write through ProxyProfiles[UserId]:SetValue.
function DataService:GetProfile(UserId: number): Profile?
    return DataService.Profiles[UserId]
end

--> Durably delivers a message to a player's profile whether they're online or offline, applied by
--> DataService.MessageHandler once their profile loads. Returns whether the queue write succeeded.
function DataService:SendMessage(UserId: number, Message): boolean
    local Ok, Success = pcall(function()
        return PlayerStore:MessageAsync(GetProfileKeyById(UserId), Message)
    end)
    return Ok and Success == true
end

--> Seconds ViewDataAsync waits for the store before answering nil.
local ViewDataTimeout = 8

--[[
    A READ-ONLY look at any player's saved Data, online here, on another server or offline -- the
    gift pre-check reads `Entitlements` through it (Shop-Contract.md §9). It goes through
    `PlayerStore:GetAsync`, ProfileStore's view mode: no session is started, no lock is taken and
    nothing is ever saved from it, so it can never disturb the owner's live session.

    NIL MEANS "UNKNOWN", never "empty": a failed call, a timeout or a key with no save all answer nil.
    GetAsync retries a failing DataStore call forever with backoff, so it runs in its own thread
    and this caller stops waiting after ViewDataTimeout. Yields. The table returned is the saved
    copy (possibly a few minutes stale for a live player) and belongs to the caller.
]]
function DataService:ViewDataAsync(UserId: number): any?
    if typeof(UserId) ~= "number" or UserId <= 0 or UserId ~= math.floor(UserId) then
        return nil
    end

    local Done = false
    local Result = nil

    task.spawn(function()
        local Ok, View = pcall(function()
            return PlayerStore:GetAsync(GetProfileKeyById(UserId))
        end)
        if Ok and View ~= nil and typeof(View.Data) == "table" then
            Result = View.Data
        end
        Done = true
    end)

    local Deadline = os.clock() + ViewDataTimeout
    while not Done and os.clock() < Deadline do
        task.wait(0.1)
    end

    return if Done then Result else nil
end

--[[
    NO Players:GetPlayers() LOOP IN HERE, and that is load-bearing.

    CoreServer already fans PlayerAdded out over everyone standing on the server when the Loader
    finishes, so a service that ALSO sweeps them in Init runs its own PlayerAdded twice for the
    first joiner -- and for this service in particular the second run was not a harmless repeat. It
    destroyed the good session: Sessions:Add with an index Removes that index first, so construction
    number two tore down the profile that had already loaded, and then StartSessionAsync hit
    ProfileStore's "already loaded in this session" guard and rejected. The player was left with no
    ProxyProfile at all, every GetDataAsync timed out, nothing they did saved, and nothing said so.

    Guaranteed in a Studio playtest, where the local player is always present when Init runs.
]]
function DataService.PlayerAdded(Player: Player)
    DataService.new(Player)
end

function DataService.PlayerRemoving(Player: Player)
    Sessions:Remove(SessionKey(Player.UserId))
end

return DataService
