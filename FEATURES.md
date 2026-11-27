# MOHAB Plus features

<!--
  Player-facing list shown in the launcher's FEATURES tab (embedded at build time) and linked from the README.
  Keep it short and non-technical. Update it in the same commit as any feat/fix that players notice.
  "Fixes" lists only problems of the original game that the mod fixes, never bugs of the mod itself.
  Format: "## Group" (Features / Fixes), "### Category", "- **Title** - one or two sentences."
-->

## Features

### Syringes
- **Trigger to inject** - A syringe only injects when you bring it to your chest *and* pull the trigger of the hand holding it.
- **Smaller syringes on the sleeve** - Stored syringes look smaller on your sleeve and get their normal size back when you grab them.

### Weapons
- **Manual holsters** - Letting go of a weapon drops it to the floor, with the ammo it had: it falls with your hand's movement, also when you held it by the front with your other hand. To put it away, take it to its holster and let go: pistols at the hip, rifles, shotguns and other long weapons at either shoulder, grenades and explosives on the chest, if that holster is free. It goes in at once, without flying back. A grenade goes in when your hand is at the row of grenades on your chest, a bit farther than where you take one. A light tap tells you when letting go would put it away (when your hand stops there, not when it just passes by, and only once while it rests there; not while you aim or hold the weapon with both hands). Taking a weapon with your other hand (from a holster or the floor) puts away only the one in your weapon hand: it flies back to its holster as in the original game, and your other hand keeps the new one. With your holsters full you can still use a weapon from the floor without losing yours. Mission objects always come back to you. Distance adjustable, or turn it off for the game's automatic holsters.
- **Flick to drop** - With manual holsters off, weapons you let go of fly back to their holsters as in the original game, but letting go while you flick your hand sharply, as if throwing the weapon away, drops it to the floor. Works with either hand, with pistols, rifles and grenades (with the pin in). How sharp the flick must be is adjustable.
- **Nearest holster** - With manual holsters off, a weapon you let go of flies to the free holster nearest to your hand instead of always your weapon hand's side: the hand that let go of it last counts (your weapon hand if you held it with both). A rifle let go of by your left shoulder goes to the left shoulder.
- **All your grenades on the chest** - The grenades you carry (up to 3) are shown in a row on your chest, a bit smaller. Take the one you want: the one your hand is closest to grows and you feel a light tap. The others stay there while you hold it, so you can have one in each hand. With 3 on your chest you can still pick up one more in each hand from the floor.
- **Grab distances** - Choose how close your hand must be to take what you carry, so you don't grab things by accident: one distance for your inventory (grenades, mission objects on your chest, syringes on your sleeve; 10 cm by default) and another for weapons in holsters (20 cm by default). Weapons on your back and shoulders and the magazine pouch of the weapon in your hands keep the game's distance.
- **Realistic grenade throws** - A grenade flies at the speed and spin of your hand, with or without its pin (the game threw it twice as fast, but only with the pin out), keeps its speed in the air and bounces by its weight: the metal American grenade bounces and rolls, the stick grenade a bit less, the soft Gammon bag hardly at all. The strength can be adjusted.
- **Pulling the pin with your teeth** - Choose how close a grenade in your hand must get to your mouth to pull its pin with your teeth (5 cm by default, 10 cm in the game, 0 = never), so it doesn't come out by accident when you take a grenade from your chest.
- **Precise two-handed grip** - Your free hand only grabs the front grip of a weapon when it is really close to it.
- **Manual or automatic cocking** - Choose "Manual" and you work the weapon yourself: after a reload, grabbing the front grip no longer cocks it (put your hand on the bolt or slide and pull it), and on bolt-action rifles letting go of the bolt halfway no longer finishes the cycle for you (grab it again to finish). "Automatic" keeps the game's behaviour.
- **Second grip first** - With your free hand at your weapon's front grip, nearby weapons and ammo boxes are ignored, so you always grab your own weapon.
- **Helmet-safe back holsters** - With your hand above your eyes (touching your helmet or hat) no weapon is pulled from a holster; take them from behind your shoulders, also with your head bent down.

### Movement
- **Crouch with the turn stick** - Push the turn stick down to crouch and up to stand (how far you must push it is adjustable).
- **Slower when crouched** - Crouched, for real or with the stick, you walk at 60% of your normal speed (adjustable; the original game does not slow you down).
- **Arm-swing sprint** - Swing your arms like a runner to sprint; the faster you swing, the faster you run. Stick-click sprint still works.
- **Always sprint** - Optional sprint mode: you run just by pushing the stick, without clicking it or swinging your arms, and only walk while you aim a gun (pointing it where you look, at eye level), raise a grenade or another explosive to throw it, or shoot. Taking a rifle to a back holster or carrying it across your chest or low does not slow you down. Push the stick gently to walk without aiming. Choose between stick click, arm swing, stick + arms and always sprint.
- **No sprinting while aiming or shooting** - Aiming a gun (one or both hands), raising a grenade or other explosive to throw it, or pulling the trigger of a weapon, cancels the stick-click sprint and puts you at walking pace in the always sprint mode; arm-swing sprinting still lets you shoot.
- **Progressive sprint** - The stick-click and always sprints build up from walking pace to full speed over a second and a half instead of starting at top speed. Stopping, sliding, crouching or shooting starts the build-up again.
- **Faster sprint** - Raise the maximum sprint speed up to x1.5.
- **Realistic turns** - Turning sharply while sprinting costs speed, which comes back over a second; a full U-turn drops you to walking pace (strength adjustable, 0 turns it off). Sprinting sideways or backwards is at most half as fast.
- **Steady speed on stairs** - Going up or down stairs and slopes no longer speeds you up: in the original game the engine keeps your speed over the ground and adds the climb on top, so you move noticeably faster along the stairs than on flat ground. Walking and sprinting.
- **Slide** - Crouch while sprinting (with the stick or for real) to slide, with a scraping sound.
- **Jump (experimental)** - Push the turn stick up while standing to jump, with an effort grunt and cloth sounds. You can climb onto and walk around on tables, rocks and crates, but jumps can't take you over the level's invisible barriers; no jumping under a low ceiling, while swimming or skiing (on by default; it can be turned off, and height (up to 1.2 m), sounds and how far you must push the stick adjusted). The stick only needs to point roughly up (a push slightly to the side still jumps), and a jump pressed a moment too early (just after landing, or on a step) still happens instead of being lost.
- **Hard landings** - After a big fall (2 m or more by default, jumped or not) you bend down on landing and come back up, with a bigger effort grunt and a jolt in both controllers; the bigger the fall, the deeper and longer. If the fall hurts, the game's own pain reaction plays instead. Can be turned off, and the height adjusted, in the Jump options. Experimental: the levels were not designed for jumping, so some spots may still let you reach places you should not.
- **Fairer fall damage** - The original game takes the same big chunk of health for any fall from about 3.3 m up, however high. With the mod, falls under 3.5 m don't hurt and the damage grows with the height (from a scratch to a heavy hit just below the fatal 10 m). Safe height, fatal height and amount are adjustable, or switch back to the game's rules.

### Haptics
- **Damage vibration** - The controllers vibrate when you get hurt, stronger for big hits and on the side of the impact.
- **Weapon handling vibration** - Feel magazines, clips, shells and bullets going in, and break-action shotguns opening and closing.
- **Grab zone vibration** - A light tap tells you when your empty hand is close enough to take a holstered weapon or something you carry (grenades, objects, syringes). No tap at a holster whose weapon is in your other hand: an empty hand only feels full holsters, a hand holding a weapon only free ones.
- **Out of ammo vibration** - Pressing grip at your magazine pouch when you have no ammo left gives three short taps on that hand.

### Cutscenes
- **Skip cutscenes** - Hold both triggers and both grips for a second to skip a cutscene.
- **Fast-forward dialogue** - The same gesture speeds through dialogue scenes where you just stand and wait.

### Launcher and menu
- **In-game settings menu** - Hold the left Y button to change every option without leaving VR. Options are grouped in categories (switch with the grips), with a short explanation of the selected one; press X for a detailed description. Values only change after pressing A or the trigger on an option (B cancels), so moving the sticks never changes a setting by accident.
- **Basic and advanced views** - The basic view shows only the main options (movement, weapons, comfort); the advanced view shows every option, including distances, sizes and sounds. Switch in the in-game menu or in the launcher (the choice is shared). Hidden options keep working with their values.
- **Option details** - Every option has a detailed description: what it does, how the original game behaves and its default value. In the launcher, point at the (i) next to an option (click it to keep it open); in the game, press X on an option.
- **Mod on/off switch** - From the in-game menu, turn every change of the mod off and on again at once (or hold a thumbstick click) to compare with the original game. Your settings are kept, and the mod is always on when the game starts.
- **Auto-load from Virtual Desktop / Oculus** - Start the game as usual; the launcher loads the mod by itself.
- **Automatic updates** - The launcher tells you when a new version is out and installs it with one click.
- **No game files modified** - Start the game without the launcher and it is exactly the original.

## Fixes

### Grabbing
- **Grab guide not matching the blue object** - The game lit (and took) the object nearest to a point in front of your hand, and often kept it while you pointed at another one. Now it is the one your hand's guide points at, also from a distance; things beside or behind your hand are not lit, nor anything loose while your hand is at something on your chest or sleeves, or close to a weapon in a holster at your hip or shoulder (so you take your own weapon, not one on the floor your hand points at). The pin, ring or cap of the grenade in your other hand is taken as soon as your hand is at it, instead of an object farther along the guide (can be turned off).

### Weapons
- **Front grips grabbed from far away** - The game let your free hand grab a weapon's front grip from up to two metres away.
- **Automatic cocking lost with the precise grip** - The precise two-handed grip could switch a front grip back on while the game had it disabled (weapon waiting to be cocked), so taking the grip no longer cocked the weapon as in the original game, even with the mod switched off from the menu.
- **Loose front grips** - If a weapon's front grip comes loose and falls, it is put back so you can keep using both hands.
- **Weapons pulled instead of your helmet** - Grabbing near your head took a weapon from the back holster first.

### Syringes
- **Accidental grabs from your body** - Syringes, grenades and other things you carry were easy to grab by mistake when your hands passed near them.
- **Accidental injections** - Syringes no longer inject just because they touch your chest while you move them around.

### Respawning
- **Wrong direction after respawning** - If you were physically turned when you died, the game could respawn you looking the wrong way. Now you always face the checkpoint's direction.
- **View turning after respawning** - A second or two after respawning at a checkpoint, the game turned your view back to the direction you had when respawning. Now you keep looking where you are.

### Cutscenes
- **Unskippable scenes** - Many scenes and dialogues the game did not let you skip can now be skipped or sped up.
