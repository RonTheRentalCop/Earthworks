# Earthworks — test build

Low-poly heavy machinery: dig, haul, doze and demolish. Built with Godot 4.7.

## Play
- Double-click `play.bat`, or
- Open Godot, **Import** this folder, press **F5**.

### Mac (Apple Silicon or Intel)
Download `Earthworks-macOS.zip` from the latest **Release** on GitHub and unzip it. The app isn't
notarized by Apple, so the first time either right-click `Earthworks.app` → **Open**, or run
`xattr -cr Earthworks.app` in Terminal. New Mac builds are made automatically by GitHub Actions
whenever a version tag (`v0.2.0`, …) is pushed.

You spawn on foot in the **construction depot** (south side of the map) next to three machines parked in their bays.
Walk up to a cab door and press **F** (controller **X**) to climb in. F1 / Y toggles the controls panel.

**Mouse-only machine control:** hold a button and push the mouse like a joystick.
Left drag = boom + swing (dozer: blade up/down, truck: bed), right drag = stick + bucket (dozer: blade tilt),
both / middle drag = drive. Scroll all the way in for the cab view. Keyboard and controller work too,
and controllers rumble while digging, pushing or stuck.

## The world (288 m × 288 m)
- Construction depot: fenced gravel yard with gate, security booth and raised barrier, weighbridge,
  workshop shed (benches, tool boards, drums, engine hoist), two-storey site office and lunch room,
  fuel station with canopy, concrete-block material bays (gravel / sand / topsoil), container yard,
  wash bay, painted parking bays, parked pickups and roller, scaffolding, light towers, a practice heap
- Borrow mound to dig just north of the yard; demolition site (houses, tower, wall) to the west
- River down the east side, a lake to the north-west fed by a stream, and an outlet stream to the river
- Mud along the banks, around the lake and in pits near the yard — trucks bog down, especially loaded
- Six forests of destructible trees: hit one with a machine and it falls, leaving a stump that blocks
  machines until you dig around its roots (about 0.4 m down) to break it free
- Dense swaying grass that disappears where you dig

## Machines
- **Excavator** (your model, scaled up 1.4× to a big-class machine, 3.5 m³ bucket): soil pushes back on the bucket; the soil heap is lofted through slices of
  the bucket's real cavity so it fits the scoop; dump over the truck bed to load it
- **Bulldozer**: grades a flat cut a set depth below the natural ground (lower the blade to go
  deeper); up to 3.5 m³ rolls in front of the blade, and only an overloaded blade spills round its
  ends (mostly off the low end when tilted). Lift the blade or reverse to drop the load as a pile. Blade tilt
  (swing controls) for angled cuts; rear ripper (stick controls) tears furrows and loosens stumps.
  Heavy handling: slow to accelerate, slower uphill. Tracks leave ruts. It shoves logs, stumps, barriers and stuck trucks (`tools/doze_check.gd` tests a push)
- **Dump truck**: real wheel physics, 40 km/h top speed (32 km/h loaded) with gearing-style power,
  speed-sensitive steering, 8 m³ bed with a heap that fits the bed, tipping bed to dump,
  gets stuck in mud (wheels sink, grip drops, worse with a load)

- **Recovery truck**: heavy 6x6 wrecker with mud tyres, a 35 m boom winch (220 kN) and a tow hitch
- **Lowboy trailer**: hitch to either truck (T / L3 with the hitch at its drawbar); tracked machines
  can drive up the ramps and ride along. Walk to the back of the trailer and press **F / X** to
  raise or lower the hydraulic ramps (raised, they stand up like a tailgate for the road)

## Recovery, winches and tools
- Every vehicle has a winch: tap **H / B** to hook the nearest vehicle, trailer, log, stump, prop or a
  standing tree (as an anchor); hold to reel in; tap again to unhook. A winched truck drops into
  neutral, and a steady pull breaks the mud's suction.
- Excavator tools (**N / L3**): standard bucket, big 6.5 m³ bucket, 1.5 m³ trench bucket, and a tree
  grapple (curl closes, dump opens) that lifts logs/props, pulls standing trees over and tears out stumps.
- Soft mud gives way under tracks and tyres on every pass; spinning wheels and slipping tracks dig in.
- First person in every vehicle (V / scroll in); look around with Alt + mouse, Z/C and -/=, or the D-pad.

## Code map
| File | Purpose |
|---|---|
| `scripts/main.gd` | World layout, machines, enter/exit, rumble, `--autotest` |
| `scripts/terrain.gd` | Heightmap, dig/deposit, slumping, channels, mud, gravel, tiled collision |
| `scripts/water.gd` | Tiled shallow-water flow with sleeping tiles, river heads, mud wetting |
| `scripts/excavator.gd` / `excavator_model.gd` | Excavator and the rig for `models/excavator.glb` |
| `scripts/bulldozer.gd` | Bulldozer |
| `scripts/truck.gd` | Dump truck and recovery truck |
| `scripts/trailer.gd` | Lowboy trailer with hydraulic ramps |
| `scripts/model_kit.gd` | Shared modelling helpers (rounded boxes, prisms, wheels, paint/glass/hazard materials) used by the built-in vehicle and worker models |
| `scripts/winch.gd` | Winch and cable |
| `scripts/tree.gd` | Destructible tree / stump |
| `scripts/scenery.gd` | Tree meshes, forests, loading-zone props |
| `scripts/grass.gd` | Grass streamed around the camera |
| `scripts/machine_fx.gd` | Exhaust, dust, mud spray, track meshes |
| `scripts/player.gd` | Worker on foot / seated operator |
| `scripts/buildings.gd` | Destructible block buildings |
| `scripts/mouse_controls.gd` / `input_setup.gd` | Mouse joystick and keyboard/controller bindings |
| `scripts/follow_camera.gd` / `hud.gd` | Camera and UI |
| `tools/*.gd` | Dev tools: model inspection, `doze_check.gd`, `feature_check.gd` (winch/trailer/grapple) |

## Automated check
```
Godot_v4.7.2-stable_win64_console.exe --headless --path . -- --autotest
```
Digs and loads the truck, dozes into a forest, drives a loaded truck into mud, walks — printing stats.

## Credits
- Excavator model: ["Excavator"](https://sketchfab.com/3d-models/excavator-c00f6295235349e3b60885a9efa45629)
  by [MD.Jobair Hossain](https://sketchfab.com/samrat33k), licensed
  [CC-BY-4.0](http://creativecommons.org/licenses/by/4.0/). Split into rig parts in code; mesh unchanged.
