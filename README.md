# Earthworks — test build

Low-poly heavy machinery: dig, haul, doze, shred and demolish — and run the company. Built with Godot 4.7.

## Play
- **Windows:** download `Earthworks-Windows.zip` from the latest **Release** on GitHub, unzip it and
  run `Earthworks.exe` (it isn't signed, so SmartScreen may ask: **More info → Run anyway**).
- From the source: double-click `play.bat`, or open Godot, **Import** this folder and press **F5**.

### Mac (Apple Silicon or Intel)
Download `Earthworks-macOS.zip` from the latest **Release** on GitHub and unzip it. The app isn't
notarized by Apple, so the first time either right-click `Earthworks.app` → **Open**, or run
`xattr -cr Earthworks.app` in Terminal. New Mac and Windows builds are made automatically by
GitHub Actions whenever a version tag (`v0.2.0`, …) is pushed. Macs start on the **Medium** graphics setting.

You spawn on foot in the **construction depot** next to an excavator, a bulldozer and a dump truck.
Walk up to a cab door and press **F** (controller **X**) to climb in.

| | Keyboard | Controller |
|---|---|---|
| Depot screen (hire machines, tools, jobs, fleet) | **Tab** | View |
| Pause menu (controls, graphics, new career) | **Esc** | Menu |
| Get in / out, work trailer ramps | F | X |
| Handbrake (trucks) | Space | A |
| Run (on foot) | Shift | L3 |
| Winch: tap to hook, hold to reel | H | B |
| Swap excavator tool / hitch a trailer | N or T | L3 |
| Cab view | V | R3 |
| Ratchet strap: press at the thing, then at what to tie it to | G | LB |
| Rope (same two presses) | R | RB |
| Cut a strap or rope you're standing by | X | B |
| Minimap: close-up / whole area | M | |

**Mouse-only machine control:** hold a button and push the mouse like a joystick.
Left drag = boom + swing (dozer: blade up/down, truck: bed), right drag = stick + bucket (dozer: blade tilt),
both / middle drag = drive. Scroll all the way in for the cab view. The HUD buttons cover winch, tool,
cab view and climbing out.

## The company
- **Cash** shows top left. Progress (cash, unlocks, stats, graphics setting) is saved automatically.
- **The world is saved too:** every hole, pile, rut and gravel road, felled trees and pulled stumps,
  the logs and stumps lying about, demolition rubble and ground mats. It saves every minute and when
  you quit, and comes back next time. **New career** (pause menu) starts a fresh world. When you
  join someone else's game you play in their world and your own save is left alone.
- **Depot screen (Tab):**
  - **Machines** — unlock a machine once, then deliver as many as you like (up to 14 on site) to the
    numbered bays in the yard. **Tools** — unlock excavator buckets and the grapple.
  - **Jobs** — the job board (three offers). Take one and it's marked in the world (posts, tape and
    a light beam), on the minimap and in the job card: foundation dig, fill delivery, level a pad,
    land clearing, stump removal, demolition, gravel a track, and breakdown recovery (a truck with
    a dead engine in the mud — tow or winch it home).
  - **Tools → Supplies** — **ground mats** ($1,200 for four), delivered by the material bays.
  - **Fleet** — every machine on site: reset one that's tipped over, or return it to the dealer.
- **Five shredders** around the map (the minimap shows them): drag, push, tip or drop logs and
  stumps into the striped infeed zone and they're shredded for cash. Swamp cypress logs pay about
  2.4× and giant oak about 3× an ordinary log ("prized log").

## Multiplayer (up to 4 players)
**Esc → Multiplayer.** One player presses **Host online** and gets a room code like `KX7P-M3QD`
(shown in the pause menu too, with a COPY button); the others type it under **Join with code**.
That's it: no port forwarding, no VPN, nothing to install. Everyone works for the same company:
shared cash, unlocks and jobs (saved on the host's PC). Joining swaps your world for the host's for
the session; your own career is untouched.

- **How it connects:** players find each other through free public MQTT brokers (EMQX, shiftr.io,
  Mosquitto; several at once, so one being down doesn't matter), then connect straight to each other
  over WebRTC (the bundled `addons/webrtc_native` plugin), using Google's and Cloudflare's free STUN
  servers to get through home routers. There's no game server to run.
- **If it can't connect:** a few strict networks (some phone hotspots and carrier-grade NAT) block
  direct links. Then use **Host or join by IP address**: the host forwards UDP 24680 on their router
  (or everyone uses the same Wi-Fi), and friends join with the host's address and a password.
- **Security:** traffic is encrypted either way (WebRTC's DTLS, or ENet with DTLS and a fresh key
  every time you host). The room code (or password) is checked by HMAC challenge-response in both
  directions, so it never crosses the network and a fake host can't impersonate yours; only a hash
  of the code is posted to the brokers. Players can't message each other directly; everything they
  send is type-checked and rate-limited; the host decides everything.
- The host runs the simulation; other players' machines, logs and rubble follow it (20 updates a
  second), and your controls are sent to the host for the machine you're in. Each player's water
  is simulated on their own PC.
- Joining a well-worked world (yours, from your save) is quick: the ground is sent as just the
  difference from untouched ground, in small batches each confirmed by the joining player, on its
  own channel so it never holds up anything else; far-off changes are put in when that ground loads.
- Windows/macOS may ask to allow the game through the firewall the first time you host.

## The world (1 km × 1 km)
- **Construction depot** in the middle: fenced yard with a wide 28 m gate under the company gantry, a
  wide haul road out, delivery bays, dispatch board, workshop, offices, fuel station, material bays
  (one of them gravel), container yard, wash bay, light towers. **The yard and the haul road can't be
  dug up**, so the way out can never be cut off (spoil dumped on them can still be pushed off).
- Borrow mound to dig just north of the yard; demolition yard (warehouse, block, tower, wall) to the west.
- **The Great Swamp** (south-west, ~300 m across) and a second swamp in the north-east: deep mud,
  standing pools and swamp cypress forests.
- **Gravel quarry** in the south-east: benches of gravel to dig and haul. An abandoned **farm** to
  demolish near it.
- **Snowy pine forest** in the east: snow on the ground and on the trees (the broadleaves stand
  bare for winter), falling snow, and a **frozen pond** of slippery ice (wheels lose their grip,
  tracks slide). Dig or drive the snow to mud and the soil shows through.
- Big hills, three lakes, a river across the whole map plus a western river and streams, mud pits
  everywhere, and 21 forests (about 2,900 trees: pines, broadleaves, swamp cypress, giant oaks) with a
  dense tree line round the edge. Water has momentum, and near you it runs every frame: it floods channels you dig, fills holes,
  runs downhill, surges into new channels, and
  the surface flows visibly downstream (white water where it's fast).
- Felled trees shed their leaves as they fall and come down as bare, heavy logs (a big oak weighs
  tonnes), so they lie where they land instead of bouncing away.
- **Ore in the ground**: dig below the topsoil and chunks of ore turn up in the hole now and then:
  iron and copper (common, rich round the quarry), silver (the hills), gold (along the rivers and
  the big hills, a metre or more down) and emeralds (rare, deep, in the hills and the snowfield).
  Boulders lie about the map, some flecked with ore hinting at what's under them. Take ore and
  boulders to the **ore crusher** on the quarry floor (grapple, truck or dozer) to sell them.
- Hit a tree with a machine and it falls, leaving a stump that blocks machines until you dig around
  its roots (about 0.4 m down) to break it free, or shove on into it with a dozer or excavator and
  tear it out. Felled trees and stumps are remembered across the map.

### Mud, sinking, gravel and mats
- Heavy machines **sink into mud**. A truck's wheels sink by the load on each wheel: an empty pickup
  barely notices, a loaded dump truck parked in the swamp sinks ~0.7 m within 20 seconds, loses most
  of its drive and needs a winch or tow (tipping the load out helps a little). Excavators and dozers
  standing in mud settle in too and can then only crawl; driving keeps them up.
- **Gravel** is firm ground: nothing sinks on it. Dig it at the quarry or the depot's gravel bay
  (the bucket and HUD say GRAVEL), haul it, dump it on mud and spread it with a dozer to build roads.
- **Ground mats**: heavy timber crane mats. Lay them on mud with the grapple (they bed in once they
  settle) and drive across: no wheel or track sinks on a mat. Lift them out with the grapple or winch.

## Machines
- **Excavator** (your model, scaled up 1.4×): soil pushes back on the bucket; the soil heap fits the
  bucket; dump over a truck body to load it. Tools: 3.5 m³ bucket, 6.5 m³ bulk bucket, 1.5 m³ trench
  bucket, tree grapple (fells trees, pulls stumps, lifts logs).
- **Mining excavator**: the same machine at twice the size — a ~10 m³ bucket, huge reach, slower arm.
  The **grapple** grips logs anywhere along the trunk and settles them centred across its jaws;
  close it on a pile and it takes up to four logs at once in a bundle.
- **Big bulldozer** (18 m³ U-blade), **Big angle dozer** (14 m³) and the **Carry dozer**: a giant
  high-wall blade that shoves ~51 m³ forward at a time.
- **Bulldozer** (U-blade) and **Angle dozer**, both big-class machines. Each grades a flat cut a set
  depth below the natural ground. The U-blade's forward-turned wings carry everything straight ahead
  (~9 m³; what won't fit piles up in front and gets pushed along). The angle blade swings ±29° with
  the swing controls and rolls its load off the trailing end into a windrow beside the pass. Both
  have a rear ripper. The tracks are rigid: they bridge dips, rock forward over crests, drop off
  ledges under gravity, slide on very steep slopes, and shove trucks they drive into.
- **Dump truck** (8 m³), **Articulated hauler** (14 m³, 6x6, big tyres, good in mud),
  **Log truck** (tipping log bed with stakes — logs ride on it and slide off when it tips),
  **Heavy haul tractor** (for the lowboy), **Recovery truck** (6x6, 35 m boom winch),
  **Heavy recovery truck** (8x8 rotator wrecker, 450 kN winch, 60 m cable),
  **Site pickup** (fast 4x4). All have real wheel physics, a load that raises mass and centre of
  gravity, a handbrake, and mud that sinks the wheels.
- **Portable shredder** ($22,000): a tracked shredder you drive to where the trees are coming down.
  Drop, drag or push logs and stumps into the striped infeed at its back; they're shredded and
  paid for on the spot.
- **Dozer grinder:** in any bulldozer press the tool button (N) to swing a grinder drum onto the
  front of the blade. Drive into standing trees, stumps, logs and loose stumps and they're ground
  up and paid for instantly. Raise the blade a little to drive freely.
- **Wide flatbed trailer** ($16,000): a 14 m × 4.2 m deck on five axles with full-width ramps, for
  the big dozers and the mining excavator. Hitch it to the heavy haul tractor; raise the ramps to
  strap the load down.
- **Ore:** ore dug up by the excavator lands in its bucket (you can see the rocks), pours into a
  dump truck with the soil and slides out of the tailgate when you tip it; tip it into the ore
  crusher at the quarry to sell it. Ore a dozer blade cuts out rolls ahead of the blade to be
  pushed along.
- **Clean up site** (pause menu): clears loose stumps, ore and boulders off the whole map to keep
  the frame rate up. Anything strapped, tied, held or in a machine stays.
- **Roller** ($16,000): grades ground flat to a level you set. Raise or lower the level with the
  boom keys (I / K), or press stick out (L) to set it to the ground under the drum; then press
  the tool button (N) to switch levelling on. Wherever the drum rolls (or sits), high ground is
  cut and low ground filled to that level, and rolled firm so nothing ruts it. The HUD shows the
  level and how far the ground under the drum is above or below it.
- **Tracked conveyor**: tip soil or gravel into its hopper (excavator bucket or a dump truck backed
  up to it) and the belt carries it up and drops it off the head as a growing pile, or into a truck
  parked under the head. Drive it on its tracks, raise/lower the boom (boom controls) and fold/unfold
  its three sections (stick in / out): 9 m folded for driving, a 28 m reach unfolded. The belt only
  runs fully unfolded.
- **Logging semi**: a huge, stable rig (1.4x scale, five axles on a wide stance, low centre of
  gravity) with a 10.6 m x 4.1 m bed of tall-staked tipping bunks; walk to the back and press F to
  strap the load down (logs ride locked to the bed, even as it tips) or release it. The log truck
  straps the same way. **Log trailers** (bunks and tall stakes; the button at the back straps the
  load down). Trailers chain: back the last trailer's tail up to
  another trailer's drawbar and press the hitch button to add it to the train; with nothing behind,
  the hitch button drops the last one.
- **Ratchet straps and rope** (on foot): a strap locks a log, stump, mat or block onto a truck,
  trailer, machine or tree so it rides rigidly; a rope is a line with a little slack that pulls
  when it goes tight (drag a log behind a truck). Cut either with X / B.
- **Lowboy trailer**: hitch to any truck; walk to the back and press F / X to raise or lower the
  hydraulic ramps; tracked machines drive up and ride on the deck. Raise the ramps and everything on
  the deck (machines, trucks, logs, mats) is strapped down and rides locked to it; lower them to
  unload.

## Feel
- Physics interpolation is on, so movement is smooth at any frame rate; the camera follows the
  smoothed positions. The worker eases in and out of walking, runs, leans into the stride, and has
  a full walk/run cycle with knees and elbows (other players' workers animate the same way).

## Performance
- The 1 km map is generated in 8 m blocks as you approach; nearby ground is drawn in detail, the rest
  as a low-detail horizon; physics ground exists only around players, machines and loose objects;
  trees far away are instanced meshes and turn into real trees as you get close.
- Models are merged per moving part into one mesh with a shared material (colour, roughness and
  metalness baked into the vertices), so a whole machine, the worker or the depot draws in a few
  calls; nearby trees are real physics trees but drawn with the batched forest meshes.
- The water simulation only visits the wet part of each tile, and only rebuilds water surfaces the
  camera can see, nearest first (bit-for-bit the same result as visiting everything).
- Terrain chunks have distance LODs (with skirts so seams never gap), grass thins out with distance,
  the depot and every vehicle are batched into a few meshes per material, the distant tree ring is
  tiled for culling, and the water simulation runs a few tiles every frame instead of in bursts.
- **Graphics** setting in the pause menu: Low (no SSAO, short shadows, sparse grass, upscaled),
  Medium, High.

## Code map
| File | Purpose |
|---|---|
| `scripts/main.gd` | World layout, fleet spawning, economy wiring, enter/exit, `--autotest` |
| `scripts/net.gd` | Multiplayer: hosting/joining, encryption and password handshake, world sync |
| `scripts/career.gd` | Cash, unlocks, catalogue of machines and tools, save file |
| `scripts/jobs.gd` | Job board, job markers and progress |
| `scripts/shredder.gd` | Wood shredder |
| `scripts/terrain.gd` | Heightmap, dig/deposit, slumping, channels, mud, protected ground, LOD chunks |
| `scripts/water.gd` | Tiled shallow-water flow with momentum, sleeping tiles, river heads, flow-map shader |
| `scripts/excavator.gd` / `excavator_model.gd` | Excavator and the rig for `models/excavator.glb` |
| `scripts/bulldozer.gd` | Bulldozer |
| `scripts/truck.gd` | All the wheeled trucks (one script, several kinds) |
| `scripts/trailer.gd` | Lowboy trailer with hydraulic ramps |
| `scripts/model_kit.gd` | Shared modelling helpers (rounded boxes, prisms, wheels, materials) and mesh batching |
| `scripts/hud.gd` / `minimap.gd` / `menu.gd` | HUD, minimap, depot and pause menus |
| `scripts/winch.gd` | Winch and cable |
| `scripts/tree.gd` | Destructible tree / stump |
| `scripts/forests.gd` | Every tree on the map: species, felled/stump state, streaming live trees in and out |
| `scripts/scenery.gd` | Tree meshes, the depot, the quarry |
| `scripts/grass.gd` | Grass streamed around the camera |
| `scripts/machine_fx.gd` | Exhaust, dust, mud spray, track meshes |
| `scripts/player.gd` | Worker on foot / seated operator |
| `scripts/buildings.gd` | Destructible block buildings |
| `scripts/mouse_controls.gd` / `input_setup.gd` | Mouse joystick and keyboard/controller bindings |
| `scripts/follow_camera.gd` | Camera |
| `tools/*.gd` | Dev checks and model tools |

## Automated checks
```
Godot_v4.7.2-stable_win64_console.exe --headless --path . -- --autotest
Godot_v4.7.2-stable_win64_console.exe --headless --path . -s tools/feature_check.gd
Godot_v4.7.2-stable_win64_console.exe --headless --path . -s tools/gameplay_check.gd
```
The autotest digs and loads a truck, dozes, drives a loaded truck into mud. `feature_check` covers
mud ruts, the recovery winch, trailer towing and the grapple; `gameplay_check` covers delivering
every machine, the shredder, jobs, the protected depot, the log truck, dozer gravity and pushing;
`machines_check` covers both dozer blades, the grapple's grip and the mining excavator;
`bigmap_check` covers sinking in the swamp, ground mats, quarry gravel, prized logs and stumps
streaming back in. `trees_check` fells every species and buries logs under dumped soil to check nothing
ever ends up under the ground.
`semi_check` loads the logging semi with 13 t of logs, straps them with F and drives hard;
`logging_check` pulls two chained log trailers with a strapped load behind the logging semi;
`ties_check` straps a log onto a truck with the keys, drags one on a rope and straps one to a tree.
`ore_check` digs pits in three places and sells the best find at the crusher; `water_check`
times the river filling a trench dug from it to a pit. `conveyor_check` tips a truck into the conveyor, piles the load off the head, folds, raises,
drives, and loads a truck under the head. `ground_check` makes sure the worker never ends up under the ground; `trailer_check` tows logs and
a dozer strapped to the lowboy through a hard turn and stop. `save_check` digs, gravels, fells, pulls a stump, moves rubble and lays mats, saves, rebuilds the
world and checks it all comes back. Checks never touch your save. `tools/net_check.gd` runs a host
and players as separate processes on this PC (`-- --role=host`, then `-- --role=client`;
`--role=idleclient` adds another player, `--role=badclient` tries a wrong password, and
`-- --role=host --bigdig` digs holes all over the map first, like a long-played save).

## Credits
- Excavator model: ["Excavator"](https://sketchfab.com/3d-models/excavator-c00f6295235349e3b60885a9efa45629)
  by [MD.Jobair Hossain](https://sketchfab.com/samrat33k), licensed
  [CC-BY-4.0](http://creativecommons.org/licenses/by/4.0/). Split into rig parts in code; mesh unchanged.
