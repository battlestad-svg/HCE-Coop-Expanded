===============================================================================
 HALO: CAMPAIGN EVOLVED - CO-OP EXPANDED                    v1.10.0
===============================================================================

Co-op Expanded is an expanded version of JPurd123's
"Halo Campaign Evolved Split-screen Coop" mod.

It builds on the original split-screen foundation with easy local P2 joining,
live split orientation, in-mission armor and weapon skin customization, Limited
Respawns, keyboard controls, HUD fixes, synchronized vehicle colors, independent
first/third-person Perspective switching, Controller Settings integration, and
experimental 2-PC network campaign support with local split-screen on both PCs.

v1.10.0 ships Steam Win64 and Xbox App / PC Game
Pass WinGDK payloads together. Install only the platform folder matching your game.


===============================================================================
 WHAT IS NEW IN v1.10.0
===============================================================================

CONTROLLER SETTINGS LAYOUT
--------------------------
Halo's Controller Settings page now shows Co-op Expanded shortcuts directly in
the frontend and in-game pause menus. Vanilla actions remain visible, with the
mod shortcuts added beneath the matching controls.

Page title:
  CO-OP EXPANDED CONTROLS

See CONTROLS.txt for the full layout.

BETTER KEYBOARD/MOUSE + CONTROLLER SUPPORT
------------------------------------------
Controllers=1 provides:

  Player 1: keyboard/mouse
  Player 2: first gamepad

Steam now supports both normal XInput controllers and Steam Input virtual
controllers in this mode. The release was tested with Xbox, DualSense/PS5,
8BitDo Lite 2 and PS3-class controllers, wired and wireless, both connected
before launch and hot-plugged after reaching the frontend.

P2 joining is also more robust: the mod waits until Halo can actually see the P2
controller route before completing the join.

Game Pass / WinGDK supports Controllers=1 with native Xbox/XInput only.

FIXED: PLAYER 1 ESCAPE / PAUSE
------------------------------
Fixed a Controllers=1 issue where keyboard Escape for Player 1 could stop opening
pause after Player 2 used pause/settings. The recovery preserves an active P2
menu and uses Halo's normal fullscreen pause flow for P1.

LIMITED RESPAWNS VOICE BROADCAST
--------------------------------
The host can now broadcast Limited Respawns status through Halo's existing TTS
system. Vanilla remote clients can hear these synthesized announcements without
installing Co-op Expanded.

Voice broadcast is ON by default and controlled by host P1:
  Controller: RB / R1 + Y / Triangle
  Keyboard:   Ctrl + F8

Announcements include current lives, death/lives updates, reinforcement warning
milestones, reinforcement availability and the no-lives/restart state.

OTHER RELEASE IMPROVEMENTS
--------------------------
- More reliable P2 A/Cross joining during startup/frontend timing changes.
- Existing Perspective, armor, weapon-skin, split-layout, Limited Respawns and
  synchronized vehicle-color features are retained.
- Controllers=2 remains the default for backward compatibility.
- VehicleMessageProtocol remains version 3.

===============================================================================
 PACKAGE CHOICE
===============================================================================

STANDALONE
----------
Contains HCE Co-op Expanded only, including its project-owned native helpers.
Use this if you already have the compatible Halo-specific UE4SS runtime and
UEHelpers installed.

COMPLETE-UE4SS
--------------
Contains HCE Co-op Expanded plus the tested Halo-specific UE4SS compatibility
runtime used by this release.

Bundled/tested runtime:
  UE4SS v3.0.1 Beta #0
  Git SHA: c838a8ac
  Halo compatibility release: 1.3

Supported game build recorded by that compatibility package:
  2026.06.26.1097863.1-Rel-i343-Meteorite-2606-CU2


===============================================================================
 INSTALLATION
===============================================================================

STEAM / WIN64
-------------
1. Close Halo.
2. Open the Steam-Win64 folder in this archive.
3. Copy its Meteorite folder into the Halo: Campaign Evolved install directory.
4. Keep the folder structure intact and allow matching files to merge/overwrite.

The mod should end up at:
  Meteorite\Binaries\Win64\ue4ss\Mods\HaloSplitscreenCoop

XBOX APP / PC GAME PASS / WINGDK
--------------------------------
1. Close Halo.
2. Open the GamePass-WinGDK folder in this archive.
3. Copy its Meteorite folder into the game's Content directory.
4. Keep the folder structure intact and allow matching files to merge/overwrite.

The mod should end up at:
  Content\Meteorite\Binaries\WinGDK\ue4ss\Mods\HaloSplitscreenCoop

Before starting local co-op on Game Pass, read:
  GamePass-WinGDK\README-MANUAL-OFFLINE-WORKAROUND.txt

LINUX / STEAM DECK / PROTON
---------------------------
For Steam/Proton, install the Steam-Win64 payload and use this launch option if
required by the bundled Halo UE4SS compatibility runtime:

  WINEDLLOVERRIDES="dwmapi=n,b" %command%

The %command% part is required.

PIRATED / MODIFIED EXECUTABLES
------------------------------
Pirated/cracked executables are not supported. The Halo-specific UE4SS
signatures and native helpers depend on the supported retail executable layout.


===============================================================================
 CONTROLLER CONFIGURATION
===============================================================================

The included settings.ini defaults to:

  [Input]
  Controllers=2

CONTROLLERS=2 - DEFAULT / BACKWARD COMPATIBLE
---------------------------------------------
  Player 1: keyboard/mouse and controller 1
  Player 2: controller 2

This remains the default so existing installations retain the established
behavior without editing settings.ini.

CONTROLLERS=1 - KEYBOARD/MOUSE P1 + FIRST GAMEPAD P2
----------------------------------------------------
  Player 1: keyboard/mouse
  Player 2: first gamepad

Steam / Win64:
- native Xbox/XInput controllers are supported;
- Steam Input virtual-controller routing is supported;
- controller hot-plug after Halo has launched is supported;
- P2 creation is held until Halo's logical P2 input slot is verified live.

Xbox App / PC Game Pass / WinGDK:
- native Xbox/XInput is supported;
- PlayStation/Steam-Input-style virtual controller paths are not supported in
  Controllers=1 and are listed in KNOWN-ISSUES.txt.

The adaptive companion file is named HCEXInputSteamBypass.dll for historical
reasons. Its release behavior is an adaptive router, not a generic
controller emulator or driver.

The project-owned xinput1_4.dll is part of the tested route and must remain the
package copy. Do not replace it with an unrelated XInput proxy.


===============================================================================
 LOCAL SPLIT-SCREEN CO-OP
===============================================================================

Player 2 can join from the split-screen sign-in interface using P2's gamepad:
  Xbox-style route: A
  PlayStation route through Steam Input: Cross

Ctrl+Y remains available as a Player 2 creation fallback.

To leave the local session from a frontend/menu, hold A / Cross on Player 2 for
about two seconds. Ctrl+U remains the keyboard fallback.

Co-op Expanded handles local controller IDs, split layout, HUD repair/scaling,
campaign transitions and related local-player state automatically.


===============================================================================
 CONTROLLER SETTINGS PAGE
===============================================================================

The mod extends Halo's existing Controller Settings screen rather than creating
a separate menu. It is applied in the frontend and in each local player's pause
stack, including after Halo refreshes/reconstructs the menu.

Title:
  CO-OP EXPANDED CONTROLS

The normal Halo labels stay visible. Co-op Expanded adds its shortcut under the
matching control. Important additions include:

  RB              Co-op Expanded modifier
  RB + D-pad Up   Respawn Limit (P1)
  RB + D-pad Left Previous Armor
  RB + D-pad Down Split Orientation
  RB + D-pad Right Next Armor
  RB + X          Weapon Skin
  RB + B          1st / 3rd Person
  A               Menu Join P2 / hold Leave P2
  RB + Y          Respawn Voice ON/OFF (P1)
  RB + LS / RS    Previous / Next Vehicle Color

The menu text intentionally uses concise Xbox-style button labels such as RB,
A, X, LS and RS so the same stable layout works across PC controller families.
See CONTROLS.txt for the dedicated quick-reference page.


===============================================================================
 GAME PASS / WINGDK LOCAL CO-OP
===============================================================================

The WinGDK path uses the platform-user Add/Login/Promote flow required by the
Xbox App / PC Game Pass build. Steam continues to use its established
CreatePlayer path. The same main.lua is used by both platform payloads.

Controllers=2 remains the default/documented broad compatibility path.
Controllers=1 is also supported with a native Xbox/XInput controller.

The release-tested Game Pass workflow still includes a manual offline transition:
join local P2 in the co-op lobby/fireteam first, then Alt+Tab and disable the
active LAN/Wi-Fi adapter before starting/loading the mission. Start the mission
while offline and re-enable the adapter only after the local split-screen mission
is visibly loaded. Follow the included WinGDK guide for the exact sequence.

The mod does not automatically disable/re-enable adapters or modify firewall rules.

If Player 2 loads to a black screen, fully exit Halo and retry the documented
sequence from a fresh process. Restarting only a mission/checkpoint has not been
a reliable recovery for that state.


===============================================================================
 PLAYER 2 SETTINGS INHERITANCE
===============================================================================

When local Player 2 is created, Co-op Expanded copies relevant Player 1 per-user
gameplay/video settings into Player 2 once, then applies them. This avoids hidden
lower/default P2 values that are not exposed in P2's reduced Settings menu.

The join-time copy includes HUD anchoring, Warthog driving mode, upscaling
quality/preset, graphics quality groups, motion blur, screen shake and related
per-user visual settings.

Shared/global renderer settings such as display mode, VSync, HDR and frame-rate
limits remain owned globally by Halo rather than being written separately to P2.


===============================================================================
 HUD AND SPLIT-SCREEN LAYOUT
===============================================================================

The mod repairs HUD scale/anchoring for split-screen and reapplies it after
relevant video-menu, mission, cinematic and orientation transitions.

Previously validated split-screen resolutions include:
  1280x720
  1600x900
  1920x1080
  3440x1440 ultrawide

Switch split orientation live between Left/Right and Top/Bottom:

Controller - either local player:
  RB / R1 + D-pad Down

Keyboard - Player 1:
  Ctrl + Down Arrow

Legacy fallback:
  Ctrl + O


===============================================================================
 LIVE FIRST / THIRD PERSON PERSPECTIVE
===============================================================================

The Perspective skull is not required.

Controller - either local player:
  RB / R1 + B / Circle

In local co-op, P1 and P2 can switch independently. One player can remain in
first person while the other uses third person. Hybrid network + local-split
routing contains separate Steam-client and WinGDK-client context handling so the
controller shortcut targets the intended local player.

Keyboard - Player 1:
  Ctrl + B

In local co-op Ctrl+B remains a global fallback that switches both local views.


===============================================================================
 IN-MISSION ARMOR SWITCHING
===============================================================================

Both local players can cycle Master Chief armor while playing without returning
to the Customization menu. The mod exposes 27 armor entries discovered from the
game's live customization data.

Controller:
  RB / R1 + D-pad Left   - previous armor
  RB / R1 + D-pad Right  - next armor

Keyboard - Player 1:
  Ctrl + Left Arrow      - previous armor
  Ctrl + Right Arrow     - next armor


===============================================================================
 LIMITED RESPAWNS
===============================================================================

Limited Respawns work in solo campaign and local co-op.

At mission start:
  RESPAWN LIMIT: OFF

Available values:
  OFF -> 5 -> 10 -> 20 -> 30 -> OFF

Controller - Player 1:
  RB / R1 + D-pad Up

Keyboard - Player 1:
  Ctrl + Up Arrow

After selection, a short countdown locks the value for that mission.

Solo:
- each death consumes one life.

Local co-op:
- both local players share the life pool;
- each player death consumes one life.

At zero lives, surviving for 120 seconds grants one reinforcement life. Dying
again while still at zero triggers a mission restart.

Network co-op:
- Limited Respawns are host-authoritative;
- only local P1 on the network host configures/owns the limit;
- compatible modded clients receive host HUD state but cannot own a competing
  respawn state;
- a vanilla remote client can still participate when the host owns the feature.

LIMITED RESPAWNS VOICE ANNOUNCEMENTS
------------------------------------
Voice announcements are ON by default. Only authoritative host P1 can toggle them:

Controller:
  RB / R1 + Y / Triangle

Keyboard:
  Ctrl + F8

The feature uses Halo's existing hidden chat/TTS transport and restores the
player's original runtime TTS state after sending. It is designed so a vanilla
remote peer can hear synthesized Limited Respawns status without needing the mod.
The chat widget is hidden before/after transmission.

Announcements include:
- Limited Respawns activation and current lives;
- coalesced lives-remaining messages after deaths;
- reinforcement warnings at 120, 90, 60 and 30 seconds;
- a five-second reinforcement warning;
- reinforcement available;
- no lives / restarting.

If no remote peer exists, the voice transport stays dormant. Local/modded HUD
text is independent and remains available.


===============================================================================
 WEAPON SKIN SWITCHING
===============================================================================

With a supported weapon equipped:

Controller:
  RB / R1 + X / Square

Keyboard:
  Ctrl + X

The system supports seven verified weapon families and includes skins that are
not always exposed through the normal customization menus.


===============================================================================
 VEHICLE COLOR SWITCHING
===============================================================================

Supported Warthog and Scorpion vehicles can use the 18 original Halo CE
multiplayer colors plus ORIGINAL.

While positively identified as the driver:

Controller:
  RB / R1 + L3 / R3      - previous / next color

Keyboard:
  Ctrl + Page Up / Down  - previous / next color

Vehicle color networking uses protocol 3 and is capability-gated. Compatible
Co-op Expanded peers can synchronize supported vehicle colors; custom color
traffic is not sent to vanilla/unverified peers.

The bounded P2 Warthog driver recovery used by the hybrid network + local-split
topology requires exact driver proof and never chooses a vehicle by proximity.


===============================================================================
 KEYBOARD QUICK REFERENCE - PLAYER 1
===============================================================================

  Ctrl + Y                - create P2 fallback
  Ctrl + U                - remove P2 in frontend
  Ctrl + Left / Right     - armor
  Ctrl + Up               - Limited Respawns
  Ctrl + Down             - split orientation
  Ctrl + X                - weapon skin
  Ctrl + Page Up / Down   - vehicle color
  Ctrl + B                - Perspective
  Ctrl + F8               - Limited Respawns voice broadcast ON/OFF


===============================================================================
 EXPERIMENTAL 2-PC NETWORK + LOCAL SPLIT-SCREEN
===============================================================================

Co-op Expanded includes a hybrid mode where two PCs connect over the network
and either PC can also add a local split-screen player, allowing up to four
campaign players across two PCs.

Recommended join order:
  HOST P1 -> REMOTE P1 -> LOCAL P2 -> LOCAL P2

Connect network players first, then add local split-screen players.

The mod deliberately ignores remote PlayerController objects when building each
PC's local-player cache.

Mixed modded/unmodded sessions remain possible for normal Halo replication.
Features that use Co-op Expanded's custom peer protocol, such as synchronized
vehicle colors, require compatible modded peers for that custom data.

VehicleMessageProtocol remains 3 in this release.


===============================================================================
 KNOWN LIMITATIONS
===============================================================================

- Game Pass Controllers=1 supports native Xbox/XInput only. PlayStation-family
  and other non-native virtual-controller paths are not supported on WinGDK.
- Game Pass local co-op still depends on the documented manual-offline workflow:
  join P2 in the lobby, disconnect before mission start, reconnect after the
  mission/local split session is loaded.
- If Game Pass P2 loads black, fully exit Halo and retry the full sequence.
- After leaving a complex hybrid network + local-split session, Halo's own online
  session state can occasionally refuse an immediate reconnect. A full game
  restart is the reliable recovery if repeated reconnect attempts fail.
- FSR can produce persistent shimmering/fine noise in P2's split view on some
  detailed surfaces. TSR, DLSS or XeSS may avoid the artifact.
- Frame Generation can produce unusual P2 ghosting/artifacts on some systems.
- The Complete package's Halo-specific UE4SS runtime targets the game build
  listed near the top of this README.

See KNOWN-ISSUES.txt for the focused known-issues list.


===============================================================================
 UNINSTALLATION
===============================================================================

Remove:
  ue4ss\Mods\HaloSplitscreenCoop

from the platform-specific binary directory.

The project-owned xinput1_4.dll in that same Win64/WinGDK directory is part of
Co-op Expanded's controller-slot routing. Remove it as well if no other local
installation depends on that file.

If you installed Complete-UE4SS and no other mods require the bundled UE4SS
runtime, that runtime can also be removed.

Co-op Expanded does not permanently modify campaign/save files.


===============================================================================
 CREDITS
===============================================================================

JPurd123
- Creator of the original "Halo Campaign Evolved Split-screen Coop" mod that
  Co-op Expanded is based on.

JoacoL999 / joaqo455
- Work credited by the upstream project relating to side-by-side split-screen,
  controller routing, HUD corrections and Game Pass testing.

bfixer117 / HCE Revival
- Additional split-screen research, XInput routing direction, HUD/load handling
  and the Game Pass workaround direction.

red2k1
- Testing/documentation of the repeatable Game Pass controller/sign-in sequence
  used by the WinGDK workaround.

beanzrod
- Perspective research reference. The included BEANZROD_PERSPECTIVE_LICENSE.txt
  carries the applicable MIT notice. Co-op Expanded does not redistribute
  beanzrod's version.dll or shoulder_swap.ini.

Narknon and RE-UE4SS contributors
- UE4SS framework and upstream split-screen examples that made the project
  possible.

See THIRD_PARTY_NOTICES.txt and the included license files for details.


===============================================================================
 AUTHORSHIP / AI DISCLOSURE
===============================================================================

The Nexus uploader/project owner defines desired features and behavior, performs
hands-on game testing, supplies logs, reports regressions and directs releases.

Custom Lua/native implementation and iterative code changes for Co-op Expanded
have been developed with OpenAI ChatGPT based on those specifications, feedback
and test results.

All upstream/original work remains credited to its respective creators.

Not affiliated with Halo Studios, 343 Industries, Xbox Game Studios or
Microsoft.
