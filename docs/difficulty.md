# How difficulty works in the game

Study of what the Easy / Normal / Hard setting changes in **Medal of Honor: Above and Beyond**
(Oculus build, Unreal Engine 4.25.3, unmodified game). Date: 2026-11-24.

**Method.** Static analysis only: disassembled Blueprints, data tables and default values read from the
paks, plus a search of the native executable. Nothing here has been confirmed by playing.

## Summary

- Difficulty changes the **player's health** and, on Easy only, the **damage and aim of the player's weapons**.
- For weapons, Normal and Hard are identical.
- Nothing was found that changes enemy AI, health, damage, accuracy or numbers in general.
- A few levels and modes have their own rules (see [Special cases](#special-cases)).

## Player health

Source: `BP_VRPlayerCharacterHealthAndDamageComponent:UpdateHealthBasedOnDifficulty`
(skipped in multiplayer).

| Variable | Easy (0) | Normal (1) | Hard (2) |
|---|---|---|---|
| `MaxHealth` | 800 | 400 | 250 |
| `AutohealRatePerSecond` | 200 | 100 | 60 |
| `LowHealthEventDuration` (s) | 3 | 2 | 1 |

Same on every difficulty (class defaults):

| Variable | Value | Meaning |
|---|---|---|
| `LowHealthEventThreshold` | 80 | Critical health |
| `LowHealthEventDamageTakenMultiplier` | 0.1 | Damage taken during the critical protection |
| `AutoHealCoolup` | 5 s | Wait after the last damage before healing |
| `MaxSyringeCount` | 3 | Syringes |

Rules:

- **Critical protection.** The first hit that would leave the player at 80 or less sets health to exactly 80.
  For `LowHealthEventDuration` seconds, damage is multiplied by 0.1. It is available again only after a full heal.
- **Auto-heal.** Above 80 it heals up to `MaxHealth`. At 80 or less it never goes past 80.
- **Syringe.** Calls `PlayerFullHeal`: full health, and the critical protection is available again.
- **Changing difficulty.** Health above the new maximum is trimmed.

Hits needed to reach critical health, from full health (calculated: rank 3 enemy with damage x1, no auto-heal,
no body-region modifiers):

| Enemy weapon | Damage | Easy | Normal | Hard |
|---|---|---|---|---|
| MP40 | 27 | 27 | 12 | 7 |
| Karabiner 98 | 260 | 3 | 2 | 1 |

## Player weapons (Easy only)

Source: `BP_WeaponBase:UpdateWeaponBasedOnDifficulty`, `EnableEasyMode`, `PrecacheWeaponDef`, `LaunchProjectile`.
Standalone game only. It runs when the player grabs a weapon, and on the holstered weapons when the option changes.

- **Damage.** x2 (`PrecacheWeaponDef`); x4 for `BP_CombatShotgun` and `BP_LeverAction`, which override it.
- **Ammo.** `EnableEasyMode` sets `Ammo` to `AmmoPerLoad` when the weapon enters easy mode.
- **Aim, weapons without scope.** Sphere trace of 60 cm radius and 40 m from the muzzle. If it hits an enemy,
  the shot is redirected to the neck (`jx_c_neckB`). Chance: `EasyModeHeadSeekChance` = 100 %, but 33 % for
  BAR, Thompson, MP40 and StG44.
- **Aim, scoped weapons.** The trace is 30 cm radius and 80 m, and the shot is redirected to the bone that was hit.
  This correction also exists on Normal and Hard, with a radius of 8 cm.
- **No exceptions found.** Among the weapon Blueprints, only `BP_SawedOff` overrides `LaunchProjectile`, and it
  moves the muzzle to the right barrel and calls the base function, so it keeps the aim assist.

## Special cases

### Omaha beach landing (312)

`312_DesignLevel:CheckDifficulty` sets `OverrideDamageMulitplier` on the scripted bullets:

| Blueprint | Easy | Normal | Hard |
|---|---|---|---|
| `BP_312_PlayerPusherMagicBullet` | 0.4 | 0.7 | 1 |
| `BP_312_CinematicMagicBullet`, `BP_312_ObstacleMagicBullet`, `BP_312_AIKillerMagicBullet` | 0.2 | 0.35 | 0.5 |
| `BP_312_PlayerKillerMagicBullet` | 1 | 1 | 1 |

### Rescue the scientist (623)

When Groenk spawns in the standoff, his capsule's response to the `Bullets` channel (`GameTraceChannel1`)
is *ignore* on Easy and *overlap* on Normal and Hard. The effect in play is unconfirmed.

### Quartermaster gauntlets

- Stars: +1 under par time, +1 all enemies killed, +1 with Enemy Rank off, and +0 / +1 / +2 for Easy / Normal / Hard.
- If difficulty is lowered, or Enemy Rank turned on, during the run, the lower result counts.
- One achievement per gauntlet needs Hard, Enemy Rank off and a time under par.

### Campaign progress

- Each segment stores the highest difficulty completed (`SetTrackedSegmentDifficulty`, option value + 1).
  `UpdateTempDifficulty` keeps the lowest value used during the segment.
- `CheckVeteranAchievement` (`ACH_SIM_041`) needs every segment completed on Hard.

### Survival and multiplayer

- Survival forces Normal and restores the player's setting at the end (`BP_R6GameMode_SurvivalMode`). Its own
  escalation over time (`IncreaseDifficulty`) raises `MaxEnemies` up to 7 and lowers `SpawnPauseMultiplier`.
- Multiplayer ignores the setting.

## What does not depend on difficulty

Enemy damage comes from each soldier's **rank** (`DT_AIWeaponProficiencySettings`, `AIDamageMultiplier`).
The table also holds aim and firing values per rank.

| Rank | Damage multiplier (most weapons) |
|---|---|
| 0 Friendly | 0.3 |
| 1 Recruit | 0.5 |
| 2 Enlisted | 0.7 |
| 3 Default | 1 |
| 4 Veteran | 1.75 |
| 5 Elite | 2.5 |

The `Enemy Rank` option only shows or hides the rank stars.

## Confidence and limits

- **Coverage.** The name tables of 97,305 packages (`.uasset` / `.umap` up to 6 MB, optional paks excluded) were
  searched for `ifficult`. Only 31 packages matched; none is an enemy spawner or a general AI class.
- **Native code.** `R6PlayerController:GetDifficultyOption` reads the option at offset `0x298` of the save object.
  Among the direct calls to the getter of that object, it is the only one found to read that offset. An indirect
  access cannot be ruled out.
- **Player reports.** A [Steam thread](https://steamcommunity.com/app/1402320/discussions/0/5242718027644942222/)
  claims Hard only adds enemies and that the player takes the same number of hits. The health values contradict the
  second claim, and no evidence was found for the first.
- **Not analysed.** Grenades, vehicles and mounted turrets.

## Reproducing it

- `tools/pak_extract.py` extracts the packages and `tools/kismet_dis.py` disassembles their Blueprints.
- Enum values: `EDifficulty` 0 = Easy, 1 = Normal, 2 = Hard.
- The extracted game data stays out of the repository (`extracted/` and `research/` are git-ignored).
