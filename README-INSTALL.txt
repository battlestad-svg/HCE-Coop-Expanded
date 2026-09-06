HCE CO-OP EXPANDED v1.10.0
===============================
Steam Win64 + Xbox App / PC Game Pass WinGDK

THIS ARCHIVE CONTAINS BOTH PC VARIANTS.
Install only the folder for the version of Halo you own/use.

STEAM
-----
Use the payload under:
  Steam-Win64\

Copy its Meteorite folder into the Halo: Campaign Evolved install directory so
that the mod ends up under:
  Meteorite\Binaries\Win64\ue4ss\Mods\HaloSplitscreenCoop

XBOX APP / PC GAME PASS
-----------------------
Use the payload under:
  GamePass-WinGDK\

Copy its Meteorite folder into the game's Content directory so that the mod
ends up under:
  Content\Meteorite\Binaries\WinGDK\ue4ss\Mods\HaloSplitscreenCoop

Read GamePass-WinGDK\README-MANUAL-OFFLINE-WORKAROUND.txt before starting a
Game Pass local-coop session.

PACKAGE TYPES
-------------
Standalone:
  HCE Co-op Expanded files only. A compatible Halo-specific UE4SS installation,
  including UEHelpers, must already be installed.

Complete-UE4SS:
  Includes the tested Halo-specific UE4SS compatibility runtime used by this
  release, plus HCE Co-op Expanded.

DEFAULT INPUT
-------------
The included settings.ini defaults to:

  [Input]
  Controllers=2

Controllers=2 keeps the established two-gamepad behavior.

Controllers=1 is supported:
  P1 = keyboard/mouse
  P2 = first gamepad

Steam Controllers=1 supports native XInput and Steam Input virtual controllers.
Game Pass Controllers=1 supports native Xbox/XInput controllers only.

BASIC LOCAL CO-OP
-----------------
Reach the co-op frontend and use Player 2's normal A/Cross join action.
Ctrl+Y remains a P2 creation fallback.

Frontend P2 leave:
  Hold A / Cross on P2 for about 2 seconds.

CONTROLLER SHORTCUTS
--------------------
Hold RB / R1, then:
  D-pad Left / Right  - previous / next armor
  D-pad Up            - Limited Respawns (host P1)
  D-pad Down          - split orientation
  X / Square          - weapon skin
  B / Circle          - first / third person
  Y / Triangle        - Limited Respawns voice broadcast ON/OFF (host P1)
  L3 / R3             - previous / next vehicle color

KEYBOARD (P1)
-------------
  Ctrl+Y               - create P2 fallback
  Ctrl+U               - remove P2 in frontend
  Ctrl+Left / Right    - armor
  Ctrl+Up              - Limited Respawns
  Ctrl+Down            - split orientation
  Ctrl+X               - weapon skin
  Ctrl+PageUp/PageDown - vehicle color
  Ctrl+B               - Perspective
  Ctrl+F8              - Limited Respawns voice broadcast ON/OFF

CONTROLLER SETTINGS
-------------------
Halo's Controller Settings page is extended by Co-op Expanded in the frontend
and in local-player pause menus. The page title becomes:

  CO-OP EXPANDED CONTROLS

The normal Halo actions remain visible and Co-op Expanded shortcuts are shown
under the corresponding buttons. See CONTROLS.txt for the full layout.

NOTES
-----
- VehicleMessageProtocol remains version 3 for hybrid network + local co-op.
- Game Pass still uses the documented manual-offline mission-start workflow.
- Game Pass Controllers=1 supports native Xbox/XInput only; this is a documented
  limitation in this release.
- The project-owned xinput1_4.dll is part of the tested controller route. Do not
  replace it with another XInput proxy when validating this package.
