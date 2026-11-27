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
  options are back). The fork's 1024 is now the range of two ground-level modems over flat, open ground at the
  default transmit power (`peripheral.radio.transmit_power`, 8.4 dBm).
- **Wired modems don't get the extra `modem_message` argument.** Only messages received by radio do.
- **The signal strength argument is in dBm**, rather than "remaining range in blocks".
- **A channel's number is its frequency** (in units of 100 kHz), and what a frequency does to range is physical
  (materials and hills cost more at higher frequencies), rather than a fixed ÷8 above channel 1023. Programs set how
  much power a modem transmits with.

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

The model computes a **link budget** in dB, as radio engineers do. A message is received if the transmit power, less
the path loss, is at least the receiver's sensitivity. The receiver is told the received signal strength in dBm.

Each modem transmits with a power programs can set (see [Frequencies and power](#frequencies-and-power)). By default
it is 8.4 dBm for placed computers, which makes two modems sitting on flat, open ground just hear each other 1024 blocks
apart. Everything else follows from the physics: raising a modem extends its range, while hills and walls shrink it.

### Path loss

**Base loss** from distance alone uses the **two-ray ground reflection** model: free-space loss
(`20log d + 20log f − 27.55`) up to the crossover distance `4π·h₁·h₂/λ`, and `40log d − 20log(h₁h₂)` beyond it. Near
the ground, the reflected ray cancels the direct one, so loss grows with the fourth power of distance. Antenna heights
are measured above the *average terrain along the path*, so a modem on a mountain overlooking a valley does well,
while one at the bottom does not. This replaces upstream's "range increases above y=96" rule with the real reason it
exists.

On top of that, the signal takes the better of two paths:

- **Through**: straight through whatever is in the way. We walk every block along the ray with an exact voxel
  traversal (Amanatides & Woo, not Bresenham, so no voxels are skipped and no diagonal correction is needed) and sum
  each block's attenuation × path length × fill fraction. Where a chunk isn't loaded we only have heightmaps, so the
  ray is classified as underground (rock), in vegetation (between the ground and surface heightmaps), or in the open.
  An earlier version only walked real blocks within `block_radius` of each antenna and used heightmaps for the whole
  middle of the link, even through loaded chunks. A heightmap can't see a tunnel, so a straight 3×5 tunnel cut out
  at 134 blocks: past 2 × 64 blocks, the middle was assumed to be rock, at 7.4dB a block on the low band.
- **Over**: escape any enclosure around each antenna (walls, a forest canopy, a cave), then **diffract over the terrain
  profile** between them. Diffraction uses Deygout's method with the ITU-R P.526 knife-edge approximation
  `J(ν) = 6.9 + 20log(√((ν−0.1)²+1) + ν − 0.1)`, recursing one level either side of the main edge. If the straight
  ray from an antenna stays underground, we try escaping straight up instead, so a modem three blocks under the floor
  of a bunker gets through the ceiling and diffracts from the surface.

Taking the better path means a wooden shed between two modems costs a few dB (through it), a mountain costs the
diffraction loss over its top (not the sum of every stone block inside it, which the old model did), and a deep cave
is cut off.

The profile has at most `profile_samples` evenly spread points, which on a long link are several blocks apart (16 at
8km), so a house right next to a modem would fall between them. On such links every block within `block_radius` of
each end is sampled too: that's where a building matters most. It also means a flat roof is seen as what it is, which
Deygout counts as two edges (see the limitations).

**Reflections.** Besides the direct path, the signal may reflect once off a wall near either end (the image method),
which brings some of it round whatever is in the way there: in a village, the wall of the house across the street.
Near an end whose direct ray hits something on the way out (and reaches open air), every vertical plane of block faces
within 24 blocks is tried: the other end is mirrored in it, and where the line to the image meets the plane must be a
wall's face (a block at least half full, of anything but leaves or water) with open space in front. The leg to the wall
is walked, and the leg on, as far as this end's section of the link; beyond that, the path shares the direct path. The
reflection costs what Fresnel's coefficient says for the wall's material (an electric field along the wall: concrete
about 8dB head-on and next to nothing at a glancing angle, wood more, metal nothing), and the wall only reflects as
much as it covers of the first Fresnel zone around the point (sampled at 21 points, with the zone stretched along a
wall the path meets at an angle): a lone block hardly at all. At most 8 reflections are kept near each end. The
reflected paths' powers add to the direct path's. In a village scene (a cell 2.5km off at an angle to the streets, a
house in the way, a neighbour's wall across the street) the signal comes back from 134-150dB (lost) to 106-114dB, about
6dB short of the open street (100-109dB); behind a lone house in a field nothing changes. The walks for reflections don't depend on
the budget a link is traced for (where the direct path's walks were cut short, they're walked again, to a fixed cap), so
a cached path answers as a fresh trace would. `reflections = false` turns them off.

Optionally, the terrain profile is bent by the earth's curvature (`earth_radius`, with the standard 4/3 effective
radius factor for atmospheric refraction). This matters for Tellus at 1:1 scale, where the bulge is 1.5m at the
middle of a 10km link and 36m over 50km.

### Antenna position

A modem's `getPosition()` is the corner of the block it is attached to (or of its turtle). The distance passed to
`modem_message`, and so GPS, is measured from there, and stays that way. The model instead uses where the antenna
actually is, through `RadioAntenna`: the middle of the modem block itself, the middle of a turtle, or a pocket
computer holder's eyes (the middle of a lectern). The first block along the ray from each antenna, which it is
mounted on, is ignored.

An earlier version used `getPosition()` plus half a block. That put the antenna of a computer set into a tunnel
ceiling inside the rock, so a modem hanging in plain sight lost the low band within 64 blocks, and the high band
within 10.

Mods which turn blocks into moving objects may keep those blocks somewhere else. Sable (used by Create Aeronautics)
keeps each object's blocks in a "plot" in the same level, around X/Z 20,480,000, and only draws them where the object
is. A modem on one would report the plot position, and so be some 29 million blocks from everything, out of range of
every other device (or, without the radio model, of every other wireless modem; ender modems still got through, but
with nonsense distances). Sable patches vanilla's own distance checks, such as a player's reach, but can't know about
ours. So modems, turtles and pocket computers map both of their positions back to the world through Sable Companion
(`shared.integration.Sable`), which also makes `modem_message` distances, and so GPS, right on a moving object.

### Frequencies and power

**A channel's number is its frequency in units of 100 kHz**, as 3GPP's channel raster is: channel 1500 is 150 MHz,
channel 9250 is 925 MHz, and channel 24000 is 2.4 GHz. The model works from 30 MHz to 10 GHz; channels below 300 are
treated as 30 MHz. Higher frequencies lose more in free space (within the two-ray crossover distance), diffract worse
(ν grows with √f) and are attenuated far more by materials. Beyond the crossover distance, the two-ray loss doesn't
depend on the frequency, so on flat, open ground every frequency reaches as far for the same power: low frequencies
win over hills, through forests and through walls.

Three kinds of message have frequencies of their own, whatever their channel:

- **Rednet's messages** (2400 MHz, `rednet_frequency`), recognised by the table rednet wraps them in (a message ID and
  a numeric recipient, the check rednet's repeater makes). Going by channel would treat rednet unevenly: it sends to a
  computer on that computer's ID channel, so every computer would get a different frequency, and a reply could travel
  at a different frequency from the message it answers. Broadcasts, lookups and repeaters are rednet's too. Rednet is
  also sent with 20 dB less power (`rednet_power_offset`), which keeps it short range: ~260 blocks over flat ground at
  the default power, as before.
- **GPS's channel**, 65534 (GPS's L1, 1575.42 MHz, `gps_frequency`). Hosts send their positions every 2 seconds and
  computers only listen, so a pocket computer's weak transmitter doesn't limit how far GPS works: the hosts' power
  does (`gps host <x> <y> <z> power 30`). At the default power, a host 30 blocks up reaches pocket computers about
  1.8km away over flat ground (about 2.7km at 150 MHz, where GPS was while computers asked hosts for their positions);
  at 30 dBm, about 9km.
- **Other messages on rednet's channels** (65533 and 65535), which are taken for rednet's.

**Each modem transmits with a power programs set** (`modem.setTransmitPower`, in dBm), up to a limit for each kind of
device:

| Device | Default | Most | Sensitivity |
|---|---|---|---|
| Placed computer | 8.4 dBm | 50 dBm | −100 dBm |
| Pocket computer | −1.6 dBm | 23 dBm (a phone's) | −93 dBm |
| Turtle | −1.6 dBm | 30 dBm | −93 dBm |

The defaults are what the old offsets gave, so the old low band (now channels 300–1739, say) and rednet reach as far
as they did (GPS has moved to L1, above). What used to be the high band (channels 1024 and up, 20 dB weaker) has no penalty of its own any more: it
reaches as far as any frequency over open ground at the same power, and only loses more to walls and hills. Ender
modems radiate 10 dB less than they're set to. Power captured when a packet is sent counts, even if a program
changes it before the packet is delivered. A link is traced as far as the packets waiting for it need, at every
frequency; a stronger transmitter later traces it again, unless the link was within the first budget anyway.

Some numbers with the defaults: two modems on 30m towers reach ~15km over flat ground; one tower and one ground-level
modem reach ~4km. A 40-block ridge halfway along a 1km link costs ~34dB at 150 MHz and ~55dB at 2.4 GHz.

### Materials

There is no "material" on blocks any more, so blocks are classified by sound type (a good proxy for what a block is
made of), a few tags (leaves, ice, dirt, sand) and fluids. Partial blocks attenuate in proportion to their collision
volume; blocks with no collision count as 10% full.

Blocks people build with (planks, logs, bricks, cobblestone, stone bricks, glass, wool, metal) are marked as **built**:
a wall one block thick stands for a real wall about 30cm thick, so built blocks count `built_loss_scale` (0.3) of a
full block. Natural rock (the base stone tags, terracotta, ores, sandstone, end stone and a few more), dirt, sand, snow,
ice, water and plants keep their full loss, so hills, caves and bunkers block as before. Behind a stone house, low
frequencies now get through it (about 11dB at 450MHz, 17dB at 800MHz for two walls) while high ones still go over the
roof (35-37dB at 1.8-2.6GHz), as in real life, where buildings stop high bands much more than low ones.

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
   the channel, and not ruled out by free-space loss alone (which is a lower bound on any real path loss). Receivers
   whose link to the sender is cached (step 4) get the packet at once, still on the computer thread, as with the
   original modems. The rest are queued, and the server thread is woken to deliver them, and the call returns
   immediately. While a sender has packets queued, its next packets are queued behind them, even over cached links, so a
   sender's packets arrive in the order it sent them.
2. As soon as the server thread has time between ticks, and at the start of each server tick, `RadioPropagationService`
   traces queued links on the server thread, reading loaded chunks directly through `getChunkNow` and chunk sections (no
   cross-thread hops, no loading). Vanilla runs queued tasks while it waits for the next tick, waking when one is added,
   so with time to spare a packet over a new link is delivered within a millisecond or two, as is one whose terrain
   heights just arrived. A server which is behind has no time between ticks, and packets wait for the next tick. Work is
   capped at `tick_budget` (2ms) per tick, and per run between ticks, which also stops a millisecond before the next
   tick is due; leftovers wait. Each trace is one voxel walk along the ray
   (which stops once the signal is lost at every frequency), a `block_radius` walk at each end to find where the
   signal leaves any enclosure, and a `profile_samples`-point profile. A rough micro-benchmark puts one link at ~15µs
   for 1km, ~30µs for 4km and ~85µs at 16km, measured before tracing became independent of the frequency (below).
3. **A trace doesn't depend on the frequency.** What it records (`LinkPath`) is how many metres of each material the
   signal passes through (straight through, and on the way out of each antenna's enclosure), the antennas' heights
   for the two-ray model, and the Deygout obstacles. Each obstacle's diffraction parameter scales with `1/√λ`, so the
   main obstacle and those either side of it are the same at every frequency; only whether each counts, and what it
   costs, isn't. Turning a path into a loss at a frequency takes microseconds: materials' attenuations come from a
   table per frequency, worked out once. The walks stop once the loss, at each material's *least* attenuation over the
   whole frequency range (about 2 dB/m for rock, rather than 7.4 at 150 MHz), is beyond the budget of the packets
   waiting for the link, so a path serves every frequency. That makes walks through rock or forest go a few times
   further than a walk for one frequency would. The micro-benchmark above hasn't been run again since.
4. Paths are cached for `cache_ticks` (5s) per *unordered* pair of block positions, whatever the frequency. Path loss
   is reciprocal, so the reply to a rednet message is a cache hit, as are repeated messages between
   stationary computers, and the two directions of a link whose uplink and downlink use different frequencies.
   Concurrent requests for the same link share one trace, as far as the strongest of them needs. A path traced for a
   weaker transmitter is traced again for a stronger one, unless the link was within the weaker one's budget (its
   loss is then exact whatever the budget). **A link in use doesn't expire:** a packet over a cached path in its last
   second (at most a quarter of its lifetime) still goes at once, and has the link traced again in the background
   (once), which caches it afresh. Before, the first packet after a link expired went to the server thread, which
   reuses the old path at once (step 5) but only once it has finished its tick: a ping over a cell and two relays
   had a spike of about 10ms every 5 seconds for each of its links. A link in constant use is now traced every 4
   seconds rather than 5; one which isn't used in its last second still expires.
5. **Radios which move don't wait.** As paths are cached by block, every block a phone moves into is a link which
   hasn't been traced, and on a long link tracing takes a while: a 40km link which closes took about 1ms (half a
   tick's budget), measured offline and warm, with heights only for the chunks its profile samples, as a server has;
   and its profile crosses about 500 chunks, most of which a Tellus world hasn't generated, so their heights must be
   looked up. Walking a block at a time needed about 8 more chunks' heights a block for one 40km link, and 64 for the 15
   always-loaded computers of a test world 40km off. So the same two radios' last path is remembered too (by the
   modems themselves, either way round: `RecentLinks`), and a packet between them goes at once with that path if
   neither has moved more than `move_tolerance` (16) blocks since and it was traced within `2 × cache_ticks`. The link
   where they are now is traced in the background. Each pair has at most one such trace waiting, which a newer one
   replaces, so a phone which keeps moving only has its latest position traced, and a cached path which expires is
   traced again in the background too, rather than holding up the next packet. Only a link between two radios which
   haven't had one traced lately (or which moved further) waits for a trace.
6. **Open sky isn't walked block by block.** The straight-through walk of a long link crosses thousands of chunks,
   mostly high above the ground. Where it's above the top of a chunk whose heights are known (`TerrainView.chunkTop`,
   the highest of its columns' heights), or, in a chunk with no heights, above the profile's heights that the walk
   would go by there, the model would only find air, which costs nothing; so the walk goes on without looking. Wherever
   a mountain, a tree or a building reaches the ray, the blocks there are walked as before; loaded chunks always are,
   and nothing is skipped beneath a ceiling (the Nether). The result is exactly the same: `OpenSkyTest` traces 1,200
   random links over random mountains (reaching into the ray or not, with chunks loaded, with heights, or without,
   and under open sky or a ceiling) both ways, and requires identical losses at six frequencies.

   A chunk of open sky isn't even stepped through: the walk jumps to the next chunk, if the lowest block the ray passes
   through in it is above where it's open sky. For that to change nothing after it, the middle walk (`VoxelRay`'s
   `traverse` with a `Skipper`) works out where the ray leaves each block afresh on entering each chunk, and adds up
   step by step within it, so the walk through a chunk is the same however it got there; a jump lands just as stepping
   would have (`VoxelRayTest`: 3,000 random rays, including ones along an axis, straight up, and at exactly 45° through
   block corners, skipping random chunks, visit exactly the blocks a walk which never skips does outside them). That
   makes the middle walk differ from before in the last few digits; the walks near each end and to walls don't
   change. The walk only works out where the ray leaves a chunk if it enters high enough to skip it, which most chunks
   near the ground aren't.

   Measured offline, warm: a 40km link which closes went from 1.06ms (every block looked at) to 0.73ms (open sky not
   looked at) to 0.26ms (open sky jumped over); a 2.5km village link and a 300-block link in a base, which have little
   open sky to skip, are 5-7% slower than before (46µs and 8µs). Turning a path into a loss for a packet takes under
   0.4µs.
7. Messages are delivered at the next server tick rather than instantly. Messages crossing unknown terrain wait for
   it to be looked up (below), for at most `lookup_timeout` ticks (2s), after which the model interpolates.
8. The queues are bounded: beyond 65536 pending deliveries or 8192 links waiting to be evaluated, new packets are
   dropped (congestion, like a real network). They're shared by the whole server: a link waiting to be traced waits
   behind every other, whoever's it is.
9. Errors (for instance, from another mod's `PacketReceiver`) are caught and logged at most once a minute, so they
   can't take down the server tick.

## 4. Terrain data for unloaded chunks

The receiver set only contains modems in loaded chunks, so the chunk at each end of a link is always loaded. The rest
of the link may not be: the middle of a long link, and the blocks round an end beyond the chunks which keep it loaded
(see the limitations). There the model has only two heights per column: the ground (`MOTION_BLOCKING_NO_LEAVES`) and
the surface (`WORLD_SURFACE`), and a block below the ground counts as rock, one between the two as vegetation, and one
above both as air. The heights come from, in order:

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

Watch out for Y positions: `DhApiTerrainDataPoint`'s Javadoc says they are relative to the level's minimum height, which
is true for points handed *to* DH by a world generator (Tellus writes them that way). But the terrain repository adds
the minimum height when reading them back (`DhApiTerrainDataPointUtil.createApiDatapoint`), so what we get is absolute.
Reading them as relative put every DH column `-minY` blocks too low, 512 in a Tellus world, which made mountains
vanish: a cell 8.5km away behind a 580m ridge came through at -86dBm rather than being out of range. Since the top of
every column is open sky reaching the top of the level, we check where that ends to tell the two conventions apart.

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
`-72.5`). Messages arrive down to about -100dBm. Wired and ender modem messages are unchanged. Messages over a link
traced in the last few seconds are delivered immediately. Others are delivered as soon as the server has time, or at
the next server tick if it's busy. `ping` and `traceroute` time replies with `os.epoch("utc")`, as `os.clock` only
counts whole ticks.

Wireless modems (and pocket computers' and turtles' modems) gain `setTransmitPower(power)`, which sets the power in
dBm, reduced to the device's limit (or, given nothing, goes back to the default), and returns what it was set to; and
`getTransmitPower()`, which returns the power, the most it may be set to, and the least. The power lasts until it is set
again or the modem is removed. The cellular network sets it on the modems it uses: 23 dBm for phones and 30 dBm for
cells, unless they're told otherwise (see NETWORK_CELLULAR.md).

`PacketReceiver` keeps upstream's `receiveSameDimension(Packet, double)`, with a new default overload
`receiveSameDimension(Packet, double, double signalStrength)`, so other mods' receivers keep working.
`PacketSender.getTransmitPower()` gives a sender's power in dBm; other mods' senders, which don't say, transmit with
the default for placed computers.

Everything lives under `[peripheral.radio]` in the server config:

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `true` | When `false`, upstream behaviour (and the `modem_range` options) is used. |
| `max_range` | 65536 | Hard cap on link distance. Bounds server work. |
| `max_message_size` | 65536 | Largest wireless or ender message, in bytes, estimated from its contents. 0 for no limit. |
| `transmit_power`, `max_transmit_power` | 8.4, 50 | Placed computers' default and greatest power, in dBm. 8.4 dBm reaches 1024 blocks over flat ground. |
| `pocket_transmit_power`, `pocket_max_transmit_power` | -1.6, 23 | The same for pocket computers. |
| `turtle_transmit_power`, `turtle_max_transmit_power` | -1.6, 30 | The same for turtles. |
| `pocket_receive_offset`, `turtle_receive_offset` | -7, -7 | How much worse they hear than placed computers, in dB. |
| `ender_power_offset` | -10 | How much less ender modems radiate than they're set to, in dB. |
| `rednet_frequency`, `rednet_power_offset` | 2400, -20 | Rednet's frequency in MHz, and how much less power it's sent with, in dB. |
| `gps_frequency` | 1575.42 | The frequency of GPS's channel, in MHz: GPS's L1. |
| `metres_per_block`, `metres_per_block_vertical` | 1, 1 | For worlds at reduced scale. |
| `earth_radius` | 0 | Planet radius in km for curvature (6371 for Earth-scale Tellus). |
| `ground_reflection` | `true` | Two-ray model (height matters) vs free space only. |
| `min_antenna_height` | 2 | Minimum antenna height above average terrain, in metres. |
| `material_loss_scale` | 1 | Multiplier for block attenuation. |
| `built_loss_scale` | 0.3 | Further multiplier for blocks people build with: a one-block wall stands for one this many metres thick. |
| `reflections` | `true` | Whether signals reflect once off walls near each end of a link. |
| `block_radius` | 64 | How far from each modem to look for a way out of a building, cave or tunnel, for the path over the terrain. |
| `profile_samples` | 512 | Maximum terrain profile points. |
| `storm_noise` | 6 | Thunderstorm noise in dB. |
| `tick_budget` | 2000 | Microseconds per tick for evaluating links. |
| `cache_ticks` | 100 | How long link results are reused. |
| `move_tolerance` | 16 | How far (blocks) two radios may have moved since their link was traced for a packet between them to go at once with that path, while it's traced again in the background. 0 makes every such packet wait. |
| `lookup_timeout` | 40 | Maximum ticks to wait for unloaded terrain heights. |
| `use_generator`, `use_distant_horizons` | `true` | Enable those height sources. |

### Keeping computers running

A cell site is only useful if it keeps transmitting while everyone is far away. `os.setKeepLoaded(true)` asks for
that: while the computer is on, it keeps its own chunk ticking and the chunks around it loaded (so a modem across a
chunk border still works). This is lighter than `/forceload`, which ticks a 3×3 area and loads 5×5. The setting is
saved with the computer, survives reboots, and is cleared with `os.setKeepLoaded(false)`. `os.getKeepLoaded()` reads
it. Placed computers and turtles can do this; on pocket computers it is an error. The server can turn it off with
`allow_keep_loaded` (default `true`).

A turtle keeps more loaded: its own chunk and the eight around it tick, and the ring around those is loaded, as
`/forceload` does. A chunk only ticks once all its neighbours are loaded, so with a computer's area, the chunk a turtle
moves into would be loaded but not ticking until the chunks beyond it had loaded (or been generated): the turtle would
stop at every chunk border, and be shut down if that took over five seconds. With the larger area, each chunk next to
the turtle is ticking before it moves in. The area moves with the turtle: when it crosses into another chunk, the new
chunk is kept loaded at once, and the old chunk's ticket is removed (unless another computer kept loaded is in that
chunk, as they share it).

It's built on a chunk ticket the computer refreshes every tick. Once the computer turns off, is broken, or clears the
setting, the ticket times out after five seconds and the chunk unloads as usual, so a computer can't leave a chunk
loaded forever. Clearing the setting also removes the computer from the restart list (below) at once. Vanilla can save tickets with the world, but a world whose ticket list names an unknown ticket type
fails to read all of it (including `/forceload` chunks), so removing the mod would break those. Instead,
`computercraft/keep_loaded.json` lists the computers being kept loaded, and the server adds tickets for them when it
starts. The computers then turn back on as their chunks load, and run their startup program. A computer which
doesn't come back within a minute is forgotten. A moving turtle changes the list with every move, so it's written at
most once a second, and when the server stops. After a crash the list can be up to a second old, and so miss a
turtle which moved into another chunk in that second (the world itself is usually older still, as it's only saved
every few minutes).

## 6. Limitations and future work

- **One reflection, near the ends, off axis-aligned walls.** Signals reflect once off vertical block faces within 24
  blocks of an end; not twice, not off sloped or diagonal surfaces, and not with diffuse scattering. Whether a wall
  covers the Fresnel zone is judged from how far it reaches along and up from the point the path meets it, so windows
  and doors in it are ignored. Measured with the model itself (outside the game), reflections cost 0-4% more block
  lookups and 3-8% more time for links with something in the way near an end, and nothing for clear links. Deygout also tends to over-estimate loss over
  many ridges (ITU-R P.526's delta-Bullington method would be a more accurate replacement).
- **Fresnel-zone obstruction of a clear path is ignored**, by design: the two-ray model already accounts for nearby
  ground, and counting both cost 6dB on perfectly flat terrain.
- **Sideways diffraction** around a building corner isn't modelled; the profile is a vertical slice along the path.
  The study put its gain at 1-8dB behind a house, for 13-21% more work on obstructed links, so it was left out.
- **Deygout counts a flat roof as two edges**: the near one, and the far one at a grazing angle, which alone costs about
  6dB. Over a 7-block house with a player 5 blocks behind it, at 800MHz, that's 32dB, against 26dB over a one-block wall
  of the same height. Before every block near the ends was sampled, samples several blocks apart mostly caught one edge
  of a roof, so houses cost about 6-8dB less over the top. Deygout is known to over-count edges this close together.
- **The over path counts the ground near the antennas twice** once the direct ray is blocked: the two-ray model, and the
  ground's intrusion into the Fresnel zone (about 12dB at 450-800MHz on flat ground). And the profile ignores
  everything within 1.5 blocks of an antenna in the open, so a thin wall right next to one is missed by the over path.
- **Near a computer kept loaded, only its own chunks have real blocks.** `os.setKeepLoaded` loads the computer's chunk
  and the eight around it: 16-31 blocks each way, depending on where it stands in its chunk (32-47 for a turtle, which
  loads two rings). The model looks at single
  blocks up to `block_radius` (64) from each end, and for walls to reflect off up to 24. Past those chunks, with nobody
  nearby, it has only heights, so a house there reads as solid rock up to its roof: nothing gets through it
  (`built_loss_scale` can't apply, as heights don't tell built from natural), and its walls don't reflect. The path
  over it is the same either way, as the heights include roofs. So a cell among houses at about roof height can gain or
  lose a phone far away when a player comes near the cell or leaves (links are evaluated again every few seconds). A
  cell whose antenna is above the roofs around it isn't affected: its rays to distant phones pass over them, through
  air either way. The model never loads a chunk to look. Loading a wider ring round cells, with a second ticket which
  loads chunks without ticking them, was considered and left out: a radius of 2 (25 chunks, 16 more) would cover
  reflections, and 4 (81 chunks) all of `block_radius`. At a player's end, the view distance covers `block_radius`
  unless the server sets it below 5.
- **A moving radio's packets use a path up to one move old**, until the link where it is now has been traced:
  usually by the next tick, but up to `lookup_timeout` (2s) when far terrain's heights are being looked up. Walking
  indoors, packets keep the outdoor strength that long. A radio which moves more than `move_tolerance` blocks between
  traces (an aircraft, between two beacons) waits for each trace, as all did before. Nor is the queue fair between
  players: a phone far from many cells, walking about, puts a long trace in it for each cell it hears.
- **New far links wait for terrain heights, on one thread.** A link across chunks nobody has generated waits (up to
  `lookup_timeout`) for their heights, which one low-priority thread looks up in turn: from disk, from Distant
  Horizons, or from the world generator, which for Tellus may be slow. A few threads, or looking up the chunks a moving
  radio's next trace will need before it's traced, would make a phone's first contact with a far cell quicker. (Not
  the server's CPU time: none of this runs on the server thread.)
- **Materials are guessed from sound types.** A data-driven override (block tags such as
  `computercraft:radio/metal`, or a data map with per-block ITU parameters) would let packs fix modded blocks.
- **Heights are cached in memory only.** Persisting snapshots would avoid disk scans after a restart, though the scans
  are cheap.
- **No fading.** Reception is a hard threshold, so messages are deterministic. A small random fade margin near the
  threshold would be more realistic, at the cost of making GPS less reliable at the edge of coverage.
- **What has been verified:** the 26.3 port and the redesign compile for Fabric and NeoForge. The redesign passes
  checkstyle, Lua lint, all 75 `common` unit tests (including 24 for the physics: free space, two-ray, knife edge,
  Deygout, materials, voxel traversal, and whole-link scenarios such as flat ground, hills, walls near and far from
  the antennas, long tunnels, buried and bunkered antennas, and reciprocity), and all 117 required Fabric game tests.
  Those include rednet over wireless modems, new tests that wireless messages carry a signal strength, that modems
  hanging from computers set into a stone ceiling can hear each other, and that placed computers (but not turtles) can
  be kept loaded, and upstream's wired `transmits_messages` test, which the original fork broke. No automated test can
  show a kept-loaded chunk keeps ticking with nobody nearby, as game tests keep their area loaded anyway. Three optional game tests (loot chest, turtle placement, shulker push/pull) fail, unrelated to
  modems. The Distant Horizons conversion has unit tests, and its output was checked offline against a real 1:10
  Tellus save: LOD heights decoded from DH's database match the saved chunks' heightmaps, and running the model over
  them gives sensible results for four cells (clear line of sight from a 280m summit 4.3km away: -83dBm on the low
  band; cells behind 420m and 580m ridges: out of range). The defaults still need tuning in play.
