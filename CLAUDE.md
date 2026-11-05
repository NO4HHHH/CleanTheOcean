# Agent orientation

**Clean The Ocean** — Roblox game, Luau, Rojo-synced. Fresh project (2026-11-04) on the carried-over
core framework: boot, save system, replication and an admin console. No game code yet.

## Standing orders

- **Git**: the repo is `github.com/NO4HHHH/CleanTheOcean`. Feature branches for agent work.
  ⛔ Never force-push, rewrite pushed history, delete branches or repos, or change repo
  settings/visibility without asking. `.gitattributes` is `* -text` and `core.autocrlf=false`:
  git stores the mixed line endings byte for byte.
- **Line endings are mixed per file** (some CRLF, some LF). Match the file you are editing; normalise
  nothing. Check by bytes: `tr -dc '\r' < <file> | wc -c` (zero means LF). ⚠️ `sed -i` in Git
  Bash strips CRs from CRLF files.
- **Work directly, don't overthink**: read what the task needs, make the change, verify it
  (typecheck), report. When something is ambiguous, choose the simplest option and note it.
- **PascalCase everything**: locals, fields, parameters, loop variables. Non-trivial files open with
  a prose `--[[ ]]` header arguing *why* the design is what it is.

## Framework rules

1. **Never `require` a sibling service/controller at the top of a file.** Load order is
   `Loader.LoadChildren` walking `Runtime/`. Resolve lazily inside a function:
   `Loader.Services[Name]` / `Loader.Controllers[Name]`.
2. **Services/controllers** are modules in `src/server/Runtime` / `src/client/Runtime` with optional
   `Init`, `Start`, and (server) `PlayerAdded` / `PlayerRemoving`. CoreServer fans PlayerAdded out
   over players already present, so **never loop `Players:GetPlayers()` in Init**. On leave, every
   other service's PlayerRemoving runs **concurrently and is waited for** (10 s cap), and only then
   does `DataService`'s run, because it ends the profile session.
3. **Never write `Profile.Data` directly.** Go through the proxy:
   `DataService.ProxyProfiles[UserId]:SetValue({ "Path", "To", "Field" }, Value)`, which persists
   *and* replicates. Client reads `DataController.LocalPlayerData`.
4. **Save shape is `src/shared/Modules/ProfileTemplate.luau`.** Adding a field is free (Reconcile
   backfills). No field may share a name with a Replica member (`SetValue`, `Data`, `Id`, `Tags`…).
5. **Transport is the vendored ReplicaService** (`src/shared/Utility/Replica*`). Pattern: a service
   owns a per-player command replica with a `Commands` allow-list; client
   `Replica:FireServer("Cmd", ...)`, successes ride down the profile replica.
6. **Content goes in registries** under `src/shared/Data`: a registry + a ProfileTemplate field + a
   service that validates against the registry + UI that draws it.
7. **Flags**: `src/flags/init.luau`, `flag(v)` returns `v` in Studio and `false` live.
8. **UI**: React-Lua (`Packages.React` / `Packages.ReactRoblox`) is installed; Fusion is also in
   `wally.toml`. Pick one and do not mix the two.

## Layout

```
src/server/CoreServer.server.luau   boot: LoadChildren(Runtime) → Init → Start → player hooks
src/server/Runtime/DataService/     ProfileStore + proxy profile + queued messages
src/server/Runtime/CmdrService      admin console (Cmdr), gated by Developer.IsAdmin
src/server/Commands/                Cmdr commands, one folder per group (definition + Server pair)
src/server/Commands/Water/          spawnfloat (test crates/raft tagged Buoyant), cleanfloats
src/server/Runtime/BuoyancyService  steps every CollectionService "Buoyant" part/model (server-owned)
src/client/CoreClient.client.luau   boot mirror; sets game attribute ClientLoaded
src/client/Runtime/DataController   LocalPlayerData, GetDataAsync
src/client/Runtime/CmdrController   loads the console UI for admins (F2)
src/client/Runtime/WaterController/ ocean: 3x3 wave chunks + far ring (EditableMesh) + horizon Parts,
                                    all following the camera cell; Underwater look; PlayerFloat
src/shared/Data/Water.luau          ocean registry: waves, chunk LODs, colour gradient, buoyancy tuning
src/shared/Water/                   WaveField (shared Gerstner maths), WaterColor, Buoyancy (forces)
src/shared/Modules/                 ProfileTemplate, Developer (admin gate)
src/shared/Utility/                 ReplicaService/Controller, BootTimer, RateLimiter,
                                    convertNumberToSuffix
src/flags/                          studio-only FFlags (BootTiming, JoinReport)
```

Rojo reads `default.project.json` at startup, so changing it needs a **restart** of `rojo serve`.

## Verifying

`tools/typecheck.sh` runs luau-lsp analyze and a StyLua parse check over `src` (only StyLua
**stderr** means a parse error). After `wally install`, re-run
`wally-package-types --sourcemap sourcemap.json Packages/` so luau-lsp sees package types.
