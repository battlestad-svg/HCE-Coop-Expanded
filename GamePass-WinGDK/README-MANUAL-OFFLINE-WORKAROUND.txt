HCE CO-OP EXPANDED v1.10.0 - GAME PASS / WINGDK
MANUAL OFFLINE LOCAL-COOP WORKAROUND
===================================================

Local split-screen campaign co-op is supported on Xbox App / PC Game Pass, but
the WinGDK path still uses a manual offline transition before mission start.

INPUT MODES
-----------
Controllers=2 (default):
  Use two controllers through Halo's normal assignment.

Controllers=1:
  P1 = keyboard/mouse
  P2 = first controller
  Native Xbox/XInput only on Game Pass. PlayStation-family and other non-native
  controller paths are a known limitation in this mode.

WORKFLOW
--------
1. Launch the Xbox App / PC Game Pass version while ONLINE.
2. Sign in Player 1 and reach the co-op frontend/lobby.
3. Join local Player 2 and confirm P2 is present in the local fireteam/lobby.
4. BEFORE STARTING/LOADING THE MISSION, Alt+Tab and manually disable the active
   LAN/Wi-Fi adapter so the PC is offline.
5. Return to Halo. If an Xbox/network popup is still visible, close/dismiss it.
   Do not select a second Xbox account for P2.
6. Configure/start the co-op mission while offline and let it load.
7. Re-enable the network adapter only after the mission is visibly loaded and
   the local split-screen session is established.

The exact Xbox popup timing can vary. The tested requirement remains:
  P2 IN THE LOBBY -> GO OFFLINE -> START THE MISSION.

If Player 2 remains black, fully exit Halo and retry from a fresh process.
Restarting only the mission/checkpoint has not been a reliable recovery.

The mod intentionally does NOT disable/re-enable adapters or modify firewall
rules automatically.

CREDIT
------
Game Pass workaround direction / split-screen research: bfixer117 / HCE Revival
Repeatable controller/sign-in sequence testing/documentation: red2k1
