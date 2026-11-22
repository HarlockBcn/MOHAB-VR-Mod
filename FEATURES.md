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
- **Shorter sleeve grab distance** - Your hand has to be closer to the sleeve to take a syringe, so you don't grab them by accident.

### Weapons
- **Precise two-handed grip** - Your free hand only grabs the front grip of a weapon when it is really close to it.
- **Second grip first** - With your free hand at your weapon's front grip, nearby weapons and ammo boxes are ignored, so you always grab your own weapon.
- **Two hands on empty weapons** - You can hold an empty weapon, or one with its magazine out, with both hands; taking its front grip gives two dry knocks on that hand (and, if you turn it on, the weapon's empty click).
- **Helmet-safe back holsters** - Reaching over your head (to touch your helmet or hat) no longer pulls a weapon from your back.

### Movement
- **Crouch with the turn stick** - Push the turn stick down to crouch and up to stand.
- **Arm-swing sprint** - Swing your arms like a runner to sprint; the faster you swing, the faster you run. Stick-click sprint still works.
- **Faster sprint** - Raise the maximum sprint speed up to x1.5.
- **Realistic turns** - Turning sharply while sprinting costs speed, which comes back over a second; a full U-turn drops you to walking pace (strength adjustable, 0 turns it off). Sprinting sideways or backwards is at most half as fast.
- **Slide** - Crouch while sprinting (with the stick or for real) to slide, with a scraping sound.
- **Jump (experimental)** - Push the turn stick up while standing to jump, with an effort grunt and cloth sounds. You can climb onto and walk around on tables, rocks and crates, but jumps can't take you over the level's invisible barriers; no jumping under a low ceiling, while swimming or skiing (on by default; it can be turned off, and height and sounds adjusted). Experimental: the levels were not designed for jumping, so some spots may still let you reach places you should not.

### Haptics
- **Damage vibration** - The controllers vibrate when you get hurt, stronger for big hits and on the side of the impact.
- **Weapon handling vibration** - Feel magazines, clips, shells and bullets going in, and break-action shotguns opening and closing.
- **Out of ammo vibration** - Pressing grip at your magazine pouch when you have no ammo left gives two taps on that hand.

### Cutscenes
- **Skip cutscenes** - Hold both triggers and both grips for a second to skip a cutscene.
- **Fast-forward dialogue** - The same gesture speeds through dialogue scenes where you just stand and wait.

### Launcher and menu
- **In-game settings menu** - Hold the left Y button to change every option without leaving VR.
- **Auto-load from Virtual Desktop / Oculus** - Start the game as usual; the launcher loads the mod by itself.
- **Automatic updates** - The launcher tells you when a new version is out and installs it with one click.
- **No game files modified** - Start the game without the launcher and it is exactly the original.

## Fixes

### Weapons
- **Front grips grabbed from far away** - The game let your free hand grab a weapon's front grip from up to two metres away.
- **Loose front grips** - If a weapon's front grip comes loose and falls, it is put back so you can keep using both hands.
- **Weapons pulled instead of your helmet** - Grabbing near your head took a weapon from the back holster first.

### Syringes
- **Accidental sleeve grabs** - Syringes were easy to grab by mistake when your hands passed near your sleeve.
- **Accidental injections** - Syringes no longer inject just because they touch your chest while you move them around.

### Cutscenes
- **Unskippable scenes** - Many scenes and dialogues the game did not let you skip can now be skipped or sped up.
