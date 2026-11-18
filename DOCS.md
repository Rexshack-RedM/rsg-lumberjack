# rsg-lumberjack — Developer Docs

Version 3.3.0. No ox_lib dependency — uses rsg-core and rsg-target only.

## Dependencies
`rsg-core`, `rsg-target`, `rsg-inventory`, `oxmysql`.

## Framework functions used
| Purpose | Call |
|---|---|
| Locales | `@rsg-core/shared/locale.lua` + `locale('key', ...)` (language from `setr rsg:locale <lang>`) |
| Client notify | `RSGCore.Functions.Notify({ title, description, type, duration })` |
| Server notify | `TriggerClientEvent('RSGCore:Client:Notify', src, data)` |
| Progress bars | `RSGCore.Functions.ProgressBar({ duration, label, canCancel, disable, anim, prop })` |
| Anim loading | `RSGCore.Functions.RequestAnimDict` / `RequestAnimSet` |
| Text UI (sell zone) | `exports['rsg-core']:DrawText(text, 'left')` / `HideText()` |
| Targeting | `exports['rsg-target']:addModel / addLocalEntity / removeLocalEntity` |
| Callbacks | `RSGCore.Functions.CreateCallback('rsg-lumberjack:server:requestChop', ...)` |

## Server events (client → server)
| Event | Args | Notes |
|---|---|---|
| `rsg-lumberjack:server:requestSync` | — | Rate-limited full state sync |
| `rsg-lumberjack:server:cancelChop` | — | Clears pending chop |
| `rsg-lumberjack:server:completeChop` | kind, targetId | Re-validated against pending action + elapsed time |
| `rsg-lumberjack:server:dropLog` | — | Position from server ped |
| `rsg-lumberjack:server:pickupLog` | logId | |
| `rsg-lumberjack:server:pickupWood` | woodId | Claimed before reward |
| `rsg-lumberjack:server:plantTree` | pos, heading | Range-checked |
| `rsg-lumberjack:server:waterTree` | id | |
| `rsg-lumberjack:server:addLogToWagon` | wagonNetId | |
| `rsg-lumberjack:server:removeLogFromWagon` | wagonNetId | |
| `rsg-lumberjack:server:sellWagonLoad` | — | Wagon/price resolved server-side |

## Callback
`rsg-lumberjack:server:requestChop(kind, targetId)` → `{ ok, duration, reason, args }`.

## Database
`rsg_lumberjack_trees` — auto-created on start; `install/database.sql` for manual install.

## Config
See `shared/config.lua`: `Chopping`, `Planting`, `Items`, `Models`, `Carry`, `Wagon`, `WagonSellLocations`, `Trees`.

## Changelog
- **3.3.0** — Optional rsg-skills integration (`Config.Skills`): lumberjack XP and `extra_yield` perk on wood pickup.
- **3.2.0** — Migrated off ox_lib to rsg-core (locale, notify, progress bar, anim loading, text UI); ox_target → rsg-target. Progress `disable.car` → `disable.mount`.

## rsg-skills integration

`Config.Skills = { Enabled, Skill, WoodXP, ExtraYield }`. In `rsg-lumberjack:server:pickupWood`, after the piece is claimed and added, the server calls `AddXP(src, 'lumberjack', WoodXP, ...)`. When `ExtraYield` is on, it rolls `math.random(100) <= GetPerk(src, 'lumberjack', 'extra_yield')` and adds one more piece when `CanAddItem` allows it. Everything runs on the server; skipped when rsg-skills is not started.

