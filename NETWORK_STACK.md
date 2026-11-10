<!--
SPDX-FileCopyrightText: 2026 The CC: Tweaked Developers

SPDX-License-Identifier: MPL-2.0
-->

# A network stack for CC: Tweaked

Rednet gives computers a way to send Lua values to each other by ID, but nothing more: no routing, no reliable delivery,
no address assignment, and no security. This document designs a layered network stack to replace it, loosely modelled
on the internet's protocols, and a cellular layer that carries it over the radio model on this branch.

The protocols are named after the ones they imitate (UDP, TCP, ICMP, DHCP, DNS), because that makes them easier to
learn and reason about. None of them is wire-compatible with the real thing, and all of them are much simpler.

1. [What CC gives us](#1-what-cc-gives-us)
2. [Architecture](#2-architecture)
3. [Addressing](#3-addressing)
4. [Link layer](#4-link-layer)
5. [Network layer and ICMP](#5-network-layer-and-icmp)
6. [Routing](#6-routing)
7. [Transport: datagrams and connections](#7-transport-datagrams-and-connections)
8. [DHCP and DNS](#8-dhcp-and-dns)
9. [Security](#9-security)
10. [The Lua API, settings and tools](#10-the-lua-api-settings-and-tools)
11. [Cellular networks](#11-cellular-networks)
12. [Changes to the mod](#12-changes-to-the-mod)
13. [Testing](#13-testing)
14. [Implementation plan](#14-implementation-plan)
15. [Decisions and open questions](#15-decisions-and-open-questions)

**Goals:** computers on different networks can reach each other through routers; programs get both fire-and-forget
datagrams and reliable connections; a new computer joins a network with no setup; traffic can be encrypted and
authenticated; phones keep their connections while moving between cells.

**Non-goals:** compatibility with rednet, real-world wire formats, or performance beyond what a few dozen computers
need. The stack should stay small enough to read: it runs in Lua, and players should be able to learn from it.

## 1. What CC gives us

These facts about CC: Tweaked (as of 1.121.0, on this branch) shape the design:

| Fact | Consequence |
|---|---|
| A modem sends a Lua value on one of 65,536 channels to every modem in range that has that channel open. Functions and metatables are dropped. | The physical layer is a broadcast medium carrying Lua values, not bytes. Channels only filter what wakes a computer up. |
| A modem can have at most 128 channels open. | Each computer can only listen on a few channels, so addresses can't map one-to-one to channels. |
| `modem_message` gives the side, channel, reply channel, message and distance, and on this branch the signal strength in dBm for radio messages. | Link quality is visible to the stack and can feed routing and cell selection. |
| On this branch, channels 0–1023 use the low band (150 MHz, long range) and 1024–65532 the high band (2.4 GHz, short range). 65533–65535 are reserved for rednet and GPS. | Which channel the stack uses decides how far it reaches. Wired modems ignore bands. |
| Radio messages arrive at the next server tick. Wired messages arrive immediately. Ender modems hear everything, in every dimension. | Each radio hop takes at least 50 ms. Timers should be measured in ticks. |
| Anyone can open any channel, and the sender of a message is whatever the message says. | Without cryptography there is no privacy and no authentication. |
| Each computer's event queue holds 256 events. Further events are silently dropped. | A flood of messages loses some of them. The stack must keep its queue short and treat drops as loss. |
| `bios.lua` runs `rednet.run` in parallel with the shell, and every coroutine under `parallel` sees every event. | The stack can run its background process the same way. Apps must ignore events that aren't theirs. |
| `require` gives each program its own copy of a module, and isn't available to APIs. Files in `rom/apis` are loaded once at boot, in alphabetical order, into globals shared by all programs. | The stack's state must live in a global API (`net`), like rednet, not in a `require`d module. `net.lua` loads before `parallel`, `peripheral`, `rednet` and `settings` exist. |
| Computers, turtles and pocket computers share one ID space, unique within a world. | Computer IDs make good hardware addresses. |
| Lua strings are byte strings. Java functions can take and return them (`IArguments.getBytes`, `ByteBuffer`). Cobalt has `string.pack` and `bit32`. | A native crypto API can work on raw bytes, and binary encodings are possible in Lua. |
| Datapacks can add files to the ROM (`data/computercraft/lua/rom/...`). | The stack can be developed as a datapack without rebuilding the jar, then moved into the ROM. |

## 2. Architecture

| Layer | Imitates | Responsibility |
|---|---|---|
| Applications | | `ping`, `nslookup`, file transfer, remote shell, cellular services |
| Security | TLS, Noise | Encrypted, authenticated sessions; key management |
| Transport | UDP, TCP | Ports; datagrams; reliable, ordered connections |
| Configuration | DHCP, DNS | Addresses, gateways and names without manual setup |
| Network | IPv4, ICMP | Addresses, forwarding, TTL, error reports, ping |
| Routing | RIP | Routers learning routes from each other |
| Link | Ethernet, ARP | Frames between computers that can hear each other directly |
| Physical | | Modems: wired, wireless (two bands), ender |

The cellular layer (§11) is another kind of link: it gets a phone's packets to a tower and through the operator's
network.

### Process model

The stack is a global API, `net`, loaded from `rom/apis/net.lua` like rednet, so every program on the computer shares
one instance. APIs load in alphabetical order, before `settings`, `peripheral` and the rest exist, so the file's top
level only defines functions. All setup happens when `net.run` starts: defining settings, finding modems, and loading
the internal modules with `dofile` (APIs can't use `require`). `bios.lua` runs that background process next to the
shell:

```lua
parallel.waitForAny(shell, rednet.run, net.run)
```

The background process only handles input: `modem_message` events, its own timers, and modems being attached or
removed. Sending happens directly in the calling program's coroutine, through the shared state. That is safe because CC
coroutines only switch when they yield, and `modem.transmit` doesn't. The send path must never call anything that does,
such as `sleep` or a peripheral method that runs on the main thread.

To be robust:

- Each event handler runs under `pcall`. Errors go to a log ring buffer (shown by `netstat -e`) and the stack keeps
  running. This is essential: if `net.run` ever returns or errors, `parallel.waitForAny` returns and `bios.lua` shuts
  the computer down. The outer loop itself must not be able to fail.
- The stack keeps one OS timer for its earliest deadline (retransmissions, leases, routing updates) instead of one per
  packet, so it doesn't flood the event queue.
- Programs waiting on the network are woken by events the background process queues (`net_data` and so on). These are
  coalesced, at most one pending per socket.
- Buffers are bounded: a few dozen datagrams per socket, and a connection's receive window. A sender that ignores this
  loses datagrams, which is no different from a real network.
- It ignores `terminate`, so pressing Ctrl+T in a program doesn't kill the network.

### Testability

The protocol logic is a `Stack` object with its inputs and outputs injected:

```lua
local stack = Stack.new {
    id = os.getComputerID(),
    clock = os.clock,                      -- seconds, advancing per tick
    transmit = function(interface, channel, frame) ... end,
    wake = os.queueEvent,
    settings = settings,
}
stack:receive(interface, channel, frame, distance, signal)
stack:tick()                               -- run any timers that are due
```

`net.run` is a thin driver around this. Tests can create many stacks in one Lua VM and connect them with fake links that
drop, delay, duplicate or reorder frames (§13).

## 3. Addressing

### Why not computer IDs?

Computer IDs are unique and permanent, which makes them good **hardware addresses**, like Ethernet MAC addresses. They
are poor **network addresses**:

- **They're flat.** A router would need a route for every computer it can reach. Addresses that share a prefix can be
  routed as a group: one route covers a whole base or cell.
- **A router needs several.** It has one interface per modem, and each interface belongs to a different network.
- **They can't follow a phone.** An ID says nothing about where a computer is, so a moving phone can't be routed to by
  its ID alone.
- **They identify hardware.** Replacing a broken server computer would change its address.

### Two levels

- **Link addresses** are computer IDs. They're only used between computers that can hear each other directly.
- **Network addresses** are 32-bit numbers, written like IPv4 (`10.4.0.17`) with a prefix length (`10.4.0.17/24`). They
  are assigned by DHCP or set by hand, and an interface can have one per network it's on.

In packets, addresses are plain Lua numbers (exact up to 2^53), so masking is `bit32.band`. Programs see dotted
strings.

| Address | Meaning |
|---|---|
| `0.0.0.0` | Unspecified: the source of a DHCP request before the computer has an address |
| `255.255.255.255` | Broadcast to everything on this link. Never forwarded. |
| The last address of a subnet | Broadcast to that subnet |
| `127.0.0.0/8` | This computer (loopback) |
| `169.254.0.0/16` | Link-local addresses a computer gives itself when there is no DHCP server (§8) |

Everything else is usable. With no real internet to collide with, all of `10.0.0.0/8` is free. On multiplayer servers,
players agree among themselves who uses which prefix, for example one `10.N.0.0/16` per player or group (256 subnets of
254 computers each). The stack doesn't enforce this.

An alternative is IPv6-style automatic addresses: the router advertises a prefix, and the computer ID fills in the host
part, so addresses can never clash. It's elegant, but less familiar, and it ties addresses to hardware again. The design
uses it only for link-local addresses: `169.254.(1 + ⌊id / 256⌋ mod 254).(id mod 256)`, checked for conflicts. After a
clash, the computer tries random link-local addresses instead.

### Names

On top of addresses, DNS (§8) maps names like `bank.spawn` to addresses, and services like `chat` to the computers that
offer them. Names ending in `.local` are resolved by asking the local network, with no server, as `rednet.lookup` does
today.

## 4. Link layer

### Interfaces

An interface is a modem on one band:

- **Wired modems** are one interface, named after the peripheral (`back`).
- **Wireless modems** are one interface on their configured band, by default the high band (short range, like Wi-Fi).
  The same modem can also be a second interface on the other band (`top:low`), so one modem can serve both a local
  network and a long-range link.
- **Ender modems** currently reach everything, in every dimension. After their rework (§12) they are weak radios whose
  signal also appears in other dimensions. Either way the stack needs to recognise them, but from Lua they look like
  any other wireless modem: all three kinds of modem have the peripheral type `modem`, wired ones add `peripheral_hub`,
  and `isWireless()` is true for both wireless and ender modems. So the mod adds `modem.isInterdimensional()` (§12).

Interfaces come and go as modems are attached and removed, and the stack reports this with a `net_interface` event.

### Channels

Each interface listens on a broadcast channel and a unicast channel derived from its computer ID. Unicast channels are
only a filter: several computers may share one, and frames carry the real destination ID.

| Band | Unicast channel | Broadcast channel | Reserved |
|---|---|---|---|
| Low | `id mod 1000` (0–999) | 1000 | 1001–1007 for cellular control (§11) |
| High, and wired | `1024 + id mod 60000` (1024–61023) | 61024 | |

Rednet listens on `id mod 65500`, which can land on another computer's unicast channel here. Each side ignores the
other's messages, so this only costs the odd wasted wakeup. Channels 1008–1023 and 61025–65532 are left for other
programs. The ranges are fixed for now; settings to move them could
be added if a server's programs conflict. Frames always carry a version field, so the stack ignores anything that isn't its own.

### Frames

A frame is the Lua table passed to `modem.transmit`:

```lua
{
    net = 1,          -- version; anything without it isn't ours
    src = 17,         -- sender's computer ID
    dst = 42,         -- receiver's computer ID, or -1 for broadcast
    type = "ip",      -- "ip", "nd" (neighbour discovery), or "cell" (§11)
    body = { ... },   -- the packet
}
```

The reply channel is set to the sender's unicast channel. On receipt, the stack drops frames that aren't for it, and
remembers the signal strength of radio frames per neighbour.

### Neighbour discovery

To send a packet to a network address on the same link, the stack needs that computer's ID. This is ARP:

- `{op = "who", addr = A}` is broadcast. The computer with address `A` replies `{op = "is", addr = A}` directly.
- Answers are cached for five minutes, along with the interface and last signal strength. The cache is also filled
  passively from packets received, but not from packets a router forwarded, whose sender is elsewhere. Routers mark
  those frames. The cache holds at most 512 computers per interface, and at most 64 are looked for at once.
- A computer announces a newly configured address with an unsolicited `is`. If another computer already has the
  address, it answers with an `is` of its own, and the newcomer marks the address as a duplicate and doesn't use it. A
  computer that has had its address for more than 3 seconds keeps it when someone else claims it. It defends the
  address with another `is`, at most once a second, so one computer can't take another's address away. A DHCP client
  whose new address turns out to be taken declines it, and asks for another.

### Wireless links aren't fully connected

On a wired network everyone hears everyone. On a radio network two computers can both hear a tower but not each other.
So a wireless interface works in one of three modes:

- **Station**, when a DHCP server on the link says so: everything goes through the gateway, which relays between its
  clients, as a Wi-Fi access point does. This is how cellular phones and most wireless clients work.
- **Access point**, on a router serving a wireless link: it relays between stations on the same interface.
- **Ad hoc**, when there is no router: everything in the subnet is assumed reachable directly, and neighbour discovery
  finds out whether it is.

## 5. Network layer and ICMP

### Packets

```lua
{
    v = 1,
    src = 167772177,  -- 10.0.0.17
    dst = 167772165,  -- 10.0.0.5
    ttl = 32,
    proto = "udp",    -- "udp", "tcp" or "icmp"
    id = 4711,        -- for matching error reports
    body = { ... },
}
```

There is no checksum, since modems never corrupt messages; integrity is the security layer's job. There is no size
limit or fragmentation either, as modem messages can be any size. That changes if the mod gains a wireless message size
limit (§12).

### Forwarding

When a packet arrives, or a program sends one:

1. If `dst` is one of this computer's addresses or a broadcast address, deliver it locally by protocol. An unknown
   protocol gets an ICMP "protocol unreachable".
2. Otherwise, drop it unless this computer is a router (`net.forwarding`).
3. Decrement the TTL. At zero, drop it and send ICMP "time exceeded".
4. Find the route with the longest matching prefix, then the lowest metric. With no route, send ICMP "network
   unreachable".
5. Find the next hop's computer ID with neighbour discovery, and send the frame on the route's interface.

Packets waiting for neighbour discovery are queued briefly, a few per destination, and dropped with "host unreachable"
if three questions, a second apart, go unanswered.

A router reports "time exceeded" and "network unreachable" from the address of the interface the packet arrived on,
which is the address `traceroute` shows for that hop.

### ICMP

ICMP messages are packets with `proto = "icmp"`:

| Type | Use |
|---|---|
| `echo`, `echo_reply` | `ping` |
| `unreachable` with code `net`, `host`, `port`, `proto` or `admin` | Reporting why a packet couldn't be delivered (`admin` means a firewall rule) |
| `time_exceeded` | TTL ran out. `traceroute` relies on this. |
| `redirect` | A router telling a host there's a better first hop on the same link. Not implemented yet. |

Error messages carry the original packet's header (addresses, protocol, ID and ports), so the sender can tell which
packet failed. They are never sent about other ICMP errors or about broadcasts, and are limited to two per second per
destination to avoid storms.

## 6. Routing

### Routing table

| Field | Meaning |
|---|---|
| prefix, length | The destinations this route covers |
| next hop | A router's address, or none for a directly connected network |
| interface | Where to send |
| metric | Cost; lower is better |
| source | `connected`, `static`, `dhcp`, or `rip`, with an expiry time for learned routes |

A host has routes for the networks its interfaces are on, plus a default route (`0.0.0.0/0`) through the gateway from
DHCP or settings. Static routes can be added in settings, for example `"10.5.0.0/16 via 10.4.0.1"`.

### Routers

A router is a computer with forwarding on and usually several modems, for example a wired modem on a base's network and
a wireless one towards the next base. Routers can also filter: a list of rules (`net.firewall`, edited with the
`firewall` program), each matching source and destination networks, protocol, destination port and the interface a
packet arrived on, that allow or reject with ICMP "admin" (shown as "Prohibited"). The first matching rule decides, and
packets matching none are forwarded. Rules only apply to packets being forwarded, not to the router's own. There's no
NAT, because addresses aren't scarce.

### Distance-vector routing

Routers with `net.rip` on learn routes from each other with a protocol modelled on RIP. It needs far less code than a
link-state protocol like OSPF, and that suits Lua:

- Every 15 seconds, with a few seconds of random jitter, a router sends its whole table to its neighbours as a datagram
  on port 520. It also sends an update within a second whenever a route changes.
- Each entry is a prefix, length and metric. A neighbour's route is accepted with its metric plus the cost of the link
  it arrived on. Metric 16 means unreachable.
- Routes aren't advertised back over the interface they were learned from, except as unreachable ("split horizon with
  poisoned reverse"), which stops most routing loops.
- A route not refreshed for 90 seconds becomes unreachable and is removed 60 seconds later.
- A router with `net.rip.default` advertises a default route, typically the one connecting to a backbone. It never
  learns a default route from others, which would send packets for unknown places in a loop.
- Static routes are advertised too, so a router with a fixed route to a network without routers shares it.
- Updates can be authenticated with a shared key (an HMAC over the update, §9), so nobody can inject routes.

**Link cost** is 1 on wired and ender links. On wireless links it comes from the neighbour's last signal strength: 1 at
−60 dBm or better, plus 1 for every 10 dB weaker, at most 8. Routes prefer strong links over marginal ones, which lose
fewer packets. (Ender modems will need the same once they are radios, §12.)

`traceroute` sends packets with increasing TTL and lists the routers that answer with "time exceeded".

## 7. Transport: datagrams and connections

Both protocols use 16-bit ports. Programs bind to a port, or get a random ephemeral one (49152–65535).

| Port | Service |
|---|---|
| 7 | echo |
| 22 | remote shell (§10) |
| 53 | DNS |
| 67, 68 | DHCP server, client |
| 115 | file copies (`ncp`) |
| 520 | routing |
| 2152 | cellular tunnels (§11) |

### Datagrams (UDP)

```lua
body = { sp = 49210, dp = 53, data = <any Lua value> }
```

There's no acknowledgement and no ordering. A datagram to an unbound port gets ICMP "port unreachable". Datagrams can
be sent to a broadcast address. Each socket buffers up to 32 datagrams and drops new ones beyond that.

### Connections (TCP)

Connections deliver **Lua values**, in order and exactly once, rather than a byte stream. That's more natural in Lua and
needs no framing; a stream helper adds byte-stream reads on top for files and terminals.

```lua
body = {
    sp = 49211, dp = 22,
    flags = "A",      -- any of S (open), A (ack valid), F (close), R (reset), K (please acknowledge)
    seq = 1042,       -- sequence number of this segment
    ack = 977,        -- next sequence number expected from the peer
    win = 12,         -- how many more messages, from ack on, the receiver will take
    sack = { 979 },   -- messages after ack which have already arrived, if any
    data = <any Lua value>,
    ts = 1234.5,      -- when it was sent, by the sender's clock, if it uses up a sequence number
    echo = 1230.25,   -- the ts of the segment this one answers, if it had one
}
```

Sequence numbers count messages, starting from a random number. A segment uses one up if it opens (S) or closes (F)
the connection, or carries a message. Plain acknowledgements don't. Lua's numbers are exact far beyond what any
connection could send, so sequence numbers never wrap.

- **Opening:** a three-way handshake: S, then S+A, then A. A listening port queues up to eight connections waiting to
  be accepted, counting ones still opening, and ignores more. Their senders try again. When the queue is full, a
  connection which is still opening and whose S+A went unanswered the first time makes way for a new one, so opens from
  computers which don't exist can't keep everyone else out. A computer has at most 128 connections. A segment for a
  connection which doesn't exist gets an R, rate-limited like ICMP errors.
- **Restarts:** a computer which restarts forgets its connections, but the other sides don't know. Its ports start
  from a random one each time, so a new connection rarely looks like an old one. If it does, the other side answers the
  S with a plain acknowledgement of where the old connection was up to. That's an acknowledgement of something the
  restarted computer never sent, so it answers with an R, which clears the old connection, and its next try gets
  through.
- **Acknowledgements:** every message is acknowledged as it arrives. Messages which arrive early, within the window,
  are held until the gap before them fills, and listed in `sack`, so the sender doesn't resend them. Duplicates are
  dropped and acknowledged again.
- **Retransmission:** the timeout comes from measured round trips (RFC 6298: smoothed round trip plus four times its
  mean deviation). It starts at 1 second, is at least 0.25 seconds (five ticks) and at most 30, and doubles on each retry.
  Round trips are measured with `ts` and `echo`, much like TCP's timestamps: the first segment sent straight away in
  answer to one with a `ts` sends it back as `echo`. That's right even when a message was sent twice, or waited at the
  other side for a gap to fill, which working it out from the acknowledgement numbers isn't. After eight retries (about
  two minutes) the connection resets and the program gets "Timed out". Opening gives up after five.
- **Faster recovery:** a lost message is found before its timeout by duplicate acknowledgements: three of them, or fewer
  when only a few messages are in flight and nothing new can be sent (RFC 5827). It's then resent at once. Until
  everything sent before the loss is acknowledged, each partial acknowledgement resends the next gap (NewReno). Radio
  links lose messages often enough that waiting for timeouts alone would be far too slow.
- **Flow and congestion control:** at most `min(peer window, congestion window)` messages are in flight. A receiver
  takes 16 messages, counting ones waiting to be received. A program may queue 32 before `send` waits. The congestion
  window starts at 2 and doubles each round trip up to 16, then grows by one each round trip. After a fast resend it
  halves, and after a timeout it drops to 1 and starts again. This stops one connection from flooding a radio link or the
  receiver's event queue. When the receiver's window is closed, the sender asks with K now and then, in case the
  message reopening it was lost.
- **Closing:** `close` queues F after everything already queued. The other side's `receive` then returns `nil`, but a
  connection closed on one side can still carry messages the other way. The connection ends when both sides have
  closed, after a short five-second wait for stray segments. `net_closed` is only queued once every message that
  arrived has been received. R aborts at once, and is only believed if its sequence number is within the window (or,
  while opening, if it acknowledges the open exactly).
- **Keepalive:** after 60 seconds with no traffic, a K probes the peer every 10 seconds. Five unanswered probes reset
  the connection.
- **Messages:** any value a modem can send, up to 60 KiB as modems estimate sizes. Unlike datagrams, which modems send
  with functions quietly dropped, connections refuse messages containing anything they can't send. `net.stream` sends
  bytes in 16 KiB messages.
- **Interfaces:** a connection fails with "Address lost" if its computer loses the address it uses.

A connection is identified by local address and port plus remote address and port, so it survives as long as both
addresses do. That is why a phone's address must not change during handover (§11).

## 8. DHCP and DNS

### DHCP

DHCP runs over datagrams, with the server on port 67 and clients on port 68.

1. **Discover:** the client broadcasts from `0.0.0.0`, with its computer ID, hostname and any address it used before.
2. **Offer:** each server answers with an address and the network's settings: prefix length, gateway, DNS servers,
   domain and lease time. (Telling wireless clients to use station mode, §4, is left for later.)
3. **Request:** the client broadcasts which offer it accepts, so other servers can withdraw theirs.
4. **Ack** confirms the lease, or **Nak** refuses it.

The client starts renewing halfway through the lease, trying more often as it runs out, and starts again from
scratch if it does. `release` gives the address back. The server's lease times use real time (`os.epoch("utc")`), and
it keeps its leases in `/.dhcpd/<interface>.leases`, so they survive restarts.

- **Server (`dhcpd`):** one address range on one interface (by default `.100` to `.199`). A client gets back the
  address it had before when it can, which works much like a reservation. Before offering a new address, the server
  pings it in case a computer with a fixed address is using it. The settings `dhcpd.lease`, `dhcpd.dns`,
  `dhcpd.domain` and `dhcpd.gateway` are passed on to clients.
- **Relays (later):** a router with `net.dhcp.relay` forwards broadcast requests from its networks to a central server,
  adding the address it received them on, so the server knows which pool to use. One server can cover a whole base.
- **No server:** after three unanswered attempts, about six seconds, the client takes a link-local address (§3). It
  tries DHCP again after 15 seconds, then less often, doubling up to every five minutes, so a server started later is
  found quickly without unconfigured computers flooding the network.

### DNS

DNS also runs over datagrams, on port 53.

- **Names** are dot-separated and case-insensitive (`bank.spawn`, `0042.tel.acme`). As with addresses, players
  agree among themselves who runs which top-level name.
- **Record types:**
  - `A`: name to address
  - `PTR` (later): address to name
  - `SRV`: service to host and port. It replaces `rednet.host` and `rednet.lookup`: `chat` maps to every computer
    offering chat.
  - `KEY` (later): a host's public key or certificate (§9)
  - `TXT` (later): free text
- **Queries and answers:** `{id, name, type}` is answered with `{id, code, records = {{name, type, value, ttl}, ...}}`.
- **Server (`dnsd`):** answers for one zone, from `/zones/<zone>.txt`, which has one `name address` pair per line (`@`
  is the zone itself). The file is read for every question, so edits apply at once. Computers which got their address
  from `dhcpd` on the same computer are found by their hostname too, which gives dynamic DNS for free. Forwarding
  other zones to an upstream server isn't done yet.
- **Resolver:** built into the stack. It checks addresses, `net.hosts` in settings, its own name and its cache first.
  A name without dots is tried in the search domain (from DHCP or `net.domain`), then as a `.local` name.
- **`.local` names:** names and services ending in `.local` are asked for by broadcast on every interface. Whoever owns
  them answers, so small networks work with no servers, like rednet today.

## 9. Security

### Threat model

- **In scope:** other players' computers can hear any channel within radio range or on a shared wired network. They can
  send frames with any source ID or address, and replay or alter traffic they see.
- **Physical theft:** they can't read files on computers they can't reach. Someone who takes a computer can use the
  keys in its enclave, but can't copy them to another computer. That's part of the game.
- **Out of scope:**
  - Server operators can read everything on disk.
  - Flooding can't be prevented, only limited.
  - Protecting genuinely valuable data. This is about keeping casual sniffing and spoofing out of a game, so the design
    favours cheap operations over extra margins.

### Native crypto API

Cryptography in pure Lua is possible but slow: elliptic curve operations take long enough to stall a computer
noticeably, and constant-time code is hard to get right in Lua. So the mod adds a `crypto` API, implemented in Java with
the JDK's standard providers (this branch builds and runs on Java 25). All arguments and results are binary strings.

| Function | Result | JDK implementation |
|---|---|---|
| `crypto.random(n)` | `n` random bytes | `SecureRandom` |
| `crypto.sha256(data)` | 32-byte digest | `MessageDigest` |
| `crypto.hmac(key, data)` | 32-byte HMAC-SHA256 | `Mac` |
| `crypto.hkdf(ikm, salt, info, length)` | Derived key (RFC 5869) | Built from `Mac` |
| `crypto.pbkdf2(password, salt, iterations, length)` | Key from a passphrase | `SecretKeyFactory` (PBKDF2WithHmacSHA256) |
| `crypto.generateKeyPair(kind)` | Private and public key, 32 bytes each, for `"x25519"` or `"ed25519"` | `KeyPairGenerator` |
| `crypto.exchange(private, public)` | 32-byte shared secret; errors on an all-zero result | `KeyAgreement` (X25519) |
| `crypto.sign(private, data)` | 64-byte signature | `Signature` (Ed25519) |
| `crypto.verify(public, data, signature)` | `true` or `false` | `Signature` (Ed25519) |
| `crypto.seal(key, nonce, plaintext [, aad])` | Ciphertext with a 16-byte tag | `Cipher` (ChaCha20-Poly1305) |
| `crypto.open(key, nonce, ciphertext [, aad])` | Plaintext, or `nil` if it was tampered with | `Cipher` (ChaCha20-Poly1305) |
| `crypto.equals(a, b)` | Constant-time comparison | `MessageDigest.isEqual` |

- **Raw keys:** keys are exchanged as raw 32-byte strings. The Java side turns them into key objects by adding the fixed
  DER header for X25519 or Ed25519 keys (X.509 for public keys, PKCS#8 for private ones), rather than going through the
  JDK's integer-based key specs.
- **Limits:** inputs are capped (for example at 1 MiB per call) to bound the work one call can do.
- **CPU cost:** calls run on the computer's own thread, never the server's main thread. Each is a single JDK operation
  with no extra copying, and parsed key objects are cached. A secure connection costs three X25519 operations per side
  to open (two with `NK`), plus making an ephemeral key, and one ChaCha20-Poly1305 operation per message after that.
- **Server switch:** like the HTTP API, a server config option can turn `crypto` and `enclave` off.
- **Uses beyond the stack:** passwords, signed files, and anything else players want to protect.

### Key enclave

Every computer, turtle and pocket computer has an **enclave**: a small key store that programs can use but never read
from. A program can generate a key, sign with it, or use it in a key exchange, but the private key itself never reaches
Lua. Malicious software can misuse a key while it runs on that computer, but can't copy it anywhere else. Losing the
computer means losing the key, and keys can't be cloned.

| Function | Result |
|---|---|
| `enclave.generate(name, kind [, options])` | Creates a key of kind `"x25519"`, `"ed25519"` or `"secret"` (32 random bytes). Returns the public key, or nothing for a secret. Fails if the name is taken. `options.requirePin` protects it with the PIN (below). |
| `enclave.import(name, kind, key [, options])` | Stores a key a program already has, such as a passphrase-derived one, so its copy can be deleted. Takes the same options. |
| `enclave.publicKey(name)` | The public key, or `nil` |
| `enclave.list()` | A table of names to each key's kind and whether it needs the PIN |
| `enclave.delete(name)` | Removes a key |
| `enclave.exchange(name, peerPublic)` | X25519 with the stored private key; returns the shared secret |
| `enclave.sign(name, data)` | Ed25519 signature |
| `enclave.hmac(name, data)` | HMAC-SHA256 with a stored secret |
| `enclave.seal(name, nonce, plaintext [, aad])`, `enclave.open(...)` | ChaCha20-Poly1305 with a stored secret, for example to encrypt files on a floppy disk so they're only readable on this computer |
| `enclave.setPin(newPin [, oldPin])` | Sets, changes or (with `nil`) removes the PIN |
| `enclave.unlock(pin)`, `enclave.lock()` | Unlocks or locks the PIN-protected keys. `unlock` returns `true`, or `false` and why not. |
| `enclave.status()` | Whether a PIN is set, whether it's unlocked, and any lockout time remaining |

- **Storage:** keys are kept on the server, outside the computer's file system, in
  `computercraft/enclave/<computer id>.json` in the world save. Nothing in Lua can reach that file: not `fs`, not a disk
  drive, not another computer. It's never sent to clients.
- **Following the computer:** because keys are stored by computer ID, they travel with the computer when it's broken and
  picked up, like its files.
- **Cloning:** in survival, computer IDs can't be duplicated. In creative, copying a computer with its data shares its
  enclave, and server operators can read the file. Both are out of scope.
- **Limits:** up to 32 keys per computer, with names of up to 64 characters.
- **Speed:** keys are loaded once and kept as JDK key objects, so an operation costs the same as with `crypto`.

**PIN protection** is optional, off by default, and chosen per key, so programs that need more security can ask for it
while others, like cell towers that must come back by themselves after a restart, don't:

- **Flag:** a key generated or imported with `requirePin` carries that flag for life. A program can't remove it; the
  only way is to delete the key and make a new one, which for a SIM means activating again. Otherwise malware could
  simply clear it.
- **No PIN, no use:** a flagged key can't be used while no PIN is set. A program that asks for protection can't be
  undermined by a user who never sets one.
- **Unlocking:** with a PIN set, flagged keys stay locked after each boot until `enclave.unlock(pin)`. Keys without
  the flag always work.
- **Wrong guesses:** three wrong PINs lock the enclave for a minute, doubling each time. The lockout is stored
  with the keys, so rebooting doesn't reset it.
- **Storage:** the PIN is stored as a salted PBKDF2 hash in the enclave file, never readable from Lua.

A stolen phone whose SIM key needs the PIN is useless to the thief, like a phone with a locked SIM.

The stack keeps its identity keys here (§9 Identities), and the cellular SIM is an enclave key (§11).

### Serialising for encryption

Encryption works on bytes, but packets carry Lua values. The stack includes a binary codec, the public module
`cc.net.codec`. Values are type-tagged and written with `string.pack`. Tables have their keys sorted (numbers, then
strings, then `false` and `true`), so the same value always encodes the same way, which signatures need. `-0` is
written as `0`. It refuses functions, tables as keys, tables which contain themselves, and nesting deeper than 64.
Decoding checks everything, including the depth, so bytes from someone else can't crash or overflow it. Plain
connections can carry tables which contain themselves; secure ones can't. If it proves too slow, it can move into
Java (§12).

### Secure connections

Secure connections use the [Noise Protocol Framework](https://noiseprotocol.org/), implemented in Lua on top of the
crypto API. Noise is a small, well-analysed family of handshakes. It needs only key exchange, an AEAD cipher and a
hash, and its key derivation is exactly RFC 5869 HKDF with an empty info string.

- `Noise_XX_25519_ChaChaPoly_SHA256` when both sides prove who they are. Three handshake messages; the initiator's
  identity stays hidden from eavesdroppers.
- `Noise_NK_25519_ChaChaPoly_SHA256` when only the server is authenticated and the client already knows its key, from
  DNS or an earlier visit. One round trip; like most HTTPS.

The handshake runs as the first messages of an ordinary connection (§7). The first is a table naming the pattern,
`{ secure = 1, pattern, message }`, and the rest are strings. The server's handshake payload carries its certificate, if
it has one. Each later message is `{ d = value }`, encoded, and sealed with the session key and a counter as the nonce.
Because connections deliver each message once and in order, the counters stay in step without being sent. Both
directions use separate keys, and both sides get forward secrecy: later theft of a computer's keys doesn't reveal past
traffic. The implementation (`cc.internal.net.noise`) matches the cacophony test vectors for both patterns.

- **Check before saying who you are:** in `XX`, the client checks the server's key (pinned key, certificate or known
  host, below) after the second message, and only then sends its own identity in the third. A server which fails the
  check never learns who tried to connect.
- **Anything wrong ends the connection:** a message which doesn't decrypt was changed, replayed or reordered. Nothing
  after it can be trusted, so the connection is aborted with "Message was tampered with". Connections are reliable
  underneath, so this only happens when someone interferes.
- **Closing is authenticated:** `close` first sends an encrypted `{ close = true }`. A connection which ends without one
  was cut short (say, by a forged F), and the receiver gets "Connection closed unexpectedly" rather than a clean end.
  Once the marker has arrived, whatever happens to the connection afterwards is a clean end.
- **Anonymous clients:** `NK` clients don't say who they are, so servers refuse them unless they're listening with
  `anonymous = true`. A server which needs to know its clients, like `rshd`, can't forget to check.
- **Handshakes in `accept`:** the server's half of the handshake runs inside `accept`, so a client which stalls holds up
  others for up to 5 seconds at each step. Handshakes which fail are logged and skipped, including ones whose keys
  are made so that no secret can be agreed with them.

The handshake's steps that use a computer's long-term key call `enclave.exchange`, so that key never leaves the
enclave. Ephemeral keys are made with `crypto.generateKeyPair` and thrown away after the handshake.

Secure connections offer the same methods as plain ones, so programs switch by calling `net.secure.connect` instead of
`net.tcp.connect`. They add `getPeerKey()` (hexadecimal), `getPeerName()` (from a certificate) and `getTrust()`:
`"pinned"`, `"certificate"`, `"known"` or `"new"`. `net.stream` works on both.

### Identities and trust

- **Keys:** each computer has an X25519 key for Noise (`net.identity`), generated in its enclave on first use. A
  computer which acts as a certificate authority also has an Ed25519 key (`net.authority`).
- **The order of checks:** a key the program pinned (`options.key`) must match. Otherwise, a certificate from a trusted
  authority for the name asked for is enough. Otherwise trust on first use applies (unless the program asked for
  `trust = "certificate"`).
- **Trust on first use:** `/.net/known_hosts` remembers the key each name had the first time, and a changed key is a
  hard error, as in SSH. This needs no infrastructure. Its weakness is the first connection: someone pretending to be
  the server then goes unnoticed, and could, say, learn the password `rsh` sends. `rsh` shows the fingerprint on a first
  connection for that reason.
- **Certificates:** a certificate is `{v, name, key, expires, issuer, signature}`. The Ed25519 signature covers the
  other fields, encoded after a fixed prefix. Verifying checks that the issuer is trusted, the signature, that the key
  is the one the server proved it has in the handshake (or any certificate would vouch for anyone), the name, and the
  expiry (real time). Computers trust the authorities listed in `/.net/trust`, and a server offers the certificate in
  `/.net/certificate`. The `netkeys` program makes authorities, issues and installs certificates, and edits the lists.
  DNS `KEY` records carrying certificates are left for later.
- **Signed routing and DHCP:** routing updates can carry an HMAC with a shared key. DHCP isn't authenticated, as on real
  networks, but a computer that only trusts authenticated services gains little by being given a fake gateway.

### Secure datagrams and encrypted links

- **Datagrams** to a known peer could be sealed with a key from an earlier handshake, with an explicit counter and a
  window which rejects replays. This is left for later.
- **Encrypted links:** any interface can have a pre-shared passphrase (`net.<interface>.psk`, set with `ifconfig
  <interface> psk <passphrase>` or `net.setPassphrase`). The key is derived with PBKDF2 (4096 iterations, a fixed salt).
  Every frame then becomes `{ type = "sealed", body = { counter, data } }`. `data` holds the real type, body and
  forwarded flag, sealed with ChaCha20-Poly1305. The nonce is the sender's ID and the counter, and the sender, receiver
  and counter are authenticated too. Neighbour discovery is sealed like everything else, and the key is set before the
  address, so even the first announcement is. Frames which aren't sealed with the key are dropped, as are sealed frames
  on an interface without one.
  - **Counters come from real time:** `os.epoch("utc")` in milliseconds, times 1024. They keep growing across
    restarts, so a nonce is never reused. Every computer on a server shares that clock, so frames more than a minute
    from now are refused. Receivers only remember each sender's recent frames (the last two seconds' worth, so frames
    can arrive a little out of order) to refuse replays. A sender forgotten for lack of room can't have its old frames
    replayed, as they're too old by then. A receiver which has just started (or been given the passphrase) remembers
    nothing, so it refuses every frame from before then.
  - **Failing closed:** an interface with a passphrase but no crypto API sends and accepts nothing, rather than sending
    in the clear.
  - **Limits:** like WPA, this keeps outsiders off a base's network, but has no forward secrecy, and everyone with the
    passphrase can read everything. Sensitive traffic should still use secure connections.
- **Cellular** radio links are encrypted with per-session keys from the attach procedure (§11).

## 10. The Lua API, settings and tools

### API sketch

```lua
-- Addresses and names (there are also net.setAddress, net.getAddress, net.getHostname, net.neighbours, net.host,
-- net.unhost, net.lookup, net.capture and net.getErrors)
net.interfaces()                      --> { { name = "top", band = "high", address = "10.4.0.17", prefix = 24, ... } }
net.resolve("bank.spawn")             --> "10.4.0.5"  (or nil, "not found")
net.ping("bank.spawn", 2)             --> 0.1 (seconds), or nil, "timed out"

-- Datagrams
local sock = net.udp.open(5000)       -- or open() for an ephemeral port
sock:send("10.4.0.5", 5000, { hello = true })
local value, from, port = sock:receive(5)
sock:close()

-- Connections
local conn = assert(net.tcp.connect("bank.spawn", 80, 5))
conn:send({ op = "balance" })         -- waits while the window is full
local reply = conn:receive(5)         -- nil, "Timed out"; or nil once the peer has closed
conn:close()                          -- also abort, getPeer, getPort, getId and isOpen

local server = net.tcp.listen(80)
local client = server:accept()        -- with an optional timeout

-- Secure connections, with the same methods
local conn = net.secure.connect("bank.spawn", 443, { trust = "tofu" })

-- Byte streams, for files and terminals
local stream = net.stream(conn)       -- read(n), readLine(), write(s), flush()
```

Blocking calls wait for the stack's events with `os.pullEvent`, so they work inside `parallel`. Event-driven programs can
handle the events themselves:

| Event | Arguments |
|---|---|
| `net_datagram` | port |
| `net_connection` | listening port |
| `net_data` | connection ID: there's a message, or the end, to receive |
| `net_sent` | connection ID: it can take more messages (it just opened, or messages were acknowledged) |
| `net_closed` | connection ID, and why if it failed: sent once everything has been received |
| `net_interface` | interface name, `"up"`, `"down"`, `"address"`, `"duplicate"` (we gave our address up) or `"conflict"` (we defended it) |
| `net_frame` | `"in"` or `"out"`, interface name, the frame, and for incoming radio frames the signal strength. Only while `net.capture` is on. |

### Settings

| Setting | Default | Meaning |
|---|---|---|
| `net.enabled` | `true` | Run the stack at all |
| `net.hostname` | The computer's label, or `computer-<id>` | This computer's name, registered with DHCP and `.local` |
| `net.<interface>.address` | `"dhcp"` for wired interfaces, `"none"` for wireless and ender ones, so idle radios stay quiet | `"dhcp"`, `"none"`, or a static address such as `"10.4.0.1/24"` |
| `net.<interface>.band` | `"high"` | Band for a wireless interface |
| `net.<interface>.psk` | none | Passphrase for an encrypted link (any kind of interface) |
| `net.gateway`, `net.dns`, `net.domain` | from DHCP | Static network settings |
| `net.routes` | `{}` | Static routes |
| `net.hosts` | `{}` | Local names, like `/etc/hosts` |
| `net.forwarding` | `false` | Act as a router |
| `net.rip`, `net.rip.default`, `net.rip.key` | `false`, `false`, none | Routing protocol |
| `net.firewall` | `{}` | Firewall rules, each `{ action = "allow" or "deny", proto, from, to, port, on }` |
| `net.dhcp.relay` | none | DHCP server to relay to (later) |

### Programs

| Program | Purpose |
|---|---|
| `ifconfig` | Show and set interface addresses |
| `route` | Show and edit the routing table, and turn forwarding and RIP on |
| `firewall` | Show and edit a router's firewall rules |
| `ping`, `traceroute` | Test reachability and paths |
| `netstat` | Sockets, connections, neighbours, statistics and recent errors |
| `nslookup` | Query DNS |
| `netdump` | Show frames as they arrive, with a simple filter. Mostly for learning and debugging. |
| `dhcpd`, `dnsd` | DHCP and DNS servers |
| `nc` | Send and receive datagrams or connection messages from the shell |
| `ncp` | Copy files over a connection |
| `rsh` | Remote shell over a secure connection, with the remote terminal redirected, or one command |
| `rshd` | Remote shell server, with the computers allowed in by key, or by a password which then remembers them |
| `netkeys` | This computer's key and fingerprint, known hosts, certificate authorities and certificates |
| `chat` | A replacement for `rednet/chat` |

The API lives in `rom/apis/net.lua`, its internals in `rom/modules/main/cc/internal/net/`, address helpers in the
public module `cc.net.address`, and programs in `rom/programs/net/`, with help pages. The same files can be dropped into
a world as a datapack (§1) to try a newer version without replacing the jar.

### Rednet, and what replaces it

| Rednet | Replacement |
|---|---|
| `rednet.send`, `rednet.broadcast` | Datagrams, to an address or broadcast |
| `rednet.receive` with a protocol | A socket bound to a port |
| `rednet.host`, `rednet.lookup` | DNS `SRV` records, or `.local` services |
| The `repeat` program | Routers |
| GPS | Unchanged. It needs the physical distance between modems, which only raw modem messages have. |

Rednet can stay in the ROM, running alongside, while programs move over. The two never interpret each other's messages.

## 11. Cellular networks

The cellular layer turns pocket computers into phones that keep a network address and open connections while moving
between towers. It follows LTE's structure, simplified.

### Roles

| Role | LTE equivalent | Runs on |
|---|---|---|
| Phone | User equipment | A pocket computer with a wireless modem |
| Cell | eNodeB | A tower computer with a wireless modem, plus a backhaul link |
| Controller | MME | A core computer: attach, authentication, handover, paging |
| Subscriber database | HSS | A core computer: subscribers' public keys and numbers |
| Gateway | S-GW / P-GW | A core computer: phones' addresses, and the link to the rest of the network |

A small operator runs the controller, database and gateway on one core computer. Cells, core computers and routers
must keep running when nobody is nearby, so they call `os.setKeepLoaded(true)` (see
[RADIO_PROPAGATION.md](RADIO_PROPAGATION.md#keeping-computers-running)).

### Radio

- All cellular radio traffic uses the low band, for range.
- Cells broadcast system information on control channel 1001 every second. This is what `beacon.lua` does today.
- Everything else goes between a phone and its cell over the link layer's unicast channels, as frames of type `cell`.

System information is signed, so a rogue tower can't lure phones:

```lua
{ op = "sib", network = "ACME", cell = 12, area = 3, load = 0.4, time = ..., cert = ..., sig = ... }
```

`cell` is the tower's computer ID, `area` its tracking area (see idle mode below), and `load` how busy it is. Each cell
signs with its own enclave key. `cert` is that key's certificate, signed by the operator, and phones check it against
the operator's public key from their SIM. The operator's private key stays in the core computer's enclave, so
no cell holds it.

### Choosing a cell

- A phone tracks each cell's signal strength as a moving average over the last three beacons. `signal.lua` already shows
  this.
- It camps on the strongest cell of its own network, or of a network it may roam on.
- It switches only when another cell is at least 3 dB stronger for at least two seconds, so it doesn't flap between two
  cells of similar strength.
- Below −100 dBm it has no service.

### Subscribers and SIMs

A phone's SIM is an X25519 key named `sim` in its enclave. Unlike LTE, where the phone and network share a secret, the
operator only ever learns the phone's **public** key. Neither a hacked phone nor a stolen subscriber database can clone a
subscription.

- **The subscriber database** holds each subscriber's ID (`ACME-0042`), phone number and SIM public key.
- **The phone** keeps public information in `/.net/sim`: the operator's name and public keys, and its own subscriber ID
  and number.

### Activation

Phones are activated over the air, anywhere in range of the network, with a code from the network's administrator.
Activation is part of the cellular protocol, alongside attaching.

1. **The administrator creates a subscription** on the core computer (`cellctl add`). It returns an activation code
   such as `7Q2M-K4XD-9PRB-T6WN-HJ3C`, in Crockford base32 so there are no ambiguous characters.
   - The first group identifies the pending subscription.
   - The other four groups, 80 random bits, are the secret.
   - The code works once and expires after a day.

   The administrator passes the code on however they like: in chat, or in a book.
2. **The player runs `cell activate`** on the phone. It lists the networks it can hear; the player picks one and types
   the code. The phone creates its SIM key in its enclave, with the PIN flag if the player wants a SIM PIN (§9).
3. **The phone sends `activate {tag, handshake}`** to a cell of that network, which relays it to the controller. `tag`
   is the code's first group. The handshake is `Noise_XXpsk3_25519_ChaChaPoly_SHA256`, with a pre-shared key derived
   from the code's secret. Both sides send their long-term public keys: the phone's SIM key, and the operator's key.
   The handshake only succeeds if both knew the code.
4. **The controller records** the phone's SIM public key in the subscription and marks the code as used. It then sends
   an encrypted `activate_accept` with the subscriber ID, phone number and the operator's public keys.
5. **The phone trusts the operator's keys** only once that encrypted reply arrives, since only someone who knew the
   code could have produced it. It stores them in `/.net/sim` and attaches as usual.

Only the code is secret, and it's never sent:

- **Rogue towers:** an unactivated phone can't check beacon signatures yet, so a rogue tower can pose as the network.
  It still can't complete the handshake without the code, so the phone just gives up.
- **Guessing offline:** Noise's pre-shared keys aren't a password-based key exchange. A rogue tower that runs the
  handshake with a phone can test guesses at the code offline. That's why the secret is 80 random bits rather than a
  short PIN: far too many to try.
- **Guessing online:** the controller cancels a code after a few failed attempts.
- **Moving to a new phone:** the administrator issues a new code for the same subscription. Activating it replaces the
  SIM key, and the old phone loses service, as when moving an eSIM.

### Attaching

Attaching is a `Noise_IK_25519_ChaChaPoly_SHA256` handshake between the phone and the controller, relayed by the cell.
The phone knows the controller's public key from its SIM, so this takes one round trip:

1. The phone sends `attach {network, handshake}` to the cell. Its own public key is encrypted inside the handshake,
   so eavesdroppers can't tell who is attaching. The cell passes it to the controller over the backhaul, on a secure
   connection.
2. The controller answers, learning the phone's public key from the handshake. Unknown or barred keys are rejected.
3. Both sides now share session keys with forward secrecy. The phone confirms with an encrypted `attach_complete`.
   Those keys depend on the phone's private key (its side of the exchange ran in its enclave), so this proves the phone
   is really there. Until then the controller allocates nothing, because the first handshake message alone could be a
   recording.
4. The controller derives a key for this cell from the handshake and the cell's ID, and sends it to the cell. The phone
   derives the same key.
5. The gateway gives the phone an address from the operator's prefix and sets up a tunnel to the cell. The cell sends
   the phone its address and DNS servers in an encrypted `attach_accept`.

A recorded attach can't be used to get in: the session keys also depend on fresh ephemeral keys that only the real
phone has.

From then on, frames between the phone and its cell carry encrypted packets:

```lua
{ op = "data", ctr = 812, ct = crypto.seal(cellKey, nonce(direction, ctr), net.codec.encode(packet)) }
```

The receiver keeps a 64-entry replay window, as for secure datagrams (§9), rather than requiring counters to increase:
radio frames can arrive out of order, for example when a phone moves while a link is being evaluated.

### Getting packets to a moving phone

The phone treats its cell as a point-to-point link with a default route through it.

- **Uplink:** phone → cell (radio, encrypted) → tunnel → gateway → routed normally.
- **Downlink:** the gateway advertises the operator's prefix with RIP, so packets for phones reach it. It looks up each
  phone's current cell and sends the packet down that cell's tunnel.
- **Tunnels** are datagrams on port 2152 between gateway and cell, carrying `{teid = <tunnel ID>, packet = <inner
  packet>}`, like LTE's GTP-U.

Because only the gateway knows where a phone is, its address never changes and its connections survive moving between
cells.

### Handover

When cells can reach each other over the backhaul:

1. A connected phone reports measurements to its cell every two seconds, or at once when a neighbour becomes 3 dB
   stronger.
2. The serving cell sends a `handover_request` to the target cell, with the phone's context and a key derived for the
   target.
3. The target accepts.
4. The serving cell sends the phone a `handover_command` and forwards any downlink packets that still reach it to the
   target.
5. The phone switches cells and sends `handover_confirm` to the target, encrypted with the new key.
6. The target asks the controller to switch the path. The gateway moves the tunnel to the target and sends an end
   marker to the old cell.

The phone's connections continue. A few messages may be delayed, and the connection layer retransmits any that were
lost.

Without a backhaul path between cells, the phone attaches again through the new cell. The gateway still holds its
session, so it keeps its address.

### Idle mode and paging (later)

After 30 seconds without traffic, a cell drops a phone's radio context. The phone stays registered with its tracking
area and keeps its address. When data arrives for it, the controller pages it on the control channel of every cell in
that area. The phone reconnects with a fresh one-round-trip handshake. This saves towers work and makes
"no service" behave realistically.

### Backhaul

Cells are ordinary hosts on the network stack. Backhaul can be:
- wired, where cells are close
- point-to-point low-band radio links between tall towers, which the radio model rewards for height and line of sight
- ender modems, which after their rework (§12) can hop through the Nether, covering eight times the distance

Backhaul traffic uses secure connections or an encrypted link, because it may cross radio.

### Services

- **Messages (SMS):** a store-and-forward server in the core, addressed by phone number. Messages wait until the phone is
  reachable.
- **Directory:** numbers in DNS, such as `0042.tel.acme`.
- **Data:** any program on the network stack.
- **Audio:** DFPWM audio streamed over a connection to pocket computers with speakers. CC has no microphone, so there
  are no voice calls.
- **Cell broadcast:** alerts on the control channel to every phone in an area.

### Roaming and rogue towers

- **Roaming:** a phone may attach to another operator's cells if its SIM allows. The visited network passes the
  handshake to the phone's home controller, named in the attach request, over a secure connection. The home controller
  completes it and sends back the cell key. Traffic goes through the home gateway.
- **Rogue towers** can't complete the handshake without the operator's private key, and phones ignore beacons without a
  valid certificate. Jamming isn't possible in the radio model.

## 12. Changes to the mod

Most of the stack is Lua. These changes to the mod are planned:

| Change | Why | When |
|---|---|---|
| `crypto` API (§9) | Fast, correct cryptography | Phase 0 |
| `enclave` API (§9) | Keys programs can use but not copy | Phase 0 |
| `modem.isInterdimensional()` | Lets the stack recognise ender modems (§4) | Phase 1 |
| Wireless message size limit | Stops anyone broadcasting huge messages to everything in range | Phase 1 |
| Transmit and receive power by device | Phones are weaker than fixed computers, in both directions | Before phase 6 |
| Ender modem rework and cable recipe | Ender modems are too strong for their cost, and make cables pointless | Independent |

### Transmit and receive power by device

Pocket computers and turtles transmit 10 dB weaker than placed computers, and receive 7 dB worse (both configurable per
kind). Ender modems transmit another 10 dB weaker on top (below).

A tall tower doesn't change this, because path loss is the same in both directions. The two-ray model uses the product
of both antenna heights, and the diffraction and block losses don't depend on direction either (a unit test checks
this). So height helps a phone's uplink exactly as much as its downlink, and the uplink always runs out first. With a
10 dB gap, over the ground, a phone stops being heard at 56% of the distance at which it can still hear the tower.

Real networks close most of that gap at the tower, with directional antennas, better receivers and several receive
antennas. Phones' weaker receiver does the equivalent here. With −10 dB transmitting and −7 dB receiving, the uplink
runs out at 84% of the distance at which a phone hears the tower, rather than 56%, so phones don't show a usable signal
far beyond where they can be heard.

Links between placed computers are unaffected. Two phones talking directly lose 17 dB, which over the ground leaves
them about 38% of the range of two placed computers: closer to walkie-talkies than to towers.

Path loss doesn't depend on transmit or receive offsets, so neither costs any extra propagation work. Links are evaluated with the
strongest possible transmitter's budget, cached as now, and each sender's and receiver's offsets are subtracted from the
signal strength when a message is delivered.

### Wireless message size limit

Wireless and ender modems refuse messages over 64 KiB, estimated by walking the value (string lengths, eight bytes per
number, a small overhead per table entry). `transmit` then fails with "Message too large". Wired modems have no limit.
The stack reports oversized datagrams the same way, as real UDP does, and the stream helper splits large data into
chunks, so no fragmentation layer is needed.

### Ender modems

Today ender modems hear, and are heard by, every modem in every dimension, with no propagation at all. For the price of
an ender pearl they make cables, relays and towers pointless.

**New behaviour:**

- **Weak radios.** Ender modems follow the radio model like wireless modems, on both bands, at 10% of the power (−10 dB).
  Over the ground that cuts their range to a bit over half; in free space, to about a third.
- **Into other dimensions.** An ender modem's signal also appears in every other dimension, at the corresponding
  position:
  - X and Z are scaled by `DimensionType.getTeleportationScale`: divided by 8 into the Nether, multiplied by 8 out of
    it, unchanged for the End.
  - Y stays the same, but is clamped to a range for each dimension. Without this, a tall Tellus world (up to Y 2031)
    would put most signals above the Nether's build height.
    - **The Nether: 0–128,** between the bedrock floor and the top of the roof. Signals from high up in the Overworld
      appear on top of the roof, where Nether-roof highways and other infrastructure are built. To the radio model the
      roof is flat, open ground, so links along it carry well.
    - **The End: also 0–128.** There's no need to narrow it to the islands' height (around Y 55–70). The End has no
      ceiling, so a signal above an island still has a clear path down to it. A signal clamped to island height, on the
      other hand, could land inside an island and be buried.
    - **Other dimensions** use their full height.
  - From there it propagates through that dimension's terrain like any other signal. A link through the Nether covers
    eight times the Overworld distance, just like Nether travel.
- **Only ender modems talk across dimensions.** A normal wireless modem never hears another dimension, and an ender
  modem's signal there only reaches other ender modems. A link between two ender modems in different dimensions can be
  evaluated in either dimension: from the first modem's corresponding position to the second, or the other way round.
  Both are evaluated and the better path counts, so links work the same in both directions.
- **No distance across dimensions.** `modem_message` still reports no distance for messages from another dimension, as
  today, so GPS keeps ignoring them. Distances between dimensions would mix coordinate systems and give wrong
  positions.
- **Configuration:** `ender_power_offset` (−10 dB), `ender_cross_dimension` (on), and `ender_y_ranges`
  (`minecraft:the_nether=0..128`, `minecraft:the_end=0..128`).
- **Cable recipe:** to make wired networks the cheap option, one craft makes 32 networking cables instead of 6. The
  recipe is generated by `RecipeProvider`.

**Keeping it cheap:**

1. **Only where someone listens.** Signals only cross into another dimension if an ender modem there is listening, and
   modems only listen while they're loaded: a player is nearby, or the computer is kept loaded. Ender modems are rare,
   so most transmissions never leave their own dimension.
2. **Reject by distance first.** The lower budget shrinks the maximum range. Receivers beyond it, measured from the
   transmitter's corresponding position, are dropped before any terrain is looked at.
3. **No chunk loading.** As today, terrain for unloaded chunks comes from cached heights, the world generator, or
   Distant Horizons, and each dimension already has its own height cache. Propagation never loads a chunk.
4. **Share and keep results.** Path loss doesn't depend on power (above), so ender links reuse the normal link cache,
   keyed by dimension and the transmitter's corresponding position. Links between two placed computers never move, so
   their results can be kept for minutes rather than five seconds, until either end changes.
5. **Same tick budget.** Cross-dimension evaluations join the existing queue and share its per-tick time budget.

**The Nether's ceiling.** The model assumes open sky. In the Nether, the heightmaps report the bedrock roof everywhere,
so every unloaded column looks like solid rock, every antenna looks buried, and there's no path over the terrain.

- **Loaded chunks are fine,** because the whole ray is walked through real blocks.
- **Unloaded Nether space** between the floor and the roof is treated as mostly open, with a fixed loss: rock with a
  small fill fraction (`nether_unknown_fill`, 2% by default). That's about 0.15 dB per block on the low band, so 100
  blocks of unknown Nether cost about 15 dB, and it scales with frequency like every other material. It's a magical
  hell dimension, and physics can bend a little. Reconstructing the caverns from Distant Horizons' data would be more
  accurate, but isn't worth the code.
- **Above the roof** is open ground, as in the Overworld.
- **No path over the terrain** in dimensions with a ceiling. There's nothing to go over.
- **Buried positions:** a corresponding position inside netherrack is like a buried antenna. It could be moved to the
  nearest open space within a few blocks, as portals are.

The default fill fraction needs tuning in play.

### Later

- **Airtime.** A message's size would set how long it takes to send, at a rate depending on the band, and a modem would
  send one message at a time. Cells would then have limited capacity, so load balancing and the number of towers
  matter.
- **Interference.** Simultaneous transmissions on the same channel would add noise at receivers, so frequency planning
  matters, as it does for real networks. This is the most work.
- **Event queue pressure.** Count `modem_message` events dropped because the queue was full, so `netstat` can report
  them. Possibly also allow a larger queue.
- **A native binary serialiser,** if the Lua codec is too slow.

## 13. Testing

- **Crypto API:** Java unit tests against the RFC test vectors:
  - RFC 7748 (X25519)
  - RFC 8032 (Ed25519)
  - RFC 8439 (ChaCha20-Poly1305)
  - RFC 5869 (HKDF)
  - RFC 4231 (HMAC)
  - RFC 7914 (PBKDF2)

  The enclave gets tests that keys can be used but never read back, and that they survive a computer being broken and
  placed again.
- **Protocol logic:** Lua specs in the test ROM (`test-rom/spec/modules/cc/internal/net/`). They connect many `Stack`
  objects with virtual links (`test-rom/spec/support/virtual_network.lua`) and a clock which only moves when told to.
  Links can be slow, lose frames and deliver them twice, computers can be removed, and anything can be put on a link. The network counts
  frames and queued events, to measure floods. This covers routing convergence and DHCP races deterministically,
  without Minecraft. Each spec must finish within 10 seconds, which limits how big a network one can simulate.
- **Noise:** the published test vectors.
- **Game tests:** real computers and modems:
  - ping through a router
  - a DHCP lease
  - a connection across wired and wireless links
  - a phone attaching to a cell
- **In a world:** the "Test 3" save's eight cell sites become real cells with a core network. A phone with an open
  connection is walked across them.

### Robustness

After phase 3, the stack was tested against big networks, bad links and misbehaving computers:

- **Fuzzing** (`fuzz_spec.lua`): about 1,400 cases. Every field of every message the stack reads (frames, neighbour
  discovery, packet headers, ICMP, datagrams, RIP updates, mDNS questions, DHCP offers, acks and requests, and DNS
  answers) is filled with each of 12 bad values: missing, NaN, ±infinity, 10^18, −1, 0.5, 2^32, a string, a table, a
  boolean, and a table which contains itself. After each, the target must have no error, nothing invalid in its tables,
  no timer that can never fire, and still answer and forward pings.
- **Scale and bad links** (`robustness_spec.lua`): a 4×4 grid of routers running RIP (40 networks, paths through 7
  routers), which reroutes when three routers are broken. A line of 17 routers. 80 DHCP clients sharing 60 addresses.
  Three routers joined by radio links with 300 ms of latency and 10% loss per hop.
- **Floods, loops and conflicts:** 2,000 forged source addresses, 500 unknown destinations, a 3,000-route RIP update,
  routing loops with forged TTLs, a computer taking a router's address, link-local clashes, a DHCP server handing out a
  fixed computer's address, two DHCP servers on one link, and a DHCP server which refuses everything.

**What broke, and what changed:**

| Found | Change |
|---|---|
| A DHCP lease of NaN or infinity stopped every timer in the stack for good. Negative or very short leases made clients renew constantly (480 frames a minute at 0.5 seconds). Addresses and prefix lengths weren't checked at all. | Clients reject network, broadcast, loopback, link-local and multicast addresses and invalid prefixes, keep leases between 30 seconds and a week, and ignore a gateway that isn't on the network. |
| A server that offered addresses but never confirmed them had clients asking every 2 seconds for ever. One that refused every request made them ask in a tight loop. | Failed offers and refusals count as attempts, with a pause after a refusal. Then clients take a link-local address and back off. |
| Any computer could take any other off the network by announcing its address: both were marked as duplicates. | Only a computer which took the address in the last 3 seconds gives it up. One that has had it longer defends it, at most once a second. |
| A DHCP server that didn't know about a fixed address handed it out, and both computers lost it. | Clients notice the clash within a second and decline the address. The server avoids it for 10 minutes and offers another. |
| Two computers whose IDs give the same link-local address clashed on every retry, and ended up with none. | Retries pick random addresses. |
| In a routing loop, ICMP errors never reached the sender. Each router had learned the sender's address from the other's forwarded packets, so errors bounced between them. | Routers mark frames they forward, and nobody learns addresses from those frames. |
| A packet with a TTL of NaN, infinity or 10^9 would go round a routing loop for ever. | TTLs must be whole numbers from 0 to 255. `net.ping` rejects others. |
| Floods grew tables without limit: neighbours (one per forged source address), the error rate limit, and pending neighbour lookups, each costing three broadcasts. 2,000 unknown destinations meant 6,000 broadcasts. | At most 512 neighbours per interface, 64 lookups at once, and errors to 256 computers per half second. |
| Every timer and lookup queued a `net_wakeup` event. A computer's event queue holds 256 and drops the rest, including the stack's own timer event, which stopped the stack. | One wakeup event at a time. The background process also restarts its timers if one is well overdue. |
| RIP accepted fractional prefixes and costs and unlimited routes (all 3,000 from one update). It advertised link-local networks. Each update took time proportional to routes × entries. | Updates are checked. Learned routes are capped at 1,024. Loopback, link-local and multicast networks aren't shared. Lookups use an index. |
| DNS answers could resolve names to NaN, −1 or 2^32, and be cached with a NaN lifetime. | Answers must be real addresses. Lifetimes must be numbers. |
| The DHCP server crashed on client IDs of NaN or infinity, and on requests whose address wasn't a number. Its leases and offers grew with every client ever seen. Choosing an address took time proportional to the pool size × the leases. | Requests are checked. An address is only ever in one lease. Expired offers are forgotten. Address choice uses a set. |
| Routers forwarded packets to and from link-local addresses. `net.setAddress` accepted `0.0.0.0`, broadcast and network addresses, loopback, multicast, and `/0`. | Both are refused. |

**Left as they are:**

- **Spoofing.** A computer on a link can claim any address, answer for any `.local` name, or, without `net.rip.key`,
  advertise routes that draw traffic to itself. Security is phase 5's job.
- **Broadcast pings.** Every computer on a link answers a broadcast ping, so a forged one makes them all reply to one
  computer. This stays within a link, since routers don't forward broadcasts.
- **DHCP starvation.** A computer inventing IDs can take every address in a pool. This is the same as real DHCP.
- **RIP's limits.** Networks can be at most 15 routers across, and routing around a broken router takes up to two
  minutes.
- **Modem floods.** A computer sending frames as fast as it can fills the event queue of every computer in range. This
  is true of every protocol in CC, rednet included.
- **`dhcpd` probes.** `dhcpd` pings each new address for half a second before offering it, one client at a time, so
  100 computers starting at once take about 50 seconds to all get addresses. Clients now find clashes themselves, so
  this probe could become optional.
- **`netdump`.** It queues an event for every frame while capturing, as a debugging tool.

### Robustness of connections and security

After phases 4 and 5, connections, secure connections and encrypted links were tested the same way:

- **Connections under stress** (`tcp_stress_spec.lua`):
  - Links which lose a fifth of their frames, deliver half of them twice, and reorder them.
  - 40 rounds of random programs on random bad links, sending, receiving, closing and aborting in any order. Each side
    must receive the first so many messages the other sent, and all of them if nothing failed.
  - 128 connections at once, a thousand one after another, and 30 computers connecting to one port in the same moment.
    Afterwards no connection, port or timer may be left.
  - Computers which restart, on either side of a connection.
  - A flood of 20 opens a second from addresses which don't exist, and 400 made-up segments aimed at an open
    connection.
- **Fuzzing the security layer** (`secure_fuzz_spec.lua`):
  - Every message of both handshakes replaced by each of the 12 bad values, cut to every length, lengthened, and with
    each byte changed. Keys which give everyone the same secret. 300 opening messages of noise. About 1,300
    handshakes in all.
  - Encrypted messages which are anything but ciphertext, or decrypt to something which isn't a message.
  - The codec, given 6,000 strings of noise and every one-bit change to some encoded values. Whatever it accepts must
    encode again, and read back the same.
  - Certificates with each field and each byte changed.
  - Sealed frames with each field made bad, from computers with and without the passphrase. Frames from 2,000
    computers. Frames replayed after the receiver restarts.
  - Remote terminal drawing calls with every argument made bad.
- **Fuzzing** covers the new `ts` and `echo` fields of segments too.

**What broke, and what changed:**

| Found | Change |
|---|---|
| One message crashed any secure server, `rshd` included. A client's first `XX` message carries a key the server can't check until it answers. A key chosen so that every secret agreed with it is zero made the answer throw an error, which went straight through `accept` and ended the program. | Writing a handshake message reports failure rather than throwing, as reading always did. The handshake fails, is logged, and `accept` carries on. |
| Eight opens from addresses which don't exist closed a listening port for a minute, as each waited that long for an answer. Eight frames a minute kept it closed for good. | When the queue is full, a connection which is still opening and has already had to repeat its answer makes way. With 20 such opens a second, about half of real clients now get in within 5 seconds, where none did. |
| A computer which restarted couldn't connect to a server it had an idle connection to for up to two minutes. Ports were handed out from 49152 each time, so the new connection looked like the old one, and the server ignored its S. | Ports start from a random one. A server answers an S it doesn't expect with where the old connection was up to, and the restarted computer resets that. The new connection opens on the next try, a second later. |
| On a bad link, a connection could measure a round trip of half a minute, and from then on wait that long to resend every lost message. A message which arrived, but whose acknowledgement was lost, was timed from when it was sent until the message before it had been sent again. One connection took nine minutes to deliver 16 messages. | Round trips are measured with `ts` and `echo`, which is exact for every segment. A connection which has no measurement at all also comes back down from a long timeout once messages get through. |
| A frame recorded on an encrypted link could be replayed for up to a minute to a computer which had restarted since, as it had forgotten which frames it had seen. | A computer refuses frames from before it started. |

**Left as they are:**

- **Messages which can't be sealed.** Encrypted links and secure connections encode with `cc.net.codec`, which refuses
  tables which contain themselves, tables as keys, and nesting deeper than 64. A plain connection accepts such a
  message, but an encrypted link on its way drops it without a word, so the connection times out a minute and a half
  later, along with everything queued behind it. Connections could refuse what the codec can't encode, at the cost of
  no longer carrying everything a modem can.
- **Faster floods of opens.** A flood still keeps some real clients out: about half of them at 20 opens a second, and
  more as it grows. Doing better needs the server to keep nothing until the client answers (as SYN cookies do).
- **`rshd` and slow clients.** `rshd` serves one client at a time. A client which connects, and then doesn't answer
  the password prompt, holds it for up to three minutes. A client which stalls in the handshake holds any secure
  server for up to 10 seconds.
- **Made-up segments and errors.** A segment with exactly the next sequence number is accepted, as with TCP, and an
  ICMP error about a connection which is still opening ends it. Both need a guess at the ports, which are harder to
  guess now they start at random. Only secure connections stop this properly.
- **Computers with the passphrase.** Any of them can pretend to be any other on an encrypted link, or fill the list of
  512 computers a receiver remembers, which keeps new ones out for a minute.

## 14. Implementation plan

Each phase is usable on its own.

- **Phase 0 is done:** `crypto` lives in `core` (`CryptoAPI`, built on `Crypto`), the enclave in `common`
  (`EnclaveAPI`, `Enclave`, `EnclaveStore`), and `enable_crypto` in the server config turns both off.
- **Phase 1 is done:** the `net` API and its background process (started from `bios.lua` next to rednet), the link
  layer, neighbour discovery, static addresses, ICMP echo and errors, and `ifconfig`, `ping` and `netdump`. The protocol
  logic is `cc.internal.net.stack`, which takes its clock, modems and events as functions, so the tests in
  `test-rom/spec/modules/cc/internal/net/` run whole virtual networks. In the mod, `modem.isInterdimensional()` and the
  `max_message_size` limit for radio messages (64 KiB by default).
- **Phase 2 is done:** datagram sockets (`net.udp.open`), DHCP (clients in the stack, which every interface uses unless
  it has a fixed address; the `dhcpd` server), link-local fallback, names (`net.resolve`, `.local` names, services with
  `net.host` and `net.lookup`, the `dnsd` server) and `nslookup`. The logic is in `cc.internal.net.dhcp` and
  `cc.internal.net.dns`, tested on virtual networks, and two game tests show computers finding each other with no setup,
  and through DHCP and DNS servers.
- **Phase 5 is done:** the codec (`cc.net.codec`), Noise `XX` and `NK` handshakes (`cc.internal.net.noise`, checked
  against the cacophony test vectors), secure connections (`net.secure`, `cc.internal.net.secure`) with enclave keys,
  known hosts and pinned keys, certificates (`cc.internal.net.certificate`), encrypted links (`cc.internal.net.link`),
  and the `rsh`, `rshd` and `netkeys` programs.
  - **Tests:** specs check that changed, replayed and cut-short messages end a secure connection; that the client
    checks the server before saying who it is; and that encrypted links refuse frames which are replayed, changed, too
    old, or from computers without the passphrase. A game test runs a command with `rsh` through a router whose radio
    link is encrypted.
  - **Not automated:** `rshd`'s password prompt and interactive `rsh` sessions.
  - **Left for later:** secure datagrams, DNS `KEY` records, client certificates, and more than one `rshd` session at a
    time.
- **Phase 4 is done:** connections (`net.tcp`, in `cc.internal.net.tcp`), byte streams (`net.stream`, in
  `cc.internal.net.stream`), and the `nc` and `ncp` programs. A spec carries a megabyte across three radio hops which
  lose a tenth of their frames and reorder them, in about 15 seconds. Others cover ordering, flow control with a lost
  window update, half-closed connections, timeouts, keepalive and resets, and fuzzing covers every field of a segment.
  A game test sends a megabyte through a router, from a cable to a wireless modem, and copies a file with `ncp`.
- **Phase 3 is done:** forwarding (`net.forwarding`), static and default routes (`net.routes`, `net.gateway`, and
  gateways from DHCP), the routing protocol (`net.rip`, in `cc.internal.net.rip`), firewall rules (`net.firewall`), and
  the `route`, `traceroute` and `firewall` programs. The virtual networks in the tests have several links, so routers
  can be tested in a line and in a square, where breaking one router makes traffic take the other way. A game test pings
  through a router from a cable to a wireless modem. DHCP relays and telling wireless clients to use station mode (§4)
  are left for later.

| Phase | Delivers | Done when |
|---|---|---|
| 0 | `crypto` and `enclave` APIs in Java, including PIN-protected keys | All RFC vectors pass. Enclave keys work but can't be read back. PIN-protected keys refuse to work until unlocked. |
| 1 | `net` API and background process (as a datapack), link layer, neighbour discovery, static addresses, ICMP, `ifconfig`, `ping`, `netdump`. In the mod: `modem.isInterdimensional()`, wireless size limit. | Two computers ping each other over wired and wireless modems |
| 2 | Datagrams and sockets, DHCP client and server, link-local addresses, DNS resolver and server, `.local` names | A new computer gets an address and resolves names with no setup |
| 3 | Forwarding, static routes, distance-vector routing, firewall rules, `route`, `traceroute` | Ping across three routers. When one is broken, traffic finds another path. |
| 4 | Connections, byte streams, `nc`, `ncp` | A 1 MB file crosses a lossy wireless path intact |
| 5 | Codec, Noise sessions with enclave keys, known hosts, certificates, encrypted wireless links, `rsh` | A remote shell works securely. Tampered or replayed messages are rejected. |
| 6 | In the mod: transmit and receive power by device. Cellular: system information, activation, attach, tunnels, handover, messages. | A connection stays open while walking across the eight test cells |
| 7 | Move the stack from the datapack into the ROM | Every computer has it with no setup |
| — | Ender modem rework and cable recipe, at any point | Ender links work across dimensions within the tick budget |
| Later | Airtime and interference (§12) | |

## 15. Decisions and open questions

| # | Question | Decision |
|---|---|---|
| 1 | Rednet | Keep it, unchanged, running alongside. It may later become a thin layer over datagrams. |
| 2 | Addresses | IPv4-style, assigned by DHCP. Prefix plus computer ID only for link-local fallback addresses. |
| 3 | Connections | Deliver Lua values, with a byte-stream helper for files and terminals |
| 4 | Distribution | In the ROM from the start, so CC's own test suite runs the stack. The same files work as a datapack, to try a newer version without replacing the jar. (Changed from "a datapack first" when phase 1 was built.) |
| 5 | Multiplayer | Players agree among themselves on prefixes and top-level names; nothing enforces it |
| 6 | Crypto | On every computer, kept cheap on CPU, with a server switch. Plus a key enclave (§9). |
| 7 | Radio realism | Transmit and receive power by device and a wireless size limit now; airtime and interference later |
| 8 | Ender modems | Detected with `modem.isInterdimensional()`, and reworked into weak radios. Only ender modems talk across dimensions (§12). Cables: 32 per craft. |
| 9 | SIM activation | Over the air, anywhere in range of the network, with a code from the network's administrator (§11) |
| 10 | Phone power | Pocket computers and turtles transmit 10 dB weaker and receive 7 dB worse than placed computers (§12) |
| 11 | Ender heights | Y is kept but clamped per dimension: 0–128 in the Nether and the End (§12) |
| 12 | Unloaded Nether terrain | A fixed loss per block, tunable; the Nether can bend physics a little (§12) |
| 13 | Enclave PIN | Optional, off by default, and set per key with a flag that can't be removed. Part of phase 0. (§9) |

Nothing is open. Values such as the Nether fill fraction and the phone power offsets will need tuning in play.
