# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

크레이지 버블: a Crazy Arcade–style water-balloon game in **Godot 4.3 (GDScript, GL Compatibility renderer)**. Real-time multiplayer runs over **Supabase Realtime** (project `ootd-store`, ref `bxtfhadwhteljgzmuecy`). A player alone in a room plays against AI bots, and up to 4 people share a room by code or invite link (`?room=CODE`). It is deployed on Vercel (team `tw-32d1`, project `jjab-crazyarcade`) at https://jjab-crazyarcade.vercel.app from GitHub `cau024-droid/261020ai2`, and every push to `main` redeploys automatically. UI text is Korean.

## Commands

There is no global Godot install. A Windows editor is kept in `.tools/` (gitignored), and the commands below run from the repo root in Git Bash.

```bash
# Import / surface parse errors
./.tools/Godot_v4.3-stable_win64_console.exe --headless --path . --import

# Run the game headless for ~120 frames (catches runtime script errors)
./.tools/Godot_v4.3-stable_win64_console.exe --headless --path . --quit-after 120

# Simulation test: bot rounds + snapshot JSON round-trip + movement/bomb checks
./.tools/Godot_v4.3-stable_win64_console.exe --headless --path . res://tests/sim_test.tscn

# Render screenshots of menu/room/game to .tools/shot_*.png (opens a real window)
./.tools/Godot_v4.3-stable_win64_console.exe --path . --rendering-driver opengl3 res://tests/shot.tscn
```

- Tests must be run as **scenes**, not with `--script`, because autoloads like `Net` are not visible to `--script` SceneTree scripts. That causes "Identifier not found: Net" and a hang.
- Tests that call `host_start()` must set `Net.room` first; otherwise `member_ids()` is empty and only bots spawn.
- Local Windows has no real Python (`python` is the Store stub); `build.sh`'s python3/unzip extraction only runs on Vercel.
- If `.tools/` is missing, download `Godot_v4.3-stable_win64.exe.zip` from the godotengine/godot GitHub release into `.tools/` (it contains a `.gdignore`).
- The web build only runs on Vercel through `build.sh`, which uses `vercel.json` (`buildCommand: bash build.sh`, `outputDirectory: build`). The script downloads the Linux Godot binary, the ~1GB export templates (it extracts only `web_nothreads_release.zip`) and `NotoSansKR-Bold.otf` into `fonts/`. It then runs `--import` and `--export-release "Web" build/index.html`.
- The export uses the **no-threads** web variant, so no COOP/COEP headers are needed.
- `build.sh` must keep LF line endings, which `.gitattributes` enforces.

## Architecture

There are three scripts. `main.tscn` only attaches `scripts/main.gd`, and every node is built in code.

- **`scripts/net.gd`** (autoload `Net`) hand-implements the Phoenix channel protocol over `WebSocketPeer`. It has no Supabase SDK.
  - It connects to `wss://<ref>.supabase.co/realtime/v1/websocket?apikey=<anon>&vsn=1.0.0` and joins the topic `realtime:crazy-bubble-<ROOM>`.
  - It tracks presence `{id, name, t}`, sends a heartbeat every 25s and auto-rejoins after a disconnect.
  - `send(event, payload)` broadcasts with `self:false` and stamps `payload._from`.
  - **The host is the member with the earliest `t` (join time)**, computed identically by every client through `member_ids()`, `host_id()` and `is_host()`. When the host leaves, host migration happens through this same function.
  - `presence_diff` can arrive before `presence_state`; both paths set `in_room`, keep it that way.
  - The anon key is public on purpose.
- **`scripts/game.gd`** (a Node2D created by main) holds all game state and drawing.
  - It is **host-authoritative with client-owned movement**:
    - The host runs `sim()`: bombs, chain explosions, flames, items, trap/pop, bots and the end-of-round check. It broadcasts a full snapshot `state` every 0.1s while playing and every 0.5s otherwise.
    - Each client moves its own player locally (`move_player`, with corner assist), broadcasts `pos` at about 10Hz and asks the host to place a balloon with `bomb`. The host validates the request in `place_bomb`.
  - `apply_snapshot` ignores snapshots whose `_from` is not the current host. It never overwrites the local player's position except on a new `round_id`. For remote humans it prefers a recent `pos` message over the snapshot.
  - The snapshot format is compact arrays: the map is a digit string and player fields are positional (`[name, color, x, y, alive, trap, mb, rg, sp, bot, dirx, diry, kills]`). Changing a field means updating `make_snapshot`, `apply_snapshot` and `tests/sim_test.gd` together.
  - Positions are floats in tile units, with a tile's center at `n + 0.5`. Tile codes are 0 empty, 1 wall, 2 crate and 3–5 items.
  - A destroyed crate's item is stored on its `Flame` and appears only when the flame expires.
  - Bots are BFS on a danger map. A bot escapes if it stands in a blast tile, places a balloon only if an escape path exists, and otherwise walks to items, trapped rivals or useful bomb spots.
- **`scripts/main.gd`** builds the menu and room UI and routes `Net.broadcast_received` events to the game. The events are `state`, `pos` and `bomb`.
  - It loads the Korean font from `res://fonts/` if present. Web builds have no system-font fallback, so the font is required for the web.
  - It reads `?room=` through `JavaScriptBridge` when running on the web.
  - The phase (`lobby` / `playing` / `over`) comes from the game, and `over` returns to `lobby` after `OVER_TIME`.

## Verifying the deployed site

- Browser-pane viewport emulation makes screenshots of the Godot canvas look shrunk; check `canvas.getBoundingClientRect()` or use the default size.
- Two tabs can't test multiplayer (the background tab's game loop stops). Instead, open a raw `WebSocket` probe from the page via JS (join the room topic, count `broadcast`/`state` events).

## Gotchas

- GDScript 4.3 rejects `:=` when the value is Variant-typed, for example a Dictionary lookup or an untyped call result. Use an explicit type (`var x: int = ...`) in those cases.
- Hidden browser tabs stop Godot's main loop. A backgrounded host freezes the game for everyone.
- Supabase free-tier Realtime limits messages per second. Keep broadcast rates low when adding traffic.
- `docs/CONVERSATION.md` is a Korean log of how the project was built.
