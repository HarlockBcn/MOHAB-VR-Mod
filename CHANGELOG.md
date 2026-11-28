# Changelog

All notable changes to MOHAB Plus. Versions follow MAJOR.MINOR.PATCH.

## v1.4.0 - 2026-11-28

**Important when updating:** this version resets every setting to its new defaults the first time you start it, so you start with the values the mod is now tuned for. If you had changed anything, set it again in the launcher or the in-game menu. Reinstalling v1.4.0 later keeps your settings.

### New
- **Manual holsters**: turn "Automatic holsters" off and a weapon you let go of drops to the floor. Let go of it at a free holster to put it away. Long vibrations tell you when a holster is taken, and taps follow what your hand and the holster hold.
- **Automatic holsters, improved** (default): a weapon you let go of flies to the free holster nearest to your hand. Flick your hand as you let go to drop it instead. Holstered weapons come before weapons on the floor when your hand is near both.
- **All your grenades on the chest**: every grenade you carry sits in a row on your chest, and you can take any of them.
- **Realistic grenade throws**: grenades fly with your hand's speed and spin and bounce according to their weight, instead of the game's doubled speed and sticky floors. The throw strength can be adjusted.
- **Grab what the guide points at**: an empty hand takes the object its guide points at, not a different object highlighted in blue.
- **Always sprint** (new default sprint mode): you run just by pushing the stick, and drop to walking pace while aiming, raising a weapon or grenade, or shooting. Sprinting now builds up to full speed, and holstering no longer slows you down.
- **Steady speed on stairs**: stairs and slopes no longer speed you up.
- **Separate stick thresholds** for crouching and jumping.
- **Spanish translation** of the launcher, the in-game menu and the feature list, with a language picker in the launcher. The in-game menu follows the game's language by default.
- **Basic and advanced views**: the menu and the launcher show the main options by default, and every option in the advanced view, with a detailed description of each one. Options are grouped in the same categories in the launcher and in the game.
- **Edit mode** in the in-game menu.
- **Out of ammo vibration**: now three spaced taps.

### Changes
- New defaults: always sprint mode, sprint speed x1.3 (was x1.4), crouch and jump at 70% of the stick (crouching was 95%), holstered weapons taken from 20 cm (was 25 cm).

### Fixes
- After respawning you face the checkpoint's direction, standing, and your view no longer turns by itself.
- Taking the pin of the grenade in your hand no longer grabs a farther object instead.
- Picked-up guns keep their magazine out, and no magazine appears on your hip after picking up ammo.
- Weapons dropped by the off hand fall gently, and the off hand keeps a gun it takes while the weapon hand's goes back to its holster.
- No more stray "Text" lines in the in-game menu.
- The launcher's language picker now applies a second change.

**Updating:** if you have an earlier version, the launcher offers this update by itself (click "Update to v1.4.0" at the top). Your settings are reset to the new defaults once, as explained above.

## v1.3.0 - 2026-11-24

### New
- **Fall damage**: choose the height that starts hurting (3.5 m by default) and the fatal height (10 m). Damage grows with the height instead of the game's flat amount, and can be scaled. Turn it off to get the game's rules back (flat damage from about 3.3 m, death from about 10 m). New "Fall damage" section in the menu and the launcher.
- **Hard landings**: after a big fall (2 m or more by default) you bend down and come back up, with a grunt and a jolt in the controllers.
- **Higher jumps**: jump height now goes up to 120 cm and defaults to 100 cm. Crouching and jumping with the turn stick are also more reliable when the stick is not pushed perfectly straight.
- **Grab distances**: choose how close your hand must be to take what you carry: one distance for your inventory (grenades, mission objects, syringes on your sleeve; 10 cm) and another for holstered weapons (25 cm). Weapons on your back and shoulders and the magazine pouch of the weapon in your hands keep the game's distance. The "Weapons" tab is now called "Grabbing".
- **Grab zone vibration**: a light tap tells you when your empty hand is close enough to take a holstered weapon or something you carry.
- **Manual or automatic cocking**: with "Manual" (default) you work the weapon yourself. After a reload, grabbing the front grip no longer cocks it (pull the bolt or slide), and on bolt-action rifles letting go of the bolt halfway no longer finishes the cycle for you. "Automatic" keeps the game's behaviour.
- **Pulling the pin with your teeth**: choose how close a grenade in your hand must get to your mouth to pull its pin with your teeth (5 cm by default, 10 cm in the game, 0 = never), so the pin no longer comes out by accident when you take a grenade from your chest.

### Changes
- New default: the second hand grabs a weapon's front grip from 10 cm (was 15 cm).

### Fixes
- With the precise two-handed grip, grabbing the front grip of a weapon waiting to be cocked did nothing, and the weapon was not cocked as in the original game (even with the mod switched off from the menu).

**Updating:** if you have an earlier version, the launcher offers this update by itself (click "Update to v1.3.0" at the top). Your settings are kept. New options start at their defaults.

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
