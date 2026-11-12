<!--
SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers

SPDX-License-Identifier: MPL-2.0
-->

# Network stack: what to improve next

This is a plan, not a record: nothing in it has been done. It lists what could be improved, tweaked, reworked or
streamlined in the network stack as it stands after the ender modem rework, from reading the code and from what the
robustness tests showed. `NETWORK_STACK.md` says what the stack is and how it was built; this says what to do to it
next.

Each item says what was seen and where, why it matters, what to change, and roughly how big the change is:

- **small:** under an hour
- **medium:** half a day
- **large:** more, or a change to a protocol or a file format

Items marked **suspected** were seen by reading and not confirmed by a test. Everything else was confirmed by reading
the code named, or by a test. Paths are relative to
`projects/core/src/main/resources/data/computercraft/lua/rom/` unless they say otherwise.

## The short version

1. **Fix first** (§1): a handful of faults and loose ends, most of them small. The ones which lose something are the
   stray event on every datagram (1.1), `rshd` dropping screen updates (1.2), and the three in the wiring commands
   (1.9 to 1.11).
2. **Then make the work cheaper** (§5): a way to run one spec. Every change to the Lua stack costs a two and a half
   minute test run today, whatever was changed.
3. **Then streamline** (§2): shared helpers for files, hex, send loops and remembered sets remove about fifteen copies
   and are safe to do one at a time, as the tests cover what they replace.
4. **The reworks** (§3) are each worth doing, and each large. One connection between two cores (3.1) removes the most
   code and the most ways to go wrong. The phone's state machine (3.2) is where the next faults are most likely to be
   found.
5. **Performance** (§4) matters once networks are big: timers, routes, and what a phone does each second.

## 1. Faults and loose ends

### 1.1 Every datagram to an address queues a stray event

- **Where:** `apis/net.lua` 386–394 (`await`), 396–415 (`resolver_options`), 418–421 (`resolve_number`), 775
  (`Socket:send`).
- **Seen:** `await` queues `net_done` from its callback whenever the callback runs. For an address, a cached name or
  the computer's own name, `dns.resolve` calls back at once, so `await` returns without pulling the event it queued.
  Before that, `resolver_options()` has read three settings and walked every DHCP client. `Socket:send` does this for
  each datagram, also `send("10.0.0.2", …)`.
- **Why:** a busy sender leaves one useless event in the queue for each datagram. The queue holds 256; when it's full,
  other events are dropped, `modem_message` and the stack's timer among them.
- **Change:** try `address.parse` first in `resolve_number`, and only queue `net_done` if the callback runs after
  `start` has returned. **Small.**

### 1.2 `rshd` drops screen updates without saying, and may eat the session's events

- **Where:** `modules/main/cc/internal/net/remote_term.lua` 53–55 and 139–144; `programs/net/rshd.lua` 63–65 and 77–87.
- **Seen:** drawing calls gather in one batch until the session yields, and the result of sending it is ignored. A
  program which prints a few thousand lines without yielding makes a batch over the message limit, which is refused,
  and the client's screen is out of step from then on.
- **Suspected:** when the connection's window is full, `Connection:send` waits with `os.pullEvent()` and drops what it
  pulls. Inside `rshd` those events are the hosted session's, so a `sleep` in a remote program could hang.
- **Change:** send the batch when it passes about 32 KiB (`message.measure` exists for this), check the result, and
  give `rshd` a way to send which keeps the events it pulls for the session. **Medium.**

### 1.3 A manual address change queues no event

- **Where:** `apis/net.lua` 292 (DHCP's `on_change`) and 297–315 (`apply`).
- **Seen:** `net_interface` with `"address"` is only queued when DHCP changes an address. `net.setAddress` and
  `ifconfig` change one without it, though the design promises the event.
- **Change:** queue it in `apply`. **Small.**

### 1.4 `ifconfig` saves an address before it's checked

- **Where:** `programs/net/ifconfig.lua` 128–140.
- **Seen:** the setting is saved once the address parses, then `net.setAddress` may still refuse it (a network's own
  address, a broadcast address, loopback). The user sees a Lua error, and the setting stays, logged as a bad address
  at every start.
- **Change:** set the address first, and save only if that worked. **Small.**

### 1.5 `ping` and `traceroute` mishandle bad arguments and bad names

- **Where:** `programs/net/ping.lua` 30; `programs/net/traceroute.lua` 11.
- **Seen:** `ping` looks for a reason starting "Invalid", which nothing returns, so a name which doesn't resolve is
  tried as many times as asked. `traceroute` takes its hop limit with `tonumber`, so text or a number over 255 raises
  an error.
- **Change:** stop on "Name not found" and "No DNS server", and check the hop limit. **Small.**

### 1.6 Timeouts and ports are checked in some calls and not others

- **Where:** `apis/net.lua`: `ping` (723–726) checks its timeout fully; `Socket:receive` (788), `Connection:receive`
  (881), `Listener:accept` (949), `tcp.connect` (1019), `lookup` (667) and `secure.connect` (1301–1316) only check the
  type. `udp.open` (839) and `Socket:send` (769) don't check the port at all; `tcp.listen` does.
- **Seen:** `net.lookup("x", math.huge)` raises "Invalid delay inf" from inside the stack.
- **Also:** a datagram socket returns a bare `nil` on a timeout or when closed, where connections return
  `nil, "Timed out"`.
- **Change:** one `check_timeout` and one `is_port`, used everywhere, and the same two results from every `receive`.
  **Small**, though the second is a change of behaviour: `dhcpd`, `dnsd` and `nc` should be checked.

### 1.7 The trust store's functions don't agree with each other

- **Where:** `apis/net.lua` 1112–1134 and 1345.
- **Seen:** `trusted()` cleans what it reads, `knownHosts()` returns the file as it is. `fingerprint(key)` hashes text
  which isn't hexadecimal as if it were a key. Any `trust` other than `"certificate"` is taken as the default, also
  ones which are spelling mistakes.
- **Change:** clean both lists the same way, refuse keys which aren't keys, and refuse unknown `trust` values.
  **Small.**

### 1.8 A handler which fails leaves packets queued

- **Where:** `modules/main/cc/internal/net/stack.lua` 763–778 (`deliver`).
- **Seen:** when a handler raises an error, the packets queued behind it stay queued until some later packet arrives
  for this computer.
- **Change:** log the error and carry on through the queue, as `tick` does for timers. **Small.**

### 1.9 The wiring trace can generate chunks (suspected)

- **Where:** `projects/common/src/main/java/dan200/computercraft/shared/peripheral/modem/wired/UnloadedWiring.java`,
  the trace.
- **Seen:** the trace loads the chunks cables lead into with `level.getChunk`, which generates a chunk which doesn't
  exist yet: up to 4,096 for each run.
- **Change:** only load chunks which exist on disk, and count the others as known and empty. **Small to medium.**

### 1.10 Chunks with no wiring are never known (suspected)

- **Where:** the same file: what counts as a chunk which is known.
- **Seen:** a chunk is known if it's loaded or has remembered wiring. A full-block modem at a chunk's edge always has
  a port outwards, so a neighbouring chunk with no wiring counts as unknown for good: `wiring status` over-reports,
  and each `wiring trace` loads those chunks again.
- **Change:** remember chunks which were looked at and had nothing, in the file too (a new version of it). **Medium.**

### 1.11 Smaller things in the wiring (suspected)

All in `UnloadedWiring.java` unless they say otherwise. Each is **small**.

- A save which fails isn't tried again until something else changes: the changed flag is cleared before the write.
- There's one trace for the whole server, and `wiring status` in one dimension shows the numbers of a trace in
  another.
- Reading the file doesn't check that a port lies in its piece's chunk. With the checksum now checked, only a file
  made by hand gets that far.
- `WiredNodeImpl.acquireReadLock` reads the node's network once, outside its retry loop. If the network changed
  between the read and the lock, it would spin. Seen in passing, and not looked into.
- Wiring remembered for a dimension which no longer exists is kept and written again for good.

### 1.12 A phone which names a network its cell doesn't serve

- **Where:** `modules/main/cc/internal/net/cell/tower.lua`, `Tower:link_for`.
- **Seen:** if the cell serves one network, any phone is taken to it, whatever network it named. For a second or so
  after a shared cell loses a core, a phone of that network is attached as a visitor to the other, then notices and
  attaches again.
- **Change:** only fall back to the only network when the phone named none. **Small.**

### 1.13 Another network's core may introduce itself with no name

- **Where:** `modules/main/cc/internal/net/cell/core_service.lua`, `Service:wait` and `requests.allow`.
- **Seen:** a core which says it wants to carry phones or exchange messages, but gives no usable network name, is
  shown to the administrator without one. If it's allowed, the name it gives the first time it connects after that is
  the one it keeps.
- **Change:** refuse such a hello before it waits, so what the administrator allows always has a name. **Small.**

### 1.14 RIP updates can be replayed (suspected)

- **Where:** `modules/main/cc/internal/net/rip.lua` 150 and 230.
- **Seen:** the HMAC covers the routes and nothing else, so a signed update which was overheard can be sent again
  later, to bring back a route which was withdrawn. The design says nobody can inject routes. The comparison is a plain
  `~=`, which takes a different time for different wrong answers.
- **Change:** sign the sender's time too, refuse updates older than the last from that neighbour, and compare with
  `crypto.equals`. **Medium**, and a change to the protocol.

### 1.15 Nothing says which version of a protocol a computer speaks

- **Where:** `cell/common.lua` (`SIB_PREFIX`, `make_sib`), `cell/phone.lua` and `cell/core.lua` (`v = 1` in the
  handshakes' payloads).
- **Seen:** system information changed shape when cells learned to serve several networks. A phone with the older
  ROM (a datapack on one server, say) would hear nothing it can read, and say "Searching" for good. The `v` fields are
  written and never read.
- **Change:** a version number in system information and in the control hello, and a state for the phone which says
  the network is newer than it is. **Medium.**

### 1.16 The generated files were changed by hand

- **Where:** `projects/common/src/generated/resources/` (`recipe/cable.json`, `lang/en_us.json`).
- **Seen:** the data generator needs the game's assets, which the sandbox the ender modem rework was done in couldn't
  fetch. The two files were edited to match `RecipeProvider` and `LanguageProvider`.
- **Change:** run `./gradlew :fabric:runData` once and commit whatever differs. Have CI run it and fail when the
  output differs from what's committed, if it doesn't already. **Small.**

## 2. Streamlining

Each of these replaces copies with one thing. None changes what the stack does, and the tests which cover the copies
cover the replacement.

### 2.1 One module for files and hexadecimal

- **Copies:** `to_hex` five times (`apis/net.lua` 1059, `programs/net/netkeys.lua` 32, `programs/net/rshd.lua` 38,
  `cell/core.lua` 97, `cell/core_service.lua` 86). `from_hex` three times, which don't agree: `net.lua` takes any even
  length, `netkeys.lua` wants 64 digits. `read_table` and `write_table` five times (`net.lua`, `rshd.lua`,
  `netkeys.lua`, `cellcore.lua`, `core_service.lua`), and the same written out in `dhcpd.lua` and `dnsd.lua`, where
  `dhcpd`'s doesn't check that the file opened. The paths `/.net/trust` and `/.net/certificate` are in both `net.lua`
  and `netkeys.lua`.
- **Change:** `cc.internal.net.files` with `hex.encode`, `hex.decode(text, length)`, `read_table`, `write_table` and
  the paths. **Small to medium.**

### 2.2 One send loop for control connections

- **Copies:** "an outbox, a task which sends from it, and a loop which receives" is written five times:
  `cell/cell_service.lua` 122, `cell/core_service.lua` 422, 499, 617 and 764.
- **Change:** `tasks.lua` gets `tasks:link(connection, on_message)`, which returns the function to send with and runs
  until the connection ends. **Medium.** `cell_service.lua`'s `run` and `core_service.lua`'s `keep_connecting` are the
  same reconnect loop twice, and can share one too.

### 2.3 One kind of remembered set

- **Copies:** "remember the last N of these, or these for so long" is written nine ways in the cellular layer:
  a list beside a table (`core.lua` 531 and 787, `phone.lua` 448), a count which empties the table when it's full
  (`tower.lua` 232 and 244), times which are swept when one is added (`phone.lua`'s `failed` and `forbidden`,
  `tower.lua`'s `early_confirms`), and an order with a cap (`core.lua` 442). Two of the faults found this time
  (`forbidden` growing without limit) and last time (activations kept for good) were one of these done slightly
  wrong.
- **Change:** `cc.internal.net.recent` with `new(max, lifetime)`, `add`, `get`, `remove` and `count`, which forgets the
  oldest when full and what's too old when asked. **Medium.** The link layer's replay window (`link.lua` 136–145) may
  fit too: see 4.5.

### 2.4 Constants and checks which are written more than once

- **Cellular:** how long a cell may be quiet (`SILENCE`, 4 seconds) is in `cell/phone.lua` 72, `programs/net/cell.lua`
  39 and as a bare `4` in `apis/net.lua` 2166. The signal's four bars are in `cell/bar.lua` 38 and
  `programs/net/cell.lua` 78.
- **The stack:** `is_integer` (`tcp.lua` 75, `rip.lua` 206, `dhcp.lua` 59); `usable(interface)` (`stack.lua` 560,
  `rip.lua` 49); the ephemeral ports (`stack.lua` 63, `tcp.lua` 73); `INFINITY = 16` (`stack.lua` 60, `rip.lua` 27 and
  a bare `16` in `programs/net/route.lua` 44); the link-local network (`dhcp.lua` 42, `net.lua` 535, `address.lua`
  138); whether an address can be a host's (`net.lua` 303–312, `dhcp.lua` 69–73); port 22 (`rsh.lua`, `rshd.lua`); the
  16 KiB chunk (`ncp.lua`, `stream.lua`).
- **The firewall:** the `firewall` program checks a rule's protocol and port, but `net.lua` 214–231 takes whatever is
  in the setting, which may have been edited by hand.
- **Change:** export each from one place, have the phone's `info()` say which cells are fresh rather than leaving
  callers to compare ages, and check firewall rules where they're read. **Small.**

### 2.5 One way to say what a computer is allowed to be

- **Where:** `cell/core_service.lua`: entries in `allowed` have `role`, and since networks' cores may have two,
  `roles` as well, with `has_role` to look in both.
- **Change:** a set of roles only, written to `/.cell/cells` as such, with the old form read as before. **Small.**
  It falls away if 3.1 is done.

### 2.6 Take the cellular API out of `apis/net.lua`

- **Seen:** the file is 2,422 lines, 990 of them cellular (1401–2392): the phone's files and messages, the core's and
  the cell's services, and the manager. The trust store is another hundred. It also reaches into the stack's insides
  (`stack.dhcp_clients`, `stack.forwarding`, `stack.by_modem`).
- **Change:** `cc.internal.net.cell.api` holds what `net.cell` does, and `cc.internal.net.trust` the trust store,
  which `netkeys`, `rshd` and `core_service` then share. `net.lua` puts them together and documents them. Add
  `stack:set_forwarding()` and a way to ask for an interface's DHCP client. **Large** for the cellular part,
  **medium** for the rest.

### 2.7 Split `stack.lua`

- **Seen:** 1,259 lines: interfaces and neighbours (167–542), routes and the firewall (564–734), packets and ICMP
  (736–1027), timers (880–937 and 1029–1050), datagram sockets (1072–1166) and echo (1168–1211).
- **Change:** `timers.lua`, `udp.lua` and `routing.lua`. The first and last are where 4.1 and 4.2 would go, so do them
  together. **Medium.**

### 2.8 `cellcore`'s commands

- **Seen:** nineteen commands, eight of them about other networks (`carry`, `uncarry`, `partner`, `peer`, `unpeer`,
  `numbers`, `roaming`, `peers`), in two lists which describe the same networks from two sides.
- **Change:** one command for another network, such as `cellcore network BETA` to show everything about it, and
  `cellcore network BETA carry|home|messages on|off` to change it. The old commands can stay as other names for a
  while. **Medium**; easiest after 3.1.

### 2.9 Dead exports and loose ends in the stack

- **Seen:** only tests use `message.measure`, `tcp.WINDOW`, `Tasks:count`, `stack.channels` and `noise.public_key`.
  `dhcp.LINK_LOCAL_PREFIX` is exported and unused. `timer_count` isn't set when a stack is made (`stack.lua` 1038).
  `cc.internal.net.message` is imported as `sendable` in `stack.lua` and `tcp.lua`. `net.interfaces()` counts
  neighbours which have expired (`stack.lua` 1219), and `net.neighbours()` doesn't (1240).
- **Change:** say which exports are for tests, set the field, name the import after the module, and count neighbours
  one way. **Small.**

### 2.10 The design document

- **Seen:** `NETWORK_STACK.md` is about 1,800 lines, and mixes the design, what was built, what was decided along
  the way and what each round of testing found. "As built (phase 6)" alone is some 300 lines. Parts of the early
  sections are behind the code: §2's testability example has the old shape of `Stack.new` and `receive`; it mentions
  `netstat -e` and a new `chat`, neither of which exists; it says modules are loaded with `dofile`; the API sketch
  uses `trust = "tofu"` and lower-case error messages; `net.lua` 1226 says a stalled handshake holds `accept` for up
  to 5 seconds, where it's up to 10.
- **Change:** three documents: the design (§1 to §10 and §12, brought up to date), a reference for the cellular
  layer as built (§11), and the testing log (§13's robustness sections). **Medium.**

## 3. Reworks

### 3.1 One connection between two networks' cores

- **Seen:** two cores may hold four connections to each other: each may carry the other's phones (the role `roam`,
  one connection each way), and each may have connected to the other to exchange messages (`peer`, up to two more).
  Each is allowed apart, by key and role. The core service keeps six tables for them (`partners`, `carrying`,
  `peering`, `peer_links`, the partner keys, and `allowed` with `role` and `roles`), three files (`cells`, `roaming`,
  `peers`), and the core keeps `partners`, `partner_keys` and `peers`. A roaming tunnel's packets may come from
  another address than the one the core was reached at, which `open_roam_tunnel` works around by trying every
  partner's key.
- **Why:** this is the part of the cellular layer with the most ways to be half set up: allowed for one role and
  waiting for the other, connected one way and not the other, a prefix known from last time and a connection which
  isn't there. The four faults found between networks so far were all in how these fit together.
- **Change:** one agreement for each other network, with what it covers: whether we carry their phones, whether they
  carry ours (and as home or not), whether we exchange messages, their signing key and their number prefix. One
  secure connection between the two cores, which either may open, carrying all of it, with a field in each message
  saying which service it's for. One step to allow a network, which shows its name, fingerprint and what it asks for.
  One file. **Large**, with the old files read once and written in the new form.

### 3.2 The phone as a state machine

- **Seen:** `cell/phone.lua` is 961 lines. What a phone is doing is spread over `state` and a dozen other fields
  (`handshake`, `attempt`, `secret`, `refusal`, `confirming`, `fast_check`, `candidate`, `reported`, `home_since`,
  `activation`, `finished`, `started`, `searching_since`). Timers are closures which compare `self.attempt` with the
  attempt they were set for. Which cell to use is decided in three places which must agree: `best_cell` (with three
  arguments which change what it means), `other_cell`, and the start of `attach`, and again in `measure` for going
  home and for handovers.
- **Why:** each of the last four changes to selection (other networks, cells which don't answer, partners as home,
  listening before roaming) added a special case to several of these, and three of them needed a second commit to
  fix what the first one missed.
- **Change:** each state gets a table with what belongs to it, made on entering and dropped on leaving, so nothing
  from an attach which is over can be read by the next. One function ranks every cell and network the phone hears:
  own network or as good as home, partner, unknown; less those which failed lately or turned it away; then by
  signal. `attach`, going home and handover each take the best of that list which they may use. **Large.** The storm
  tests (`cell_networks_stress_spec.lua`) and the roaming specs are the safety net for it.

### 3.3 A test harness which uses the services

- **Seen:** `spec/support/cell_network.lua` wires cores to cells, to each other for roaming, to shared cells and to
  peers by calling the core directly (`roam_on`, `share_cell`, `peer_with`), which repeats in the harness what
  `core_service.lua` and `cell_service.lua` do over connections. A core can't be restarted in a test once it has
  agreements, as the wiring points at the old one, so the storm tests leave cores running.
- **Change:** build the harness on the services, over the pipes `cell_service_spec.lua` already has, so tests use
  the same code as the game and can restart anything. **Large.** Easier after 3.1.

### 3.4 Links between dimensions which are kept until something changes

- **Seen:** a link evaluated for an ender modem's packet from another dimension is kept for a minute
  (`ender_cache_ticks`), whatever happens to the terrain. The design asked for "until either end changes".
- **Change:** drop cached links whose ends are in a chunk when a block in it changes, or keep the minute and say so in
  the design. **Medium**, and only worth it if stale links turn out to matter in play.

## 4. Performance

None of these was measured in the game. They're ordered by how often the code runs.

### 4.1 Timers are scanned after every event

- **Where:** `apis/net.lua` 489; `stack.lua` 892–904 (`next_deadline`), 907–937 (`tick`), 1034–1043 (`schedule`).
- **Seen:** timers are a plain set. After each event, a key press included, every timer and every pending neighbour
  lookup is walked twice. Each connection has a keepalive timer and usually one to resend, which is cancelled and
  made again for each acknowledgement (`tcp.lua` 198–204). With 128 connections that's some 300 entries for each
  event.
- **Change:** a heap, or at least the earliest deadline kept up to date by `schedule` and `tick`. **Medium.**

### 4.2 Routes are scanned for every packet

- **Where:** `stack.lua` 585–612 (`route`), 568–577 (`on_link`); `modules/main/cc/net/address.lua` 108–113.
- **Seen:** each packet sent or forwarded walks every route, of which RIP allows 1,024, calling `address.contains`,
  which checks its arguments' types each time. Routes through a gateway walk the interfaces as well.
- **Change:** keep routes longest prefix first and stop at the first match of that length, or remember the answer for
  each destination until routes or addresses change. Use versions of `contains` and `mask` which don't check, inside
  the stack. **Medium.**

### 4.3 What a phone does every second

- **Where:** `cell/common.lua` (`check_sib`), `cell/phone.lua` (`radio`, `hear`).
- **Seen:** for each cell it hears, each second, and each network the cell names which it has a key for, a phone
  checks the cell's certificate (one Ed25519 verification) and then the signature (another). The certificate is the
  same every time.
- **Change:** remember the certificates which checked out, by cell and network, until they expire, and only check
  the signature. That halves the cryptography a phone does, and what the test suite spends in the cellular specs.
  **Small.**

### 4.4 `net.cell.info()` reads three files

- **Where:** `apis/net.lua`, `cell.info` and `read_messages`.
- **Seen:** each call reads and parses the SIM's file, the phone's settings and up to 100 messages. The status bar
  calls it every two seconds and on every phone event, and each menu calls it on every event it gets.
- **Change:** keep the three in memory, and read them again only when this computer wrote them. **Small.**

### 4.5 Smaller ones

- **Numbers:** the core walks every subscriber for each message, to find whose number it is (`cell/core.lua`,
  `has_number`). Keep subscribers by number. **Small.**
- **`dnsd`** reads its zone file and every lease file for each question, prints the zone's errors again each time,
  and fails on a lease with no expiry (`programs/net/dnsd.lua` 18–54). Read them when their modification times
  change. **Small to medium.**
- **The DNS cache** (`apis/net.lua` 70, `dns.lua` 188–191) never drops entries which have expired. **Small.**
- **Encrypted links** (`link.lua` 136–145, **suspected**): a sender of more than 128 frames a second keeps the
  receiver pruning its replay window on every frame. **Small.**

## 5. Tests and tools

### 5.1 Run one spec

- **Seen:** `ComputerTestDelegate` runs every Lua spec: 1,904 tests, about two and a half minutes. There's no way to
  run one file. Every change to the stack this week paid for all of it, each time.
- **Change:** a system property (say `cc.test.spec=cell_roaming`) which `ComputerTestDelegate` passes to `mcfly.lua`,
  to run the spec files whose names match. **Small**, and it pays for itself the same day.

### 5.2 The whole of `:core:test` stalls

- **Seen:** `./gradlew :core:test` with no filter doesn't finish: it stalled each time
  `ComputerThreadTest.testHardAbort` ran alongside a Lua test. Not looked into further. Everything in this plan was
  tested with `--tests '*ComputerTestDelegate*'`.
- **Change:** find out whether the two share a computer thread, and keep them apart. **Medium.**

### 5.3 What a killed test run leaves behind

- **Seen:** a test run which is killed leaves a half-written file under `build/` (`jacoco` or `test-results`), and
  the next run fails with `java.io.EOFException` until those folders are deleted.
- **Seen too:** two Gradle builds at once ran a machine with 15 GB out of memory (each daemon may take 3 GB, plus
  the tests' own processes and the game test server).
- **Change:** say both in the contributing notes. **Small.**

### 5.4 Shared test helpers

- **Seen:** in `test-rom/spec/`, `yield` is defined in 8 specs, `hex` in 7, `count`, `copy` and the list of bad
  values in 6, `wait_until` and `with` in 5, `reaches_server` in 4, and `ip()` in at least 11. `run` and `blocking`
  are almost the same in `tcp_spec.lua` and `secure_spec.lua`, as are `router` and `default_route` in
  `routing_spec.lua` and `robustness_spec.lua`.
- **Change:** `support/net_helpers.lua`. **Small to medium.**

### 5.5 What has no test

- **`net` API:** `apis/net_spec.lua` covers `tcp`, `udp`, `secure`, `cell` and `ping`'s arguments. Nothing covers
  `setAddress`, `setPassphrase`, `resolve`, `host` and `lookup`, `routes` and `reload` (where settings are read and
  RIP is only restarted when its settings changed), capturing frames, `getErrors`, or the trust store.
- **Programs:** none of the fourteen programs which aren't cellular has a spec. 1.4, 1.5 and `dnsd`'s fault in 4.5
  would have been found by one.
- **Modules:** `remote_term` has four tests and none on the size of a batch (1.2); `tasks.lua` is only tested through
  the cellular services.
- **The game:** nothing tests a shared cell, messages between networks or the `wiring` commands in the game. For the
  wiring, a test with a cable across chunks which aren't kept loaded, between two which are, would cover joining,
  saving, `status` and `trace`, none of which has a test. The NeoForge hooks for chunks which stop being fully loaded
  were read, and never run.
- **Checks which couldn't be run** where this was written: Checkstyle and the NeoForge build need dependencies the
  sandbox didn't have. CI should be seen to pass both for the last three commits.

## 6. Not planned here

These are in `NETWORK_STACK.md` as not built yet, and aren't repeated: idle mode and paging, cell broadcast, numbers in
DNS, the SIM PIN, airtime and interference. Nor is anything listed there under "Left as they are": those were looked
at and left on purpose.
