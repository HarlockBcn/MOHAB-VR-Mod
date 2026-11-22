# Changelog

All notable changes to MOHAB Plus. Versions follow MAJOR.MINOR.PATCH.

## v1.2.0 - 2026-11-23

### New
- **New in-game menu**: options are grouped in categories (Syringes, Weapons, Haptics, Movement, Jump, Cutscenes) shown side by side, with a short explanation of the selected option. Use the grips to jump between categories.
- **Mod on/off switch**: from the in-game menu (or by clicking a thumbstick while it is open) you can turn every change of the mod off and on again at once, to compare with the original game without leaving it. Your settings are kept, and the mod is always on when the game starts.
- **Slower when crouched**: crouched, for real or with the turn stick, you walk at 60% of your normal speed (the original game does not slow you down at all). Adjustable in the menu and the launcher.
- **Out of ammo vibration**: pressing grip at your magazine pouch when you have no ammo left for that weapon gives two taps on that hand.
- **Sprint**: sprinting sideways is limited to half speed, like sprinting backwards, and firing a weapon cancels the stick-click sprint (click again to keep running).

### Changes
- **Hats and helmets**: back and shoulder weapons are only blocked while your hand is above your eyes (it used to be a zone over your head). Reaching for a holster with your head tilted down works as before.

### Fixes
- Syringes taken from the Quartermaster's health pack appeared tiny in your hand when you took them from your sleeve.

**Updating:** if you have v1.1.0 or v1.0.x, the launcher offers this update by itself (click "Update to v1.2.0" at the top). Your settings are kept; the new crouched speed option starts at 60%.

## v1.1.0 - 2026-11-22

### New
- **Jump (experimental)**: push the turn stick up while standing to jump (pushing it up while crouched still stands you up). On by default: you can turn it off in the in-game menu or the launcher, where you can also set the height and the sounds (effort grunt with your character's voice and cloth rustle). You can climb onto and walk around on tables, crates and rocks, but jumps can't take you over the level's invisible barriers, and you can't jump under a low ceiling, while swimming or while skiing. The levels were not designed for jumping, so a few spots may still let you reach places you should not.
- **Sprint slows down on sharp turns**: turning hard while sprinting cuts your speed for a moment (adjustable, 0 = off), and sprinting straight backwards is limited to half speed.

### Fixes
- Swinging your arms while crouched no longer makes you sprint or stand up.
- The sprint could briefly go faster than the configured maximum speed.
- Weapon front grips whose collision parts fell away with the physics are put back, so two-handed grip keeps working.

**Updating:** if you have v1.0.x, the launcher offers this update by itself (click "Update to v1.1.0" at the top). Your settings are kept.

## v1.0.2 - 2026-11-21

### New
- **Second grip first**: when your free hand reaches for the front grip of the weapon you are holding, nearby weapons and ammo boxes are ignored, so you always grab your own weapon with both hands instead of picking up something else by mistake.

**Updating:** if you have v1.0.0 or v1.0.1, the launcher offers this update by itself (click "Update to v1.0.2" at the top). Your settings are kept.

## v1.0.1 - 2026-11-21

### Fixes
- After respawning, reaching a checkpoint or starting a new mission, some features could stop working because the mod kept following the previous player character. It now always follows the current one, so the two-handed grip and the helmet-safe back holsters keep working for the whole session.

**Updating:** if you have v1.0.0, the launcher offers this update by itself (click "Update to v1.0.1" at the top). Your settings are kept.

## v1.0.0 - 2026-11-21

First public release of MOHAB Plus, a gameplay enhancement mod for **Medal of Honor: Above and Beyond** (Oculus/Meta PC version). It does not modify any game file: it is a launcher that loads the mod when the game starts.

### Syringes
- **Trigger to inject**: a syringe only injects when you bring it to your chest *and* pull the trigger of the hand holding it.
- **Smaller syringes on the sleeve**: they get their normal size back when you grab them.
- **Shorter sleeve grab distance**, so you no longer grab syringes by accident.

### Weapons
- **Precise two-handed grip**: your free hand only grabs a weapon's front grip when it is really close to it (the game let you grab it from up to two metres away).
- **Helmet-safe back holsters**: reaching over your head no longer pulls a weapon from your back.
- Front grips that come loose and fall are put back, so you can keep using both hands.

### Movement
- **Crouch with the turn stick** (down = crouch, up = stand).
- **Arm-swing sprint**: swing your arms like a runner to sprint; the faster you swing, the faster you run.
- **Faster sprint**: maximum sprint speed up to x1.5.
- **Slide**: crouch while sprinting (with the stick or for real) to slide.

### Haptics
- Vibration when you take damage, stronger for big hits and on the side of the impact.
- Vibration when loading magazines, clips, shells and bullets, and when opening/closing break-action shotguns.

### Cutscenes
- **Skip cutscenes** by holding both triggers and both grips for a second.
- The same gesture **fast-forwards dialogue scenes** where you just stand and wait.

### Launcher
- In-game settings menu (hold the left Y button) and the same settings in the launcher.
- Loads the mod automatically when you start the game from **Virtual Desktop or Meta Quest Link / Air Link**: just keep the launcher open or minimised.
- Shows the installed version and **updates itself** when a new release is published here.

### Requirements
- Windows 10/11 x64, the game from the Oculus/Meta store and the [.NET 8 Desktop Runtime x64](https://dotnet.microsoft.com/download/dotnet/8.0).

*Fan-made by Harlock with the help of AI tools. Not affiliated with Respawn Entertainment, Electronic Arts or Meta.*
