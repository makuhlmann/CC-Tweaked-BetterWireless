<!--
SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers

SPDX-License-Identifier: MPL-2.0
-->

# Network stack: what to improve next

This is a plan, not a record: nothing in it has been done, except the items marked **Done**. It lists what could be
improved, tweaked, reworked or streamlined in the network stack as it stands after the ender modem rework, from reading
the code and from what the robustness tests showed. `NETWORK_STACK.md` says what the stack is and how it was built;
this says what to do to it next.

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
- **Done:** `resolve_number` takes an address as it is, without reading the resolver's settings, and `await` only queues
  `net_done` when the answer comes after it started waiting. A test sends datagrams and checks no `net_done` is left.

### 1.2 `rshd` drops screen updates without saying, and may eat the session's events

- **Where:** `modules/main/cc/internal/net/remote_term.lua` 53–55 and 139–144; `programs/net/rshd.lua` 63–65 and 77–87.
- **Seen:** drawing calls gather in one batch until the session yields, and the result of sending it is ignored. A
  program which prints a few thousand lines without yielding makes a batch over the message limit, which is refused,
  and the client's screen is out of step from then on.
- **Suspected:** when the connection's window is full, `Connection:send` waits with `os.pullEvent()` and drops what it
  pulls. Inside `rshd` those events are the hosted session's, so a `sleep` in a remote program could hang.
- **Change:** send the batch when it passes about 32 KiB (`message.measure` exists for this), check the result, and
  give `rshd` a way to send which keeps the events it pulls for the session. **Medium.**
- **Done:** the remote terminal sends a batch once it's about 32 KiB (counted as `cc.internal.net.message` counts), and
  draws long text in pieces, so no batch is too big to send. `rshd` puts batches in an outbox which a task of its own
  sends from, so waiting for room no longer takes the session's events; while the outbox is full, the session's events
  wait for it, in order. A batch which can't be sent ends the session, rather than leaving the client's screen out of
  step. `rshd_spec.lua` runs a session against `rshd` on the same computer: thousands of lines without a yield, a
  `sleep`, and a client slow to read.

### 1.3 A manual address change queues no event

- **Where:** `apis/net.lua` 292 (DHCP's `on_change`) and 297–315 (`apply`).
- **Seen:** `net_interface` with `"address"` is only queued when DHCP changes an address. `net.setAddress` and
  `ifconfig` change one without it, though the design promises the event.
- **Change:** queue it in `apply`. **Small.**
- **Done:** `apply` queues `net_interface` with `"address"` whenever it changes an interface's address or prefix (not
  when it changes nothing, nor for a modem which is only being added, which says `"up"`). Tested with a pretend wired
  modem.

### 1.4 `ifconfig` saves an address before it's checked

- **Where:** `programs/net/ifconfig.lua` 128–140.
- **Seen:** the setting is saved once the address parses, then `net.setAddress` may still refuse it (a network's own
  address, a broadcast address, loopback). The user sees a Lua error, and the setting stays, logged as a bad address
  at every start.
- **Change:** set the address first, and save only if that worked. **Small.**
- **Done:** `ifconfig` checks the address first (with `address.check_host`, now shared by the net API and DHCP), uses it
  if the interface is there, and saves it only if that worked. `ifconfig_spec.lua` tests it.

### 1.5 `ping` and `traceroute` mishandle bad arguments and bad names

- **Where:** `programs/net/ping.lua` 30; `programs/net/traceroute.lua` 11.
- **Seen:** `ping` looks for a reason starting "Invalid", which nothing returns, so a name which doesn't resolve is
  tried as many times as asked. `traceroute` takes its hop limit with `tonumber`, so text or a number over 255 raises
  an error.
- **Change:** stop on "Name not found" and "No DNS server", and check the hop limit. **Small.**
- **Since:** `ping` was rewritten to ping as Unix systems do (on `net.pinger`). It looks the name up once and stops
  with the reason when that fails, and checks its count. `traceroute`'s half is still to do.
- **Done:** `traceroute` checks its hop limit (a whole number from 1 to 255); it already stopped on a name which doesn't
  resolve. `traceroute_spec.lua` tests both, and a route to the computer itself.

### 1.6 Timeouts and ports are checked in some calls and not others

- **Where:** `apis/net.lua`: `ping` (723–726) checks its timeout fully; `Socket:receive` (788), `Connection:receive`
  (881), `Listener:accept` (949), `tcp.connect` (1019), `lookup` (667) and `secure.connect` (1301–1316) only check the
  type. `udp.open` (839) and `Socket:send` (769) don't check the port at all; `tcp.listen` does.
- **Seen:** `net.lookup("x", math.huge)` raises "Invalid delay inf" from inside the stack.
- **Also:** a datagram socket returns a bare `nil` on a timeout or when closed, where connections return
  `nil, "Timed out"`.
- **Change:** one `check_timeout` and one `is_port`, used everywhere, and the same two results from every `receive`.
  **Small**, though the second is a change of behaviour: `dhcpd`, `dnsd` and `nc` should be checked.
- **Done:** `check_timeout` and `is_port` in `net.lua`, used by every call which takes a timeout or a port
  (`secure.connect` checks its `timeout` option too). A datagram socket's `receive` says `"Timed out"` or `"Socket is
  closed"`, as a connection's does. `dhcpd`, `dnsd` and `nc` wait without a timeout and only look at the first result,
  so nothing changes for them.

### 1.7 The trust store's functions don't agree with each other

- **Where:** `apis/net.lua` 1112–1134 and 1345.
- **Seen:** `trusted()` cleans what it reads, `knownHosts()` returns the file as it is. `fingerprint(key)` hashes text
  which isn't hexadecimal as if it were a key. Any `trust` other than `"certificate"` is taken as the default, also
  ones which are spelling mistakes.
- **Change:** clean both lists the same way, refuse keys which aren't keys, and refuse unknown `trust` values.
  **Small.**
- **Done:** `knownHosts()` leaves out what isn't a name and a key, as `trusted()` does; `fingerprint` raises an error
  for anything which isn't 64 hexadecimal digits (the core's status leaves out a SIM's fingerprint if its key in the
  file isn't one); `secure.connect` refuses a `trust` other than `"certificate"`.

### 1.8 A handler which fails leaves packets queued

- **Where:** `modules/main/cc/internal/net/stack.lua` 763–778 (`deliver`).
- **Seen:** when a handler raises an error, the packets queued behind it stay queued until some later packet arrives
  for this computer.
- **Change:** log the error and carry on through the queue, as `tick` does for timers. **Small.**
- **Done:** `deliver` logs a handler's error and carries on through the queue, as `tick` does for timers. Tested in
  `stack_spec.lua`.

### 1.9 The wiring trace can generate chunks (suspected)

- **Where:** `projects/common/src/main/java/dan200/computercraft/shared/peripheral/modem/wired/UnloadedWiring.java`,
  the trace.
- **Seen:** the trace loads the chunks cables lead into with `level.getChunk`, which generates a chunk which doesn't
  exist yet: up to 4,096 for each run.
- **Change:** only load chunks which exist on disk, and count the others as known and empty. **Small to medium.**
- **Done:** before loading a chunk, the trace reads what's saved of it (`chunkMap.read`, without loading it) and loads
  it only if it was finished (`SerializableChunkData.getChunkStatusFromTag` is `FULL`). One which was never made, or
  never finished (so nobody built in it), counts as known with no wiring. Tested by the game tests running, and not in a
  world yet: nothing tests the trace itself (see 5.5).

### 1.10 Chunks with no wiring are never known (suspected)

- **Where:** the same file: what counts as a chunk which is known.
- **Seen:** a chunk is known if it's loaded or has remembered wiring. A full-block modem at a chunk's edge always has
  a port outwards, so a neighbouring chunk with no wiring counts as unknown for good: `wiring status` over-reports,
  and each `wiring trace` loads those chunks again.
- **Change:** remember chunks which were looked at and had nothing, in the file too (a new version of it). **Medium.**
- **Done:** chunks next to wired ones which turn out to have no wiring (a trace looked, or they unloaded with none) are
  remembered as such, and count as known. They're saved in the wiring file, which is now version 2 (version 1 is still
  read). At each save, those no longer next to any wiring are dropped. File format tested in `UnloadedWiringFileTest`.

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
- **Done:** a save which fails stays pending, and is tried again a minute later; each dimension has its own trace, and
  `wiring status` and `stop` are about the dimension they're run in; reading the file checks every port is in its
  piece's chunk (the file tests' random wiring had ports anywhere, and now doesn't); `acquireReadLock` reads the node's
  network again on each try, so it can't spin; and wiring of a dimension which no longer exists is dropped at the next
  save, with a line in the log.

### 1.12 A phone which names a network its cell doesn't serve

- **Where:** `modules/main/cc/internal/net/cell/tower.lua`, `Tower:link_for`.
- **Seen:** if the cell serves one network, any phone is taken to it, whatever network it named. For a second or so
  after a shared cell loses a core, a phone of that network is attached as a visitor to the other, then notices and
  attaches again.
- **Change:** only fall back to the only network when the phone named none. **Small.**
- **Done:** `link_for` takes a phone which names a network only to that network, and falls back to the only one only for
  a phone which names none (ours always name one). Tested in `cell_sharing_spec.lua`.

### 1.13 Another network's core may introduce itself with no name

- **Where:** `modules/main/cc/internal/net/cell/core_service.lua`, `Service:wait` and `requests.allow`.
- **Seen:** a core which says it wants to carry phones or exchange messages, but gives no usable network name, is
  shown to the administrator without one. If it's allowed, the name it gives the first time it connects after that is
  the one it keeps.
- **Change:** refuse such a hello before it waits, so what the administrator allows always has a name. **Small.**
- **Done:** `serve` refuses a hello for another network's roles which has no network name, before it can wait, with
  "Another network's core must say which network it is." Tested in `cell_service_spec.lua`.

### 1.14 RIP updates can be replayed (suspected)

- **Where:** `modules/main/cc/internal/net/rip.lua` 150 and 230.
- **Seen:** the HMAC covers the routes and nothing else, so a signed update which was overheard can be sent again
  later, to bring back a route which was withdrawn. The design says nobody can inject routes. The comparison is a plain
  `~=`, which takes a different time for different wrong answers.
- **Change:** sign the sender's time too, refuse updates older than the last from that neighbour, and compare with
  `crypto.equals`. **Medium**, and a change to the protocol.
- **Done:** signed updates (now version 2) carry the time they were sent, in milliseconds and never the same twice from
  one router, and the signature covers the routes, that time and the sender's address. A router takes one only if it's
  newer than the last it took from that neighbour and no more than a minute out, and compares signatures with
  `crypto.equals`. Routers with the older ROM and a key can't talk to these: a change to the protocol, as planned.
  Tested in `routing_spec.lua`.

### 1.15 Nothing says which version of a protocol a computer speaks

- **Where:** `cell/common.lua` (`SIB_PREFIX`, `make_sib`), `cell/phone.lua` and `cell/core.lua` (`v = 1` in the
  handshakes' payloads).
- **Seen:** system information changed shape when cells learned to serve several networks. A phone with the older
  ROM (a datapack on one server, say) would hear nothing it can read, and say "Searching" for good. The `v` fields are
  written and never read.
- **Change:** a version number in system information and in the control hello, and a state for the phone which says
  the network is newer than it is. **Medium.**
- **Done:** `common.VERSION` (2, the first version which says so) is in system information, in the hellos cells and
  cores send each other and their answers, and in what a core tells a phone when it attaches (the `v` fields, which were
  always 1 and never read). Whoever is newer knows whether it can talk to the other, so the older side only notes it: a
  phone which heard a newer cell or core lately says so in `net.cell.info().newer`, and while it's searching the status
  bar says "Phone too old", and the menus and `cell` say why; a core logs a newer cell or core, and `celld` shows a
  newer core. Tested in `cell_spec.lua` and `cell_gui_spec.lua`.

### 1.16 The generated files were changed by hand

- **Where:** `projects/common/src/generated/resources/` (`recipe/cable.json`, `lang/en_us.json`).
- **Seen:** the data generator needs the game's assets, which the sandbox the ender modem rework was done in couldn't
  fetch. The two files were edited to match `RecipeProvider` and `LanguageProvider`.
- **Change:** run `./gradlew :fabric:runData` once and commit whatever differs. Have CI run it and fail when the
  output differs from what's committed, if it doesn't already. **Small.**
- **Done:** `./gradlew :common:runData` (which runs both loaders' generators and merges what they make into
  `projects/common/src/generated`; `:fabric:runData` alone writes only to `projects/fabric/build`) makes exactly what's
  committed, so the hand edits were right. CI didn't check this. It now runs that after downloading the game's assets,
  and fails when anything in `projects/common/src/generated` differs.

### 1.17 `cellcore`'s completion doesn't know its newer commands

- **Where:** `startup.lua` 137–140 (`cellcore_commands`).
- **Seen:** `partner`, `numbers`, `peers`, `peer` and `unpeer` aren't in the list, so the shell doesn't complete them,
  alone or after `remote`.
- **Change:** add them. **Small.**
- **Done:** the five commands are in the list, so they complete alone and after `remote`.

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
- **Done:** `cc.internal.net.files` has `hex.encode`, `hex.decode(text, length)`, `hex.is_key`, `read_table`,
  `write_table` (which raises an error naming the file when it can't be opened), and the paths of the trust store, the
  certificate and the known hosts. The net API (which loads it with `dofile`, as it can't use `require` yet), the core
  and its service, `cellcore`, `netkeys`, `rshd` and `dhcpd` use it, and `dhcpd` says when it can't save its leases
  rather than failing. `dnsd` reads its files only when they change (4.5), so keeps its own reading. Tested in
  `files_spec.lua`.

### 2.2 One send loop for control connections

- **Copies:** "an outbox, a task which sends from it, and a loop which receives" is written five times:
  `cell/cell_service.lua` 122, `cell/core_service.lua` 422, 499, 617 and 764.
- **Change:** `tasks.lua` gets `tasks:link(connection, on_message)`, which returns the function to send with and runs
  until the connection ends. **Medium.** `cell_service.lua`'s `run` and `core_service.lua`'s `keep_connecting` are the
  same reconnect loop twice, and can share one too.
- **Done:** `Tasks:sender(connection, wake)` queues messages and sends them from a task of its own, returning the
  function to send with and one to stop. The cell service and the core service (its cells, and the one connection to
  each other network's core) use it: three places, where 3.1 left three of the five. Each keeps its own receive loop, as
  what it does with a message differs. The two reconnect loops (a cell's to each core, and a core's to each other
  network's) stay apart: they differ in what they record of each try and what ends them, and one shared loop would need
  about as many options as it has lines.

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
- **Done:** `cc.internal.net.recent` (`new(max, lifetime, clock)`, `add`, `get`, `remove`, `count`, `each`) forgets the
  oldest when full and what's too old when asked, and is used for the messages a phone has seen, the networks which
  turned it away and the cells which didn't answer, the messages a peer core sent us, and a cell's early confirmations,
  the computers it told it doesn't know, and the networks phones asked for. Two of these behave a little differently: a
  cell keeping early confirmations now forgets the oldest when full, rather than refusing new ones, and every store
  forgets the oldest one at a time, rather than all at once. The core's attaches under way stay as they are (several for
  each key), as does the link layer's replay window (counters, not keys). Tested in `recent_spec.lua`, and by the
  cellular specs.

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
- **Done:** `cc.internal.net.checks` has `is_integer`, `is_port`, `is_protocol` and the port error, used by the net API
  (with `dofile`), TCP, RIP, DHCP and `firewall`; the stack exports `usable`, `INFINITY` and the ephemeral ports, which
  RIP, TCP and `route` use; the address module has the link-local network, which DHCP uses; `remote_term.PORT` is
  `rsh`'s and `rshd`'s port; and `ncp` uses the stream's chunk size. The phone's `info()` says which cells it heard
  lately enough to use (`fresh`), which the `cell` monitor and the net API use rather than comparing ages with their own
  copy of 4 seconds, and the monitor uses the status bar's bars. The net API checks firewall rules as it reads them
  (protocol, port, interface), as `firewall` does, since the setting may have been changed by hand.

### 2.5 One way to say what a computer is allowed to be

- **Where:** `cell/core_service.lua`: entries in `allowed` have `role`, and since networks' cores may have two,
  `roles` as well, with `has_role` to look in both.
- **Change:** a set of roles only, written to `/.cell/cells` as such, with the old form read as before. **Small.**
  It falls away if 3.1 is done.
- **Done:** fell away with 3.1. `allowed` holds cells, administrators and refused computers, one role each, and other
  networks' cores are in the agreements. Entries an older version wrote with `roam` or `peer` stay in `/.cell/cells`
  when it's written, so an older ROM still finds them.

### 2.6 Take the cellular API out of `apis/net.lua`

- **Seen:** the file is 2,422 lines, 990 of them cellular (1401–2392): the phone's files and messages, the core's and
  the cell's services, and the manager. The trust store is another hundred. It also reaches into the stack's insides
  (`stack.dhcp_clients`, `stack.forwarding`, `stack.by_modem`).
- **Change:** `cc.internal.net.cell.api` holds what `net.cell` does, and `cc.internal.net.trust` the trust store,
  which `netkeys`, `rshd` and `core_service` then share. `net.lua` puts them together and documents them. Add
  `stack:set_forwarding()` and a way to ask for an interface's DHCP client. **Large** for the cellular part,
  **medium** for the rest.
- **Done:** `cc.internal.net.cell.api` (912 lines) holds the phone's files and messages, the core's and the cell's
  services and the manager; `net.cell` keeps each function's documentation and argument checks and hands the rest to it,
  in a tail call so errors still blame the caller. `cc.internal.net.trust` holds the trust store, which the net API and
  `netkeys` share; `rshd` and `core_service` turned out not to use it. `dhcp.client`, `dhcp.running`,
  `Stack:set_forwarding` and `Stack:has_modem` stand for what the net API read and wrote of the stack's insides.
  `net.lua` is 1,852 lines, from 2,631 before the cellular part moved.

### 2.7 Split `stack.lua`

- **Seen:** 1,259 lines: interfaces and neighbours (167–542), routes and the firewall (564–734), packets and ICMP
  (736–1027), timers (880–937 and 1029–1050), datagram sockets (1072–1166) and echo (1168–1211).
- **Change:** `timers.lua`, `udp.lua` and `routing.lua`. The first and last are where 4.1 and 4.2 would go, so do them
  together. **Medium.**
- **Done:** `stack.lua` (now about 1,100 lines) keeps interfaces, neighbours, packets, ICMP and echo. Routes and the
  firewall are in `routing.lua`, datagram sockets in `udp.lua` (each gives the stack's class its methods), and timers in
  `timers.lua`. The stack still exports `INFINITY`, `usable` and the ephemeral ports. `Stack:timer_count()` counts the
  timers waiting, which the TCP stress tests use. Done with 4.1 and 4.2.

### 2.8 `cellcore`'s commands

- **Seen:** nineteen commands, eight of them about other networks (`carry`, `uncarry`, `partner`, `peer`, `unpeer`,
  `numbers`, `roaming`, `peers`), in two lists which describe the same networks from two sides.
- **Change:** one command for another network, such as `cellcore network BETA` to show everything about it, and
  `cellcore network BETA carry|home|messages on|off` to change it. The old commands can stay as other names for a
  while. **Medium**; easiest after 3.1.
- **Done:** with 3.1. `cellcore networks` lists the agreements; `cellcore network BETA` shows one, and `cellcore network
  BETA carry|roaming|home|messages on|off`, `core <address>|none` and `forget` change it, saying what the other core's
  administrator needs to allow this one. `carry`, `uncarry`, `partner`, `peer`, `unpeer`, `roaming` and `peers` are
  still there, as other names which change and show agreements.

### 2.9 Dead exports and loose ends in the stack

- **Seen:** only tests use `message.measure`, `tcp.WINDOW`, `Tasks:count`, `stack.channels` and `noise.public_key`.
  `dhcp.LINK_LOCAL_PREFIX` is exported and unused. `timer_count` isn't set when a stack is made (`stack.lua` 1038).
  `cc.internal.net.message` is imported as `sendable` in `stack.lua` and `tcp.lua`. `net.interfaces()` counts
  neighbours which have expired (`stack.lua` 1219), and `net.neighbours()` doesn't (1240).
- **Change:** say which exports are for tests, set the field, name the import after the module, and count neighbours
  one way. **Small.**
- **Done:** the exports only tests use are marked so (`message.measure`, `tcp.WINDOW`, `Tasks:count`, `stack.channels`,
  `noise.public_key`); `dhcp.LINK_LOCAL_PREFIX` is gone (the address module has it, 2.4); `timer_count` is set when a
  stack is made; the message module is imported as `net_message`; and `interface_info` counts only neighbours which
  haven't expired, as `neighbour_info` lists them. Tested in `stack_spec.lua`.

### 2.10 The design document

- **Seen:** `NETWORK_STACK.md` is about 1,800 lines, and mixes the design, what was built, what was decided along
  the way and what each round of testing found. "As built (phase 6)" alone is some 300 lines. Parts of the early
  sections are behind the code: §2's testability example has the old shape of `Stack.new` and `receive`; it mentions
  `netstat -e` and a new `chat`, neither of which exists; it says modules are loaded with `dofile`; the API sketch
  uses `trust = "tofu"` and lower-case error messages; `net.lua` 1226 says a stalled handshake holds `accept` for up
  to 5 seconds, where it's up to 10.
- **Change:** three documents: the design (§1 to §10 and §12, brought up to date), a reference for the cellular
  layer as built (§11), and the testing log (§13's robustness sections). **Medium.**
- **Done:** `NETWORK_STACK.md` (1,084 lines) keeps the design, §1 to §10 and §12, with a summary of §11 and §13's
  account of how the stack is tested. `NETWORK_CELLULAR.md` is the cellular layer, as asked for and as built, and
  `NETWORK_TESTING.md` what each round of testing found, and what stalled the test suite. The passages behind the code
  were brought up to date: `Stack.new`'s example, `netstat` and `chat` (gone), how modules are loaded, the API sketch's
  trust options and error messages, and `net.secure`'s `accept`, which a stalled handshake holds up for up to 10 seconds
  (5 for each of the client's two messages).

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
  isn't there.
- **Change:** one agreement for each other network, with what it covers: whether we carry their phones, whether they
  carry ours (and as home or not), whether we exchange messages, their signing key and their number prefix. One
  secure connection between the two cores, which either may open, carrying all of it, with a field in each message
  saying which service it's for. One step to allow a network, which shows its name, fingerprint and what it asks for.
  One file. **Large**, with the old files read once and written in the new form.
- **Done:** one agreement for each other network (`cc.internal.net.cell.networks`, kept in `/.cell/networks`): the other
  core's key, ID and signing key, its number prefix, where its core is, and whether we carry its phones, whether ours
  may use its cells (as roaming or as home), and whether the two exchange messages. One secure connection between the
  two cores (the role `network`) carries all of it, opened by whichever core knows where the other is; if both connect
  at once, both keep the one opened by the core with the smaller key. Each core's hello says what it does for the other,
  and each message after says what it's for (`s`: `home`, `visited`, `messages`, `tunnel`, `prefix`). Another network's
  core waits once, showing its name, fingerprint and what it offers, and allowing it makes the agreement, accepting the
  offer; the core which connects keeps the other's key from the first time. A new number prefix goes over the
  connection, which stays, so roaming phones keep their service; a link is only made again if messages could start now.
  The core service keeps `links` and `dialing` where it had six tables; the core is as it was, but for `open_uplink`,
  which tries the partner towers' keys when a tunnel's packet comes from an address it doesn't know (as
  `open_roam_tunnel` does the other way). The cellular protocol is version 3, and both cores need it: an older core's
  `roam` and `peer` connections aren't understood. The older files (`cells` with `roam` and `peer`, `roaming`, `peers`)
  are read once, when there's no `networks`, and left as they were, so going back to an older ROM still finds them.
  Tested in `cell_service_spec.lua` (agreeing, everything over one connection, a prefix changing under it, both cores
  connecting at once, older files, refusals, odd requests), `cell_agreements_spec.lua` (two worlds' files, word for
  word), `cell_roaming_spec.lua` (a home core which reached the visited one at another address than it sends from), and
  the roaming game test. The test harness still wires cores to each other directly: that's 3.3.

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
- **Done:** the phone is in one state at a time (`inactive`, `activating`, `searching`, `attaching`, `attached`,
  `rejected`), each with a table of what belongs to it (`here`), made by `Phone:enter` and dropped on leaving: the
  attach's handshake, secret and refusal; while attached, the cell's key, whether it still knows us, a handover
  candidate and how long home has been stronger; the activation and the try under way. Timers check the table is still
  the phone's, rather than an attempt token. A search (`search`) lasts from losing service (or starting, or being
  activated) through every attach which doesn't work until the phone is attached, and keeps when it started, how long to
  wait before trying again, and the last refusal. What comes from the cell goes to a handler for the state and message
  (`from_cell`), so a message for another state can't be acted on. One function (`Phone:best`, ordered by `before`)
  ranks every way to use a cell the phone hears: own network or as good as home, then partners, then networks it doesn't
  know to carry it, then cells which didn't answer lately (by class, then signal); within each, the strongest.
  Attaching, going home and handovers each take the best they may use. The one change in behaviour: a handover now goes
  to a cell which will do before a stronger one which didn't answer an attach lately (it went to the strongest before),
  pinned in `cell_spec.lua`. `phone.cell`, `via` and `rejected` stay for whoever looks, set as the state changes;
  nothing in the phone decides by them. The storm specs take as long as before (about 3 seconds each, alone): a first
  version which made a list of every cell each second was four times slower, so the ranking is one pass which only looks
  at other networks when nothing better will do. Activation still picks its cells its own way, as it has no operator to
  rank them by.

### 3.3 A test harness which uses the services

- **Seen:** `spec/support/cell_network.lua` wires cores to cells, to each other for roaming, to shared cells and to
  peers by calling the core directly (`roam_on`, `share_cell`, `peer_with`), which repeats in the harness what
  `core_service.lua` and `cell_service.lua` do over connections. A core can't be restarted in a test once it has
  agreements, as the wiring points at the old one, so the storm tests leave cores running.
- **Change:** build the harness on the services, over the pipes `cell_service_spec.lua` already has, so tests use
  the same code as the game and can restart anything. **Large.** Easier after 3.1.
- **Done:** each core in `spec/support/cell_network.lua` runs `core_service`, with its files in a folder of its own, and
  each cell runs `cell_service`, building its tower as the net API does (one tower, a network added for each core). They
  connect over pipes (`support/pipe.lua`, lifted from `cell_service_spec.lua`, which now uses it too), which deliver
  after 0.01 seconds as the old wiring did, and a relay's cell connects over TCP through its own phone. The services run
  as the network stack's background process would: each is resumed when something it waits for may have changed (a
  message, a close, a timer), once however many things did, so the virtual network still only moves from one thing to
  the next. `roam_on`, `peer_with` and the new `agree` set agreements as `cellcore network` does, and `share_cell` has
  the cell join the other core too; `cut()` stops the two cores reaching each other, which now ends roaming between them
  as well as messages, as one connection carries both. Services' errors go into `net.errors`. Anything can be restarted:
  "comes back by itself when either core restarts" no longer wires roaming again by hand, "ends when the agreement does"
  changes the agreements rather than the cores' tables, and a new test restarts both cores with roaming both ways, a
  shared cell and messages, and everything comes back with nothing set up again. Three tests waited on timing which the
  services change slightly (a cell joins its core a few hundredths of a second after it's made), and now wait for what
  they meant to. The storm specs take about 20% longer (3 to 4 seconds each, alone). A core keeps the messages it holds
  in memory only, so a restart loses them: the message storm doesn't restart cores for that reason.

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
- **Done:** timers are a heap (`timers.lua`), ordered by when they're due and then the order they were set, so the next
  deadline is found at once. A cancelled timer stays until it comes up, and the heap is made again without them once
  they outnumber the others. Timers set while others run still wait for the next tick. Pending neighbour lookups are
  still walked, but there are at most 64 of them on an interface. Tested in `timers_spec.lua`, and by the TCP stress
  tests, which count the timers left.

### 4.2 Routes are scanned for every packet

- **Where:** `stack.lua` 585–612 (`route`), 568–577 (`on_link`); `modules/main/cc/net/address.lua` 108–113.
- **Seen:** each packet sent or forwarded walks every route, of which RIP allows 1,024, calling `address.contains`,
  which checks its arguments' types each time. Routes through a gateway walk the interfaces as well.
- **Change:** keep routes longest prefix first and stop at the first match of that length, or remember the answer for
  each destination until routes or addresses change. Use versions of `contains` and `mask` which don't check, inside
  the stack. **Medium.**
- **Done:** routes are kept longest prefix first (prefixes never change once added, though RIP changes metrics in place,
  so the order holds), and a lookup stops once the routes left can't match more of the address. Matching is one AND with
  the prefix's mask and a compare, rather than `address.contains` with its argument checks. Remembering the answer for
  each destination was left out: it would have to be forgotten wherever RIP changes a route in place. Tested in
  `routing_spec.lua`.

### 4.3 What a phone does every second

- **Where:** `cell/common.lua` (`check_sib`), `cell/phone.lua` (`radio`, `hear`).
- **Seen:** for each cell it hears, each second, and each network the cell names which it has a key for, a phone
  checks the cell's certificate (one Ed25519 verification) and then the signature (another). The certificate is the
  same every time.
- **Change:** remember the certificates which checked out, by cell and network, until they expire, and only check
  the signature. That halves the cryptography a phone does, and what the test suite spends in the cellular specs.
  **Small.**
- **Done:** `check_sib` takes a store of certificates which checked out (`common.new_certificates()`), by network, cell,
  operator key and the certificate itself, and checks one again only once it has expired. Each phone has one, of up to
  256. A cell's system information then costs one signature to check rather than two. Tested in `cell_spec.lua`,
  counting the signatures checked.

### 4.4 `net.cell.info()` reads three files

- **Where:** `apis/net.lua`, `cell.info` and `read_messages`.
- **Seen:** each call reads and parses the SIM's file, the phone's settings and up to 100 messages. The status bar
  calls it every two seconds and on every phone event, and each menu calls it on every event it gets.
- **Change:** keep the three in memory, and read them again only when this computer wrote them. **Small.**
- **Done:** `net.cell.info` keeps what it read of the SIM's file, the phone's settings and the count of unread messages,
  and reads a file again only once its modification time or size has changed; writes through the net API forget it at
  once. Tested in `net_spec.lua`, with files changed by another program.

### 4.5 Smaller ones

- **Numbers:** the core walks every subscriber for each message, to find whose number it is (`cell/core.lua`,
  `has_number`). Keep subscribers by number. **Small.**
- **`dnsd`** reads its zone file and every lease file for each question, prints the zone's errors again each time,
  and fails on a lease with no expiry (`programs/net/dnsd.lua` 18–54). Read them when their modification times
  change. **Small to medium.**
- **The DNS cache** (`apis/net.lua` 70, `dns.lua` 188–191) never drops entries which have expired. **Small.**
- **Encrypted links** (`link.lua` 136–145, **suspected**): a sender of more than 128 frames a second keeps the
  receiver pruning its replay window on every frame. **Small.**
- **Done:** the core keeps its subscribers' SIMs by number (made again whenever the subscribers change, which the core
  service says after every change), and delivers each message with that; `dnsd` reads its zone file and each file of
  leases again only when it changes, says what's wrong with the zone file once, and passes by leases without a name or
  expiry (and folders); the DNS cache forgets expired answers whenever it keeps a new name, and keeps 256 at most; and
  an encrypted link which has many recent frames from a busy sender waits for twice as many before pruning them again.
  Tested in `dns_spec.lua` and the new `dnsd_spec.lua`; the numbers by the messaging specs.

## 5. Tests and tools

### 5.1 Run one spec

- **Seen:** `ComputerTestDelegate` runs every Lua spec: 1,904 tests, about two and a half minutes. There's no way to
  run one file. Every change to the Lua stack pays for all of it, each time.
- **Change:** a system property (say `cc.test.spec=cell_roaming`) which `ComputerTestDelegate` passes to `mcfly.lua`,
  to run the spec files whose names match. **Small**, and it pays for itself the same day.
- **Done:** `-Pcc.test.spec=cell_roaming,stack` runs the spec files whose paths contain any of the words given (see
  `CONTRIBUTING.md`). Two specs take about thirty seconds, most of it Gradle starting.

### 5.2 The whole of `:core:test` stalls

- **Seen:** `./gradlew :core:test` with no filter doesn't finish: it stalled each time
  `ComputerThreadTest.testHardAbort` ran alongside a Lua test. Not looked into further. Everything in this plan was
  tested with `--tests '*ComputerTestDelegate*'`.
- **Change:** find out whether the two share a computer thread, and keep them apart. **Medium.**
- **Done:** they share nothing: each `ComputerThreadTest` makes its own computer thread (its "Terminating computer #0"
  is about its own computer, which has the same ID as the Lua tests'). It only adds load. The stall was the test
  delegate and `mcfly` falling out of step: when a Lua test runs past its ten seconds, the delegate gives up and asks
  for the next with a `cct_test_run` event, which the test, still waiting for something, took and dropped. Every test
  after then waited ten seconds for an event which never came. `mcfly` now runs each test in a coroutine of its own
  and passes it the events it waits for, but a `cct_test_run` ends it, so only the test which ran on fails.
- **Still open:** the storm tests in `cell_networks_stress_spec.lua` take ten to eleven seconds each on a machine which
  is busy, against the delegate's limit of ten, so they fail there. They could be shorter again, or the limit longer.
  (Alone, they now take three to four seconds each.)
- **Later:** the suite still stalled now and then, and twice cascaded for half an hour. `mcfly` now prints where a test
  it ends was waiting, which showed the cause: a test waiting for the event its yield helper had just queued, which
  never came. A computer's queue holds 256 events and drops one queued while it's full, and something on the test
  computer fills it now and then (the real network stack, which the BIOS runs beside every test, queues an event each
  time it wakes, but this isn't confirmed). The network specs share one helper, `support/yield.lua`, which queues its
  event again once more than a full queue's worth of others have come first, and prints which events those were, the
  first time; `mcfly`'s wait for the start of each test does the same, and runs the next test asked for if it comes
  first. The delegate shows the computer's screen with the first three tests which time out, and once three in a row
  have, fails the rest at once rather than waiting ten seconds for each.
- **Found:** the timers were the network stack's own. `net.run`, which the BIOS runs beside the shell, started a timer
  for the stack's next deadline, and took one which was a second overdue to be lost and started another, without
  cancelling it and still taking the deadline as when it would fire. Once a test had kept the computer busy for over a
  second, every event, those timers included, started another, and only the newest would run the stack, so they
  multiplied until the queue was full: 716,065 timers in one run of the suite. It now keeps one timer, with when it
  will fire, and cancels any it replaces: 10 in the whole of `net_spec.lua`, and a test in it which kept the computer
  busy starts 1,001 with the old loop. Under the test delegate, `mcfly` notes where each timer was started, which
  `support/yield.lua` prints with a full queue, and writes how many each place and each test started to `/timers.txt`.

### 5.3 What a killed test run leaves behind

- **Seen:** a test run which is killed leaves a half-written file under `build/` (`jacoco` or `test-results`), and
  the next run fails with `java.io.EOFException` until those folders are deleted.
- **Seen too:** two Gradle builds at once ran a machine with 15 GB out of memory (each daemon may take 3 GB, plus
  the tests' own processes and the game test server).
- **Change:** say both in the contributing notes. **Small.**
- **Done:** both are in `CONTRIBUTING.md`, with how to run some of the specs, and that the slow ones need a machine
  which isn't busy.

### 5.4 Shared test helpers

- **Seen:** in `test-rom/spec/`, `yield` is defined in 8 specs, `hex` in 7, `count`, `copy` and the list of bad
  values in 6, `wait_until` and `with` in 5, `reaches_server` in 4, and `ip()` in at least 11. `run` and `blocking`
  are almost the same in `tcp_spec.lua` and `secure_spec.lua`, as are `router` and `default_route` in
  `routing_spec.lua` and `robustness_spec.lua`.
- **Change:** `support/net_helpers.lua`. **Small to medium.**
- **Done:** `spec/support/net_helpers.lua` has `ip` (which 17 specs had), `hex`, `unhex`, `copy`, `count`, `with` (and
  its `NIL`, for a setting to clear), the odd values to feed what's tested (one core list, to which a spec adds its own,
  so the link and secure fuzzers now try a far too long string too), `reaches_server`, `wait_until`, `run` and
  `blocking` (the TCP and secure specs' near copies), `router` and `default_route`, and the pretend enclave the secure
  tests used. `support/yield.lua` has the one `yield`. The sealed-message tests, which skip the table which contains
  itself, find it by `RECURSIVE` rather than by its place in the list.

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
- **Done:** `net_spec.lua` covers `setPassphrase` (what's sent is sealed while there's one), `routes` and `reload`
  (connected routes, and configured ones once they're applied), `capture`, `getHostname`, `resolve` (addresses,
  `net.hosts` and this computer's own name), `unhost`, `getErrors` and `trusted`; `host` and `lookup` are covered by
  `dns_spec.lua`, which finds services as `net.lookup` does. `route`, `firewall`, `nslookup` and `netkeys` have specs,
  and `tasks.lua` has its own. **Not done:** specs for `nc`, `ncp`, `rsh`, `netdump` and `dhcpd`, and the game tests (a
  shared cell, messages between networks, and wiring across chunks which aren't kept loaded).

## 6. Not planned here

These are in `NETWORK_STACK.md` as not built yet, and aren't repeated: idle mode and paging, cell broadcast, numbers in
DNS, the SIM PIN, airtime and interference. Nor is anything listed there under "Left as they are": those were looked
at and left on purpose.
