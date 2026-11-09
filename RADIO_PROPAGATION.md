<!--
SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers

SPDX-License-Identifier: MPL-2.0
-->

# Radio propagation for wireless modems

This fork makes wireless modems behave like radios: signals fade with distance, are blocked or attenuated by terrain
and blocks, diffract over hills, and depend on how high an antenna is. This document covers:

1. [How the original BetterWireless implementation worked, and why it was slow](#1-the-original-implementation)
2. [The new propagation model](#2-the-propagation-model)
3. [How it is made fast enough to run on a server](#3-performance-architecture)
4. [Where terrain data comes from, including Distant Horizons and Tellus](#4-terrain-data-for-unloaded-chunks)
5. [Lua-facing changes and configuration](#5-lua-and-configuration)
6. [Limitations and future work](#6-limitations-and-future-work)

## Branches

| Branch | Contents |
|---|---|
| `mc-1.21.x` | The original BetterWireless fork, on CC: Tweaked 1.115.1 / Minecraft 1.21.1. |
| `mc-26.3-betterwireless` | Faithful port of those changes to upstream `v26.3-1.121.0` (Minecraft 26.3), with only the fixes needed to compile. |
| `mc-26.3-radio-propagation` | The redesign described here, on top of the port. |

The pocket computer "always attach a modem to the top" hack was dropped in the port: 26.3 has native top and back
pocket upgrade slots.

### Behaviour changes compared to the 1.21 fork

Some of these deliberately reverse choices in the original fork, so are worth checking:

- **Ender modems behave as upstream again.** The fork changed `||` to `&&`, so normal and ender modems could no
  longer talk. Ender modems now hear (and are heard by) everything, without any propagation simulation.
- **Messages arrive at the next server tick**, rather than during the `transmit` call.
- **`modem_range` is only used when propagation is disabled**, with upstream's default of 64 (and the high-altitude
  options are back). The fork's 1024 now lives in `peripheral.radio.reference_range`, and means something more
  specific: the range of two ground-level modems over flat, open ground.
- **Wired modems don't get the extra `modem_message` argument.** Only messages received by radio do.
- **The signal strength argument is in dBm**, rather than "remaining range in blocks".
- **Channels above 1023 have a shorter range for physical reasons** (a higher frequency), rather than a fixed ÷8.

## 1. The original implementation

For every receiver in range, `WirelessNetwork.tryTransmit`:

1. Drew a Bresenham line from sender to receiver and collected every block position on it.
2. For each block (in a `parallelStream`), looked up the block state and added
   `sqrt(explosionResistance) × 10 × diagonalCompensation` "blocks of range" to a degradation total.
3. Delivered the message if `distance + degradation ≤ range`, reporting `range - degradation` as signal strength.
4. Cached the result per sender peripheral, keyed by sender and receiver block position, for 2400 ticks of day time.

### Why it was slow

`modem.transmit` is not a main-thread method, so all of this runs on the **computer thread**. In Minecraft (verified
against the 26.3 bytecode), `ServerChunkCache.getChunk` does this when called off the server thread:

```java
if (Thread.currentThread() != this.mainThread) {
    return CompletableFuture.supplyAsync(() -> this.getChunk(x, z, status, load), this.mainThreadProcessor).join();
}
```

So **every single `getBlockState` call was a blocking round trip to the server thread**, which only processes those
tasks between ticks. And because `Level.getBlockState` asks for chunks with `load = true`, every unloaded chunk on the
line was **loaded from disk, or generated from scratch**. With Tellus, generating a chunk may mean downloading
elevation data. One message could stall for seconds, and since all computers share the computer thread(s), every
computer on the server stalled with it.

This also explains the "threaded shotgun approach … for some reason this actually works" commit: firing all the block
lookups from a `parallelStream` submits hundreds of tasks at once, which the server thread then drains in a single
batch, rather than paying one tick of latency per block.

### Other problems found while porting

- The Bresenham buffer was a `static` `ArrayList` shared by all transmissions, so concurrent transmits (more than one
  computer thread, or a pocket computer and a turtle sending at once) raced on it.
- `(ModemPeripheral) receiver` and `(WirelessModemPeripheral) sender` casts throw `ClassCastException` for any other
  mod's `PacketSender`/`PacketReceiver` (both are public API).
- `||` became `&&` in the interdimensional checks, so normal modems could no longer talk to ender modems. Worse, an
  ender receiver has a range of `Integer.MAX_VALUE`, so a normal modem transmitting near one would ray-march to it
  across the whole world.
- The cache lived on the sender and was keyed by direction, so the reply to a message (rednet, GPS) never hit it. It
  expired by day time, which stops (`doDaylightCycle false`) or jumps (`/time set`, Tellus real-time sync).
- When the 500ms timeout fired, the extrapolation divided by the block count twice.
- Explosion resistance is a poor proxy for radio opacity: water (100) was far worse than stone (6), and obsidian
  (1200) was nearly opaque while iron blocks (6) were barely noticed.
- The extra `modem_message` argument was also added to wired modems, which breaks upstream's `Transmits_messages`
  game test.

## 2. The propagation model

The model computes a **link budget** in dB, as radio engineers do. A message is received if the path loss is less than
the budget (transmit power + antenna gains − receiver sensitivity). The receiver is told the received signal strength
in dBm.

Rather than configure the budget directly, it is derived from `reference_range`: the distance at which two modems
sitting on flat, open ground can just hear each other (1024 blocks by default). Everything else follows from the
physics: raising a modem extends its range, while hills and walls shrink it.

### Path loss

**Base loss** from distance alone uses the **two-ray ground reflection** model: free-space loss
(`20log d + 20log f − 27.55`) up to the crossover distance `4π·h₁·h₂/λ`, and `40log d − 20log(h₁h₂)` beyond it. Near
the ground, the reflected ray cancels the direct one, so loss grows with the fourth power of distance. Antenna heights
are measured above the *average terrain along the path*, so a modem on a mountain overlooking a valley does well,
while one at the bottom does not. This replaces upstream's "range increases above y=96" rule with the real reason it
exists.

On top of that, the signal takes the better of two paths:

- **Through**: straight through whatever is in the way. Within `block_radius` (64) blocks of each antenna we walk the
  actual blocks with an exact voxel traversal (Amanatides & Woo, not Bresenham, so no voxels are skipped and no
  diagonal correction is needed) and sum each block's attenuation × path length × fill fraction. Further away we only
  have heightmaps, so the ray is classified as underground (rock), in vegetation (between the ground and surface
  heightmaps), or in the open.
- **Over**: escape any enclosure around each antenna (walls, a forest canopy, a cave), then **diffract over the terrain
  profile** between them. Diffraction uses Deygout's method with the ITU-R P.526 knife-edge approximation
  `J(ν) = 6.9 + 20log(√((ν−0.1)²+1) + ν − 0.1)`, recursing one level either side of the main edge. If the straight
  ray from an antenna stays underground, we try escaping straight up instead, so a modem three blocks under the floor
  of a bunker gets through the ceiling and diffracts from the surface.

Taking the better path means a wooden shed between two modems costs a few dB (through it), a mountain costs the
diffraction loss over its top (not the sum of every stone block inside it, which the old model did), and a deep cave
is cut off.

Optionally, the terrain profile is bent by the earth's curvature (`earth_radius`, with the standard 4/3 effective
radius factor for atmospheric refraction). This matters for Tellus at 1:1 scale, where the bulge is 1.5m at the
middle of a 10km link and 36m over 50km.

### Bands

Channels are split into two bands:

| Channels | Default frequency | Budget | Flat-ground range (2m antennas) |
|---|---|---|---|
| 0–1023, 65533–65535 (rednet, GPS) | 150MHz (VHF) | from `reference_range` | 1024 blocks |
| 1024–65532 | 2400MHz (UHF) | 20dB less | ~260 blocks |

Higher frequencies lose more in free space, diffract worse (ν grows with √f) and are attenuated far more by
materials, so the high band is a short-range, line-of-sight band, as in the original fork's design.

Some numbers with the defaults: two VHF modems on 30m towers reach ~15km over flat ground; one tower and one
ground-level modem reach ~4km. A 40-block ridge halfway along a 1km link costs ~34dB on VHF and ~55dB on UHF.

### Materials

There is no "material" on blocks any more, so blocks are classified by sound type (a good proxy for what a block is
made of), a few tags (leaves, ice, dirt, sand) and fluids. Partial blocks attenuate in proportion to their collision
volume; blocks with no collision count as 10% full.

Attenuation per material is frequency dependent. Most use the ITU-R P.2040 model (`ε' = a·fᵇ`, `σ = c·fᵈ`), water uses
a Debye relaxation model and vegetation an empirical fit in the spirit of ITU-R P.833:

| Material (examples) | dB/m @ 150MHz | dB/m @ 2.4GHz |
|---|---|---|
| Rock (stone, deepslate, concrete, ores, unknown solid blocks) | 7.4 | 65 |
| Brick (bricks, tiles, packed mud) | 4.5 | 39 |
| Wood (planks, logs, bookshelves) | 0.7 | 14 |
| Glass | 0.2 | 7.6 |
| Fabric (wool, carpet) | 0.2 | 3.8 |
| Dry ground (sand) | 0.2 | 1.3 |
| Ground (dirt, gravel, grass blocks) | 0.6 | 64 |
| Wet ground (mud, lava) | 2.6 | 166 |
| Water | 10 | 265 |
| Ice / snow | 0.01–0.02 | 0.2–0.3 |
| Vegetation (leaves, plants) | 0.08 | 0.42 |
| Metal | opaque | opaque |

These are physically based (a 1m block of stone really does block Wi-Fi), so `material_loss_scale` is there for
servers which want something more forgiving.

### Weather

Rain barely affects VHF/UHF in reality (it matters above ~10GHz). Thunderstorms do raise the noise floor from
lightning, which is modelled as `storm_noise` (6dB, roughly halving range) added to the receiver threshold.

## 3. Performance architecture

The rule is: **nothing reads the world off the server thread, and nothing ever loads a chunk.**

1. `WirelessNetwork.transmitSameDimension` (on the computer thread) only filters receivers: same level, listening on
   the channel, and not ruled out by free-space loss alone (which is a lower bound on any real path loss). It queues
   the packet and returns immediately.
2. At the start of each server tick, `RadioPropagationService` evaluates queued links on the server thread, reading
   loaded chunks directly through `getChunkNow` and chunk sections (no cross-thread hops, no loading). Work is capped
   at `tick_budget` (2ms) per tick; leftovers wait for the next tick. Each evaluation is bounded regardless of distance:
   at most two `block_radius` voxel walks and a `profile_samples`-point profile. A rough micro-benchmark puts one link at
   ~30µs.
3. Results are cached for `cache_ticks` (5s) per *unordered* pair of block positions and band. Path loss is reciprocal,
   so the reply to a rednet message or GPS ping is a cache hit, as are repeated messages between stationary computers.
   Concurrent requests for the same link share one evaluation.
4. Messages are delivered at the next server tick rather than instantly. Messages crossing unknown terrain wait for
   it to be looked up (below), for at most `lookup_timeout` ticks (2s), after which the model interpolates.
5. The queues are bounded: beyond 65536 pending deliveries or 8192 links waiting to be evaluated, new packets are
   dropped (congestion, like a real network).
6. Errors (for instance, from another mod's `PacketReceiver`) are caught and logged at most once a minute, so they
   can't take down the server tick.

## 4. Terrain data for unloaded chunks

The receiver set only contains modems in loaded chunks, so both ends of a link are always loaded. Only the middle of a
long link can be unloaded, and there the model only needs two heights per column: the ground
(`MOTION_BLOCKING_NO_LEAVES`) and the surface (`WORLD_SURFACE`). These come from, in order:

1. **Loaded chunks**, read live.
2. **Snapshots taken when a chunk unloads** (1KiB per chunk, LRU of 16k chunks per level).
3. **Heightmaps on disk**, read with `ChunkScanAccess` (the mechanism vanilla uses to check structures in unloaded
   chunks). This reads only the `Status` and `Heightmaps` NBT fields, asynchronously on the chunk IO thread, and never
   loads the chunk. For any chunk that has been generated, this is exact and cheap.
4. **Distant Horizons**, if installed (see below).
5. **The chunk generator** (`ChunkGenerator.getBaseHeight`) on a worker thread, sampled every 4 blocks. This only
   knows about terrain, not trees or buildings, but works for chunks that have never been generated.
6. Otherwise, **interpolation** between known samples.

### Distant Horizons

DH's API (`DhApi.Delayed.terrainRepo`, API 7.1) works on dedicated servers: the implementation accepts any loaded
`IDhLevel`, including `DhServerLevel`, and server-side DH keeps full LOD data for every column it has generated. We map
a `ServerLevel` to DH's wrapper by matching `getWrappedMcObject()`, then read a chunk at block resolution with
`getAllTerrainDataAtChunkPos` and a soft cache. Columns are ordered top to bottom, so the first non-air point gives the
surface and the first ground-like point the ground.

Two caveats from DH's source: the call is synchronous, hitting DH's database, and `getFullDataProvider().getAsync(pos)
.get()` may queue LOD generation if nothing exists yet. So DH calls run on their own thread with a 2s timeout, falling
through to the generator.

DH is deliberately *not* the primary source. On-disk heightmaps are exact for anything generated, and much cheaper.
DH's value is the area that was never generated as real chunks, which in a Tellus world with DH is most of it. The
DH API is a `compileOnly` dependency (fetched from Modrinth's Maven, carved out of the mirror's `maven.modrinth`
filter), and only loaded when DH is installed.

### Tellus

Tellus's `EarthChunkGenerator.getBaseHeight` samples its elevation data directly, so the generator source gives real
terrain heights for never-generated chunks even without DH. However, it goes through `sampleSurfaceHeight`, which may
download tiles, which is why this source only ever runs on a worker thread.

**Suggestion for Tellus:** it already has private `sampleSurfaceHeightMemoryOnly` and `sampleSurfaceHeightLocalOnly`
variants. Exposing a small public API, something like `TellusTerrain.surfaceHeight(level, x, z, CacheMode)` returning
an `OptionalInt`, would give any mod (this one, but also maps, structures or AI) a non-blocking, exact elevation
oracle for the whole planet, and would be the best possible height source here. Tellus could also expose its
`worldScale` so `metres_per_block` can be set automatically.

## 5. Lua and configuration

`modem_message` gains a seventh argument for messages received by radio: the signal strength in dBm (for instance
`-72.5`). Messages arrive down to about -100dBm. Wired and ender modem messages are unchanged. Messages are delivered
at the next server tick rather than immediately.

`PacketReceiver` keeps upstream's `receiveSameDimension(Packet, double)`, with a new default overload
`receiveSameDimension(Packet, double, double signalStrength)`, so other mods' receivers keep working.

Everything lives under `[peripheral.radio]` in the server config:

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `true` | When `false`, upstream behaviour (and the `modem_range` options) is used. |
| `reference_range` | 1024 | Range of two ground-level VHF modems on flat, open ground, in blocks. |
| `max_range` | 16384 | Hard cap on link distance. Bounds server work. |
| `low_band_frequency`, `high_band_frequency` | 150, 2400 | Band frequencies in MHz. |
| `high_band_first_channel` | 1024 | First channel on the high band. |
| `high_band_power_offset` | -20 | High band budget relative to low band, in dB. |
| `metres_per_block`, `metres_per_block_vertical` | 1, 1 | For worlds at reduced scale. |
| `earth_radius` | 0 | Planet radius in km for curvature (6371 for Earth-scale Tellus). |
| `ground_reflection` | `true` | Two-ray model (height matters) vs free space only. |
| `min_antenna_height` | 2 | Minimum antenna height above average terrain, in metres. |
| `material_loss_scale` | 1 | Multiplier for block attenuation. |
| `block_radius` | 64 | How far from each modem individual blocks are considered. |
| `profile_samples` | 512 | Maximum terrain profile points. |
| `storm_noise` | 6 | Thunderstorm noise in dB. |
| `tick_budget` | 2000 | Microseconds per tick for evaluating links. |
| `cache_ticks` | 100 | How long link results are reused. |
| `lookup_timeout` | 40 | Maximum ticks to wait for unloaded terrain heights. |
| `use_generator`, `use_distant_horizons` | `true` | Enable those height sources. |

## 6. Limitations and future work

- **No reflections or multipath.** Signals don't bounce around corners or down streets; only diffraction over the
  profile. Deygout also tends to over-estimate loss over many ridges (ITU-R P.526's delta-Bullington method would be a
  more accurate replacement).
- **Fresnel-zone obstruction of a clear path is ignored**, by design: the two-ray model already accounts for nearby
  ground, and counting both cost 6dB on perfectly flat terrain.
- **Sideways diffraction** around a building corner isn't modelled; the profile is a vertical slice along the path.
- **Materials are guessed from sound types.** A data-driven override (block tags such as
  `computercraft:radio/metal`, or a data map with per-block ITU parameters) would let packs fix modded blocks.
- **Heights are cached in memory only.** Persisting snapshots would avoid disk scans after a restart, though the scans
  are cheap.
- **No fading.** Reception is a hard threshold, so messages are deterministic. A small random fade margin near the
  threshold would be more realistic, at the cost of making GPS less reliable at the edge of coverage.
- **What has been verified:** the 26.3 port and the redesign compile for Fabric and NeoForge. The redesign passes
  checkstyle, Lua lint, all 68 `common` unit tests (including 21 for the physics: free space, two-ray, knife edge,
  Deygout, materials, voxel traversal, and whole-link scenarios such as flat ground, hills, walls, buried and bunkered
  antennas, and reciprocity), and all 115 required Fabric game tests. Those include rednet over wireless modems, a new
  test that wireless messages carry a signal strength, and upstream's wired `transmits_messages` test, which the
  original fork broke. Three optional game tests (loot chest, turtle placement, shulker push/pull) fail, unrelated to
  modems. The Distant Horizons and Tellus paths are **not** tested at runtime, and the model hasn't been played with
  in a real world yet, so the defaults will need tuning.
