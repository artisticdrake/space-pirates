# Space Pirates — Project Story

## What Is It?

Space Pirates is a local multiplayer party brawler where every player uses their **smartphone as a motion controller**. Tilt to steer, hold to brake, tap to fire — no gamepads, no keyboards, just phones. The game runs on a TV or monitor while players crowd around it, phones in hand, trying to blast each other out of the sky.

---

## Inspiration

The idea came from one simple frustration: **local multiplayer is dying because nobody owns controllers anymore**. Everybody has a phone. Why aren't we using them?

Also, we live in a world where technology moves faster than our ability to understand it. Every day, people download software without thinking twice, share data without knowing its value, and trust systems they've never questioned. And the consequences: breaches, manipulation, loss of privacy, all feel abstract until they happen to you.
So we asked ourselves: what if learning about those dangers actually felt exciting?

That's why we built Rogue Space Pirates. It's a space action game where every mission teaches you something real about technology. In one level you're escaping enemy ships after downloading malware from an unverified source, learning about cybersecurity the hard way. In another, you're destroying a cargo ship full of stolen human data, because you understand exactly what that data is being used for. The stakes feel real because the concepts behind them are real.

---

## How I Built It

The project has three components talking to each other in real time:

```
[Godot 4 Game]  ←── WebSocket ──→  [Node.js Server]  ←── HTTPS/Socket.IO ──→  [Phone Browser]
```

### The Game — Godot 4

The game itself is built in **Godot 4** using GDScript. It handles all the gameplay: ship physics, weapons, collisions, game modes, cameras, UI, and split-screen viewports.

Ships use a velocity-based physics model with linear drag — tilt data from the phone translates directly into rotation input, and thrust is always-on with a gradual brake system. There are six ship classes, each with unique stats, a primary weapon, and a special ability:

| Ship | Weapon | Special |
|---|---|---|
| Corsair | Rapid Laser | Speed Burst |
| Dreadnought | Heavy Cannon | Shield Bubble |
| Phantom | Homing Missile | Cloak |
| Scavenger | Spread Shot | Ram Boost |
| Marauder | Beam (hold) | EMP Pulse |
| Specter | Mine Dropper | Teleport Dash |

The game supports five modes:
- **Campaign** — 7 story chapters with Dialogic-powered cutscenes, leading into Swarm, Siege, and PvP encounters
- **Swarm** — escape the pursuing enemy fleet before time runs out
- **Siege** — destroy a 3000 HP mothership guarded by minion waves
- **Race** — first to cross the finish line wins
- **PvP** — free-for-all until one ship remains
- **Bot Battle** — play against an AI opponent

### The Server — Node.js

The server does two things: it serves the phone UI over **HTTPS** (required for gyroscope permission on iOS), and it acts as a relay between the phones and Godot.

Phones connect via **Socket.IO** over HTTPS. Godot connects via a plain **WebSocket** on localhost. The server bridges them — input from every phone is forwarded to Godot at ~60fps using volatile emit to keep latency low.

Slot management is handled server-side. Up to 5 players can connect, each assigned a color and a slot number. If Godot disconnects and reconnects (e.g. during development), the server replays the current lobby state so Godot catches up instantly.

```
Slot 0 → #00f5ff (cyan)
Slot 1 → #ff3f3f (red)
Slot 2 → #39ff14 (green)
Slot 3 → #ff9f00 (orange)
Slot 4 → #cc44ff (purple)
```

### The Controller — Phone Browser

The phone UI is a single HTML file served by the Node.js server. It uses the **DeviceOrientation API** to read gyroscope data. The player calibrates their neutral position at startup — whatever angle they hold the phone becomes the zero point. From there, tilting left/right steers the ship.

The controller layout (landscape orientation):

```
[ REVERSE ]  [ ↑ arrow + SPECIAL ]  [ HOLD TO FIRE ]
```

Thrust is always on. Holding REVERSE gradually decelerates the ship and then pushes it into reverse — implemented as a smooth ramp in the ship physics rather than an instant value change.

### Procedural Audio

Rather than shipping audio files, all sound effects are **generated in GDScript at runtime** using `AudioStreamWAV` with raw 16-bit PCM data:

- **Laser** — 1600→280Hz frequency sweep with a harmonic overtone
- **Hit** — white noise burst blended with a 520Hz tone
- **Explosion** — low rumble (55Hz + 90Hz) mixed with noise, attack envelope

---

## What I Learned

**WebSockets and browser security are tightly coupled.** iOS Safari will not fire `deviceorientation` events on an insecure origin. The entire HTTPS + self-signed certificate setup exists solely because of this requirement. Getting a phone's gyroscope working took more infrastructure than the gyroscope code itself.

**Volatile emit matters.** At 60fps per player, input events pile up fast. Using `socket.volatile.emit` means packets are dropped if the connection is momentarily busy rather than queued — this keeps controls feeling live instead of laggy.

**Split-screen in Godot 4 is a first-class feature** but requires careful viewport management. Each player gets their own `SubViewport` with its own camera. HP bars, ship labels, and enemy indicators are all drawn per-viewport in screen space.

**Smooth input feels dramatically better than raw input.** The original brake was an instant snap to `-1` thrust. Adding a `move_toward` ramp (1.2 units/sec down, 4.0 units/sec up) made it feel like a real vehicle. One line of physics code changed the entire feel of the game.

**Game state machines need to be explicit.** The game has states: `LOBBY`, `CAMPAIGN`, `RACE`, `ESCAPE`, `SIEGE`, `PLAYING`, `PLAYGROUND`, `WIN`. Every major function checks state before doing anything. Without this, mode transitions would constantly bleed into each other.

---

## Challenges

### The SSL Problem
Gyroscope access on iOS requires a secure context. The solution was to auto-generate a self-signed certificate at server startup using `selfsigned`. Players see a browser warning once, tap "Advanced → Proceed," and never see it again. It works but it's not a clean first-time experience.

### Keeping Godot and the Server in Sync
If Godot crashes during development and reconnects, it previously had no idea who was already in the lobby. The fix was to have the server replay all current slot state (joined, ship selected, ready) to Godot the moment a new WebSocket connection opens.

### Split-Screen Audio
`AudioStreamPlayer3D` requires an `AudioListener3D` in the scene. In split-screen, there are multiple viewports and no clear single listener — audio simply didn't play. The fix was to use `AudioStreamPlayer` (non-spatial, 2D flat audio) for all sound effects. It loses positional audio but gains reliability across all configurations.

### Campaign Flow Routing
The campaign is not linear — chapter 1 leads to Swarm, chapter 3 leads to Siege, chapter 6 leads to PvP. This is managed through a `_campaign_pending` string set by Dialogic timeline signals. The skip-cutscene button had to replicate this routing logic manually since the signal hasn't fired yet when the player skips.

### Controller Layout Iteration
The original layout had the gyro tilt controlling both steering and throttle. Players found it confusing — tilting forward to accelerate while also tilting sideways to steer required two simultaneous axes of control. The solution was to make thrust always-on and reduce the controller to a single axis (steering), with an explicit REVERSE button for braking.

---

## What's Next

- Persistent leaderboards for Race mode
- More ship classes and special abilities
- Online play (requires WSS URL change and a cloud-hosted server)
- Sound design pass with real audio assets
- QR code displayed on the lobby screen for instant phone join

---

*Built with Godot 4 · Node.js · Socket.IO · WebSocket · HTML5 DeviceOrientation API*
