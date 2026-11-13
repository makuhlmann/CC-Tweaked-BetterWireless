# Cellular networks

Phones, cells and a network's core, on top of the network stack described in `NETWORK_STACK.md`: what the design asked
for, and the cellular layer as it was built. This was §11 of that document; references to its other sections say so.

The cellular layer turns pocket computers into phones that keep a network address and open connections while moving
between towers. It follows LTE's structure, simplified.

## Roles

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

## Radio

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

## Choosing a cell

- A phone tracks each cell's signal strength as a moving average over the last three beacons. `signal.lua` already shows
  this.
- It camps on the strongest cell of its own network, or of a network it may roam on.
- It switches only when another cell is at least 3 dB stronger for at least two seconds, so it doesn't flap between two
  cells of similar strength.
- Below −100 dBm it has no service.

## Subscribers and SIMs

A phone's SIM is an X25519 key named `sim` in its enclave. Unlike LTE, where the phone and network share a secret, the
operator only ever learns the phone's **public** key. Neither a hacked phone nor a stolen subscriber database can clone a
subscription.

- **The subscriber database** holds each subscriber's ID (`ACME-0042`), phone number and SIM public key.
- **The phone** keeps public information in `/.net/sim`: the operator's name and public keys, and its own subscriber ID
  and number.

## Activation

Phones are activated over the air, anywhere in range of the network, with a code from the network's administrator.
Activation is part of the cellular protocol, alongside attaching.

1. **The administrator creates a subscription** on the core computer (`cellctl add`). It returns an activation code
   such as `7Q2M-K4XD-9PRB-T6WN-HJ3C`, in Crockford base32 so there are no ambiguous characters.
   - The first group identifies the pending subscription.
   - The other four groups, 80 random bits, are the secret.
   - The code works once and expires after a day.

   The administrator passes the code on however they like: in chat, or in a book.
2. **The player runs `cell activate`** on the phone. It lists the networks it can hear; the player picks one and types
   the code. The phone creates its SIM key in its enclave, with the PIN flag if the player wants a SIM PIN
   (NETWORK_STACK.md §9).
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

## Attaching

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

The receiver keeps a 64-entry replay window, as for secure datagrams (NETWORK_STACK.md §9), rather than requiring
counters to increase: radio frames can arrive out of order, for example when a phone moves while a link is being
evaluated.

## Getting packets to a moving phone

The phone treats its cell as a point-to-point link with a default route through it.

- **Uplink:** phone → cell (radio, encrypted) → tunnel → gateway → routed normally.
- **Downlink:** the gateway advertises the operator's prefix with RIP, so packets for phones reach it. It looks up each
  phone's current cell and sends the packet down that cell's tunnel.
- **Tunnels** are datagrams on port 2152 between gateway and cell, carrying `{teid = <tunnel ID>, packet = <inner
  packet>}`, like LTE's GTP-U.

Because only the gateway knows where a phone is, its address never changes and its connections survive moving between
cells.

## Handover

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

## Idle mode and paging (later)

After 30 seconds without traffic, a cell drops a phone's radio context. The phone stays registered with its tracking
area and keeps its address. When data arrives for it, the controller pages it on the control channel of every cell in
that area. The phone reconnects with a fresh one-round-trip handshake. This saves towers work and makes
"no service" behave realistically.

## Backhaul

Cells are ordinary hosts on the network stack. Backhaul can be:
- wired, where cells are close
- point-to-point low-band radio links between tall towers, which the radio model rewards for height and line of sight
- ender modems, which can hop through the Nether, covering eight times the distance (NETWORK_STACK.md §12)

Backhaul traffic uses secure connections or an encrypted link, because it may cross radio.

## Services

- **Messages (SMS):** a store-and-forward server in the core, addressed by phone number. Messages wait until the phone is
  reachable.
- **Directory:** numbers in DNS, such as `0042.tel.acme`.
- **Data:** any program on the network stack.
- **Audio:** DFPWM audio streamed over a connection to pocket computers with speakers. CC has no microphone, so there
  are no voice calls.
- **Cell broadcast:** alerts on the control channel to every phone in an area.

## Roaming and rogue towers

- **Roaming:** a phone may attach to another operator's cells if its SIM allows. The visited network passes the
  handshake to the phone's home controller, named in the attach request, over a secure connection. The home controller
  completes it and sends back the cell key. Traffic goes through the home gateway.
- **Rogue towers** can't complete the handshake without the operator's private key, and phones ignore beacons without a
  valid certificate. Jamming isn't possible in the radio model.

## As built (phase 6)

The modules are `cc.internal.net.cell.common`, `phone`, `tower`, `core`, `core_service` and `cell_service`, and the
programs `cell` (phones), `celld` (cells, in place of `beacon.lua`) and `cellcore` (the core). Where they differ from
the design above:

- **System information** goes out as a link-layer `cell` frame on the low band's broadcast channel (1000), rather than
  on channel 1001: the stack only hears channels it has opened. A cell's certificate is issued by the core when the cell
  connects, for the cell's own Ed25519 key (`cell.tower` in its enclave), signed by the operator's (`cell.signing`).
- **`cell` frames aren't sealed** on interfaces with a passphrase: they protect themselves. System information is
  signed, handshakes are Noise, and everything else is sealed with the key a phone shares with its cell.
- **Cell keys** are an HMAC of the attach handshake's chaining key and the cell's ID, which the phone and the core both
  know. Messages between a phone and its cell carry a counter, and the receiver keeps a 64-message replay window.
- **Backhaul:** cells reach the core by any route, with a secure connection to port 2123 for control messages. Tunnels
  are datagrams between ports 2152 (the gateway) and 2153 (cells, so a computer can be a cell and the core), sealed
  with a key per cell from a secret in the core's enclave, with a replay window. Packets travel inside them encoded as
  bytes. A cell takes tunnel datagrams from any address, as only the core can seal them.
- **Tunnels need more room** than programs' datagrams, as they carry programs' packets whole, headers and all. A
  program may send 60 KiB (61 KiB encoded), and the tunnel around it adds a few hundred bytes, so the stack's check
  refused (and the cell silently dropped) phones' biggest messages. Datagram sockets now take their own limits, and
  tunnels' allow 64 KiB less 512 bytes for their own packet and frame headers. Cells and the core log a datagram they
  still can't tunnel, rather than dropping it unseen.
- **Relays** (like LTE's relay nodes, or IAB) are cells whose backhaul is the cellular network itself: a computer which
  is both a phone of the network and a cell, so a tower needs no other link. Its phone gets an address and a default
  route as any phone does, and its cell reaches the core through them (`celld 10.64.0.1`, the gateway's address, always
  works). Relays can chain.
  - The stack lets several handlers share a frame type (`on_frame` and `off_frame`), so the phone and the cell both hear
    `cell` frames. Each ignores the other's: the phone only takes frames from its own cell, and the cell only
    phones' requests.
  - A relay's cell reaches the core from its phone's address, which is how the core knows it's a relay. The core
    works out each cell's path, the relays its backhaul goes through, by following cells' addresses to the sessions
    of their phones. It tells cells their path whenever it changes (on attaches, handovers, and cells coming and
    going), and cells add it to their signed system information.
  - Loops: a relay's phone never uses a cell whose path includes its own computer, which would be behind it. The core
    refuses such attaches and handovers too.
  - Each relay wraps a phone's packet in another tunnel, and its phone's radio frame: 249 bytes more each, measured
    with the biggest message a program may send. The outermost tunnel, from the first cell to the core, has room for
    13 relays' worth, so a chain may have at most 10 relays (`MAX_PATH`), leaving some to spare. A relay's phone
    doesn't use a cell already 10 relays from the core, the core refuses such attaches and handovers for relays, and
    a cell the core says is further away stops broadcasting. The cost which will limit chains in practice is airtime,
    once it's modelled: every relay sends each packet over the low band again.
  - A relay only broadcasts while its phone has service (when its route to the core goes through the phone). Without
    it, the relay goes quiet, so its phones (and relays behind it) find another cell rather than sending packets
    nowhere.
  - Handovers through a relay are slower to set up, as the core's word reaches the relay through its phone, often
    after the phone handed over has arrived. A cell keeps a handed-over phone's confirmation for up to five seconds
    until the core's word comes.
- **Handover goes through the core** (like LTE's S1 handover) rather than between cells, so cells needn't reach each
  other. Packets on their way to the old cell during a handover are lost, not forwarded; the connection layer resends
  them. A phone reports a stronger cell after it has been 3 dB stronger for two seconds, measured every second.
- **What phones hear:** system information isn't encrypted, so every phone hears each cell's network name, ID, area
  and load, whatever its network. Phones remember the last 32 cells they've heard (of any network) for 30 seconds,
  noting for their own network's whether the system information checked out, so a cell claiming the name without the
  operator's certificate shows as a fake. They also remember their last 20 events (activated, attached, moved, lost,
  rejected). `cell monitor` shows all of this on one screen, sized for a pocket computer, and works before activation
  too (`net.cell.listen`).
- **Messages** travel on the control path: sealed between the phone and its cell, then over the cell's control
  connection to the core. Both halves of the journey are acknowledged, as radio frames get lost:
  - A phone numbers each message, and sends it every 5 seconds until the core says it has it (or won't take it, and
    why), giving up after a minute of tries. The core remembers the last 64 numbers from each phone, so a message which
    comes twice is only kept once. Up to 20 messages may be on their way from a phone. Without service (or while cell
    service is off), a message waits, and is sent once the phone has service: only tries while it has service count.
    Messages waiting are kept with the phone's others, so a phone which restarts sends them again, with the numbers
    they had: the core knows any it took already (unless the core restarted since).
  - The core keeps messages until the phone they're for is attached and acknowledges them, trying again every 10
    seconds. It refuses messages for numbers nobody has, keeps at most 50 for a number and 1,000 in all, and forgets
    them after a week. Phones remember the last 128 messages they've had, to drop repeats. The core numbers messages
    from a random place each time it starts, so a new message is never taken for an old one.
  - They're only kept in memory, so restarting the core loses undelivered ones.
- **Keeping in touch:** a cell which restarts, or whose core does, forgets its phones, though it may be broadcasting
  again before they notice. So a phone which has heard nothing from its cell for 5 seconds asks whether it's still
  known (a sealed `ping`, answered with a sealed `pong`). After four unanswered, it attaches again, keeping its
  address. A cell which gets a sealed frame from a phone it doesn't know says so (`unknown`, at most once a second), and
  the phone then asks every second, and attaches again after three unanswered. Anyone can send `unknown`, so it only
  ever makes the phone ask.
- **Handover's last step** is the phone telling its new cell it has arrived. It repeats that every second until the
  cell acknowledges it, and attaches again after five tries.
- **What can't be checked can't interrupt.** Until a phone and its cell share a key, a frame which says it's from the
  cell may be from anyone in range. A refusal only counts if no real answer follows within a second. A handshake
  message is read with a copy of the handshake (`Handshake:clone`), as one which doesn't read would spoil it. The
  core keeps up to four attaches and activations under way for each phone at each cell, so a request which only says
  it's from a phone doesn't replace the phone's own, and at most 64 activations in all, for 30 seconds each.
- **Addresses** are kept for the core's lifetime: a phone which attaches again gets the same one. Restarting the core
  gives phones new addresses, which ends their connections.
- **The core and cells run in the background process,** as the phone does, so the computer stays free, and they start
  with it. `cellcore setup` (or `cellcore start`) and `celld <core>` start them and remember to; `cellcore stop` and
  `celld stop` stop them. `net.run` passes every event to each service after the stack has handled it, and services
  never see `terminate`. A service is a set of coroutines (`cc.internal.net.tasks`) which use connections as programs
  do; anything the stack itself sends them is queued, with a `net_cell` event (at most one queued) to wake them.
- **Managing the core** happens while it runs, over the same port: a connection's hello says whether it's a cell or an
  administrator. The core's own computer is always allowed, so `cellcore` on it is just a client over the loopback
  address, and `cellcore remote <core>` works the same from anywhere, even a phone through the core's gateway address.
  - **Requests** are `status`, `allow`, `deny`, `add`, `remove`, `set` (bar a subscriber, or keep them from roaming),
    `log` (the last 100 lines, kept in memory), `carry` and `uncarry` (roaming), and `stop` and `restart`. Only
    `setup` and `start` need the core's own computer: a core which isn't running has nothing to connect to.
  - **Stopping and restarting** from afar: the core answers, closes that connection, and a second later stops, or
    starts afresh as if its computer had restarted. Cells connect again by themselves, and phones find out they've
    been forgotten and attach again.
  - **Programs** manage a core with `net.cell.manage(core)`, which gives an object with a method for each request.
    `cellcore` is built on it. A computer the core doesn't know yet can wait to be allowed, as `cellcore remote` does.
- **Allowing computers:** a computer the core doesn't know yet waits, with its connection open, and the core lists it
  with its claimed ID and its key's fingerprint. `cellcore allow <ID>` shows the fingerprint and asks whether it
  matches the one the computer shows, then saves the full key (never the ID alone) with its role in `/.cell/cells`.
  The waiting computer carries on at once. At most 16 wait at a time, each for up to ten minutes. `cellcore deny`
  refuses a key from then on and drops its connections.
- **Files:** subscribers are in `/.cell/subscribers` and codes in `/.cell/codes`, both on the core, and only the
  running core changes them.
- **Forwarding:** `cellcore` turns `net.forwarding` on and saves it, as phones' packets go through the core.
- **Floods:** each attach request costs the core three X25519 operations, and nothing limits how often a cell relays
  them. As NETWORK_STACK.md §9 says, floods can only be limited; a per-cell limit would be the next step.
- **Roaming** is built much as designed above. The network a phone belongs to is its *home*; one whose cells it
  uses instead is *visited*.
  - **One big cell.** To the home core, the visited core is a cell: over the connection between the two cores (see
    **Agreements**), it gets a key for a tunnel, as cells do. A roaming phone's
    attach handshake goes phone → visited cell → visited core → home core and back. Only the home core can answer it
    (it's `Noise_IK` with the home operator's key), so the visited network can't attach a phone by itself, or read
    what the two say. The home core gives the phone its usual address.
  - **Keys.** A phone's key with a cell is still an HMAC of the handshake's secret and that cell's ID. The visited
    core tells the home core which of its cells the phone is at, the home core makes the key, and the visited core
    passes it to the cell. For a handover between two visited cells the visited core asks the home core for the new
    cell's key, and does the rest itself.
  - **Packets** go phone → visited cell → visited core → home gateway, and back the same way: the visited core has a
    tunnel ID of its own for each visitor, and swaps it for the home core's. The tunnel between the cores is sealed
    like a cell's, and arrives at the visited core on port 2154. It counts as one relay towards the limit on how
    deeply tunnels nest. A roaming phone's connections stay open, as its address is its home network's. A core may
    send down the tunnel from another address than the one the other core reached it at (it sends from the one it has
    towards the other), so each core, if a tunnel's packet comes from an address it doesn't know, tries the other
    networks' tunnel keys.
  - **Which cells to trust.** A phone can't check a visited cell's system information with its own operator's key. So
    the home core tells each phone, in the handshake's answer (which only that phone can read), the names of the
    networks it may use and the keys their cells are certified with. The phone remembers them (in `/.net/sim`), so it
    can roam straight after starting far from home. It hears of a new partner the next time it attaches.
  - **Choosing a network.** Left to itself, a phone uses its home network wherever it can hear it, and a partner's
    only where it can't. It stays on its home network until it loses it. While roaming, once its home network's best
    cell has been 3 dB stronger than the cell it's on for 5 seconds, it goes home. Between networks it attaches again
    rather than being handed over, which takes a moment, and its address stays the same. A phone which has just
    started, or been activated (which now tells it its partners), listens for three seconds before it uses a partner's
    cell: otherwise a partner's cell heard a moment before its own network's would keep it roaming at home.
    `net.cell.setNetwork` tells
    it to use one network only, and `net.cell.networks` lists those around. A phone may be told to use any network,
    even one it knows of no agreement with: it tries that network's cells at once (whether or not it turned the phone
    away lately), keeps trying while it's turned away, and learns the network is a partner if it is.
  - **Cells which don't hear the phone.** A phone may hear a cell well enough to choose it, while the cell doesn't hear
    the phone: at the edge of the cell's coverage, the phone's radio being the weaker. Preferring its home network
    whatever the signal, such a phone used to try its home cell again and again, and stay without service beside a
    partner's strong cell. Now, when an attach through a cell gets no answer at all (a refusal doesn't count), the
    phone leaves that cell alone for 30 seconds, then twice as long each time it happens again, up to five minutes,
    and attaches through the next best cell, a partner's if need be. It only tries such a cell sooner when there's
    nothing else, doesn't go home to one, and asks to be handed over to one only when no other cell will do. An
    attach which works forgets the cell's failures.
  - **Networks it doesn't know.** A phone only hears of new agreements when it attaches, so one which made its way
    out of its home network's coverage before an agreement was made wouldn't know it may roam. Where it can hear
    neither its home network nor a partner's, a phone left to choose tries other networks' cells too, strongest
    first, as real phones do. The visited core passes the attach on if it carries the phone's network, and the home
    core's answer brings the new partner list, so the phone can check that network's cells from then on. Until then
    it uses what it heard of the cell, which is safe, as the handshake is with its own operator. A network which turns
    it away (or doesn't answer) is left alone for a minute, like a real phone's forbidden networks.
  - **Agreements** are made by the two cores' administrators. Each core keeps one for each other network (in
    `/.cell/networks`): that network's core's key, ID and signing key, its number prefix, where its core is (if this
    one connects to it), and what the two do for each other: whether this network carries the other's phones
    (`cellcore network <network> carry on`), whether its own phones may use the other's cells (`roaming on`, or
    `home on`), and whether the two networks' phones exchange messages (`messages on`). One secure connection between
    the two cores (with the role `network`) carries all of it, whichever opened it: a core told where the other is
    (`cellcore network <network> core <address>`) connects, and keeps connecting. Each core's hello says what it does
    for the other, and each message after says what it's for (`s`). The first time, the other core's administrator
    allows it with `cellcore allow`, after it shows its fingerprint, the network it says it is and what it offers;
    allowing it makes the agreement there too, accepting the offer. A core is remembered as its network, and can't
    come back as another, and the core which connected keeps the other's key from the first time. If both cores
    connect at once, both keep the connection opened by the core with the smaller key. `cellcore deny` and
    `cellcore network <network> forget` end it from either side, and `cellcore networks` shows each agreement both
    ways. Carrying goes one way: for each network's phones to use the other's cells, each core carries the other's,
    over the same connection. Older versions had a connection for each direction and another for messages, kept in
    `/.cell/cells`, `/.cell/roaming` and `/.cell/peers`: a core with no `/.cell/networks` makes its agreements from
    those once, and leaves them as they were. Both cores need this version (version 3 of the cellular protocols).
  - **Partners as good as home** (LTE's equivalent networks). The home core's administrator may say its phones treat a
    partner as home (`cellcore network <network> home on`, kept in its agreement). Phones hear of
    it with the partner list (`home = true`), and remember it in `/.net/sim`. They use such a network's cells as
    readily as their own network's (the strongest of either), aren't roaming there (no `R`, and the bar shows their
    own network's name), stay on it until they lose it (as on their own network: moving between two networks means
    attaching again, so they don't), and may use it even if their subscription doesn't include roaming. This is for
    national roaming between two operators, each of which carries the other's phones and treats the other as home.
  - **Full MVNOs:** a network with a core but no cells, whose phones only ever use partners' cells, which it treats as
    home. Its phones can't activate through its own cells, as it has none, so activation goes through partners too:
    a phone which hears no cell of the network it's activating on tries the strongest cell of each network around.
    That network's core passes the activation on to the phone's own core if it carries its phones (as it does
    attaches), and turns it away otherwise, and the phone tries the next. The activation's answer brings the partner
    list, so the phone can check its partners' cells at once.
  - **What a visited network can do** is carry a phone, or not. It can't speak for phones which aren't with it: the
    home core only takes messages, handovers and packets for a phone from the cell (or visited core) it's at. A
    subscriber whose entry has `roaming = false` is refused when roaming.
  - **Messages** to and from a roaming phone go through the visited core to the home core, which keeps them as ever.
- **Shared cells** (like LTE's multi-operator core networks): one cell may serve several networks, whose operators
  plan a site together where neither would build alone. `celld core.acme core.beta` connects the cell to each core,
  each of which allows and certifies it as one of its own cells, and gives it a tunnel key.
  - **System information** names each network the cell serves (up to eight), each with its own part: the certificate
    that network's operator gave the cell, the cell's path to that core (relays are per network), and a signature
    over it with the cell's one key. A cell of one network sends the same, with one part. A phone checks each part it
    has a key for, and remembers each cell once, with the networks it serves, so its signal is measured once.
  - **Choosing:** a phone picks a cell and a network together: the best network (its own or one it treats as home,
    then a partner, then, as before, one it doesn't know), then the strongest cell. Its attach says which network it
    chose (`via`), and the cell sends it to that network's core, naming the phone's own network if that's another, so
    roaming through a shared cell works as through any other. The cell keeps each phone's context with its network,
    and carries its packets through that network's tunnel (each tunnel has its own key, which says whose a datagram
    is, so one port takes them all).
  - **Handover** stays within the network a phone is on, to any cell which serves it, shared or not. A roaming phone
    whose cell also serves its own network goes home through that same cell after five seconds, though it's no
    stronger there.
  - **Losing a core:** the cell stops naming that network, and its phones move on, while it serves the others. The cell
    connects to each core on its own, and is serving while it serves any network. `celld` shows each core's state, and
    a second core of a network it already serves is refused.
- **Messages between networks** are apart from roaming: two networks may exchange messages without carrying each
  other's phones, and the other way round.
  - **Number prefixes.** Each network may have a number prefix, 1 to 8 digits, given at setup (`cellcore setup ACME
    10.64.0.0/16 555`) or later, without a restart (`cellcore numbers 555`). It's kept in `/.cell/config`. Numbers
    stay as they were within a network; another network's phone is written with its network's prefix in front of its
    number there (`6660042`). A network's own numbers may be written that way too. A subscriber's own number comes
    first; then the longest prefix which fits wins, so `55` and `555` can be different networks'. A number which is
    nobody's here and has no prefix the core knows gets "Destination not reachable" (a network with no prefix, which
    exchanges messages with nobody, still says nobody has it). A phone hears its network's prefix when it attaches,
    and shows its full number (`5550042`).
  - **Peers.** Two networks exchange messages when both agreements say so (`cellcore network <network> messages
    on`). Messages then go both ways over the connection between the cores, which is secure (NETWORK_STACK.md §9),
    so they're encrypted between the cores, though not end to end. Both networks need a prefix, and different ones.
    `cellcore peers` lists them, and `cellcore network <network> messages off` (or `cellcore deny`, from the other
    side) ends it. A new prefix goes over the connection, which stays, so phones roaming there keep their service.
    Each core keeps its peers' prefixes in their agreements, so after a restart it knows their numbers before they
    connect again.
  - **Delivery.** A phone's message for another network's number goes to its core, which passes it on with a number
    of its own, and the sender's full number. The other core keeps it for its subscriber as it would its own phones',
    and answers whether it has taken it, or why not ("Nobody has the number 6669"), which the sending phone hears.
    When the other core isn't connected, or doesn't answer within 20 seconds, the sending core keeps the message and
    tells the phone it has it, as for its own phones' messages. It sends it again when that core connects, and every
    30 seconds while it hasn't answered; the other core remembers the last 256 messages each peer sent, so one which
    comes twice is kept once. If the message is refused after all, or not taken within a week, or the agreement ends,
    the sender gets a message from its own network saying so ("Not delivered to 6669: Nobody has the number 6669").
    At most 1,000 messages wait for other networks. A core only takes messages from a peer's own numbers, so a network
    can't send in another's name. The recipient sees the sender's full number, so an answer finds its way back.
- **The phone's menus and status bar.** `cell gui` is the phone as its user sees it, drawn for a pocket computer's
  26 columns and usable on any computer, with the keyboard alone or the mouse, in greys where there are no colours.
  - **The status bar** is the screen's top line: the name of the network in use on the left (or what the phone is
    doing: "Searching...", "Connecting...", "No service" after ten seconds of searching), the signal as four bars in
    brackets on the right (`[||..]`) with an `R` and a space before them when roaming (`R [||..]`), and between them a
    note such as "1 new msg". The bar is dark grey, with colours or without. There's no bar while
    cell service is turned off or the phone has no SIM, and what runs beneath it gets the line back (as a
    `term_resize`). `cell bar [program]` runs any program beneath the bar (a shell, if none is given), in a window
    one line shorter. A computer with a SIM starts beneath it: the message of the day, the startup files and the
    shell run there (leaving that shell turns the computer off, as it would anyway), unless `cell bar off` turned
    it off (the setting `cell.bar`, which also hides a bar shown now; `cell bar on` shows it again). A program which is already beneath a bar
    doesn't get a second one.
  - **Menus:** messages, as a conversation with each number (the list has the newest first, and which have new
    messages or one which wasn't sent; a conversation has those from the number on the left and those sent to it on
    the right, with how each got on, above a line to write in, and opening it reads its messages; messages can be
    deleted, one or a conversation at a time, and one which wasn't sent sent again), writing to a new number, networks
    (every network in range and the SIM's own and partners', with signal, which is in use and which is chosen;
    choosing one keeps the phone to it, and "Automatic" lets it choose), cell service off and on, and the monitor.
    Every screen is left with Q or Backspace (the first quits), but for a conversation, where Q is a letter and
    Backspace in an empty line leaves; and a key held down never leaves two at once.
  - **The same from the shell:** `cell networks`, `cell network <name>|auto`, `cell on` and `cell off`.
  - **What it's built on.** The menus only use `net.cell`: `info` (which also has `enabled`, `signal`,
    `serving_network`, `roaming`, `selection` and `unread`), `messages`, `markRead`, `deleteMessage`, `send`,
    `networks`, `setNetwork` and `setEnabled`, so other programs can do all they do. They redraw on the events
    `cell_state`, `cell_message`, `cell_sent`, and `cell_messages`, which is queued when the kept messages change in
    another way (one was read or deleted), so a bar in one tab follows messages read in another.
  - Turning cell service off stops the phone altogether (it neither listens nor sends, and has no address) and is
    remembered across restarts in `/.net/phone`, as is the chosen network.
- **Not built yet:** idle mode and paging, cell broadcast, numbers in DNS, and the SIM PIN.

The phase's test, walking across the eight test cells with an open connection, needs the towers to reach a core. In
the virtual network, a phone walks past three cells with an open connection and keeps every message. A game test
activates a phone over the air, attaches, reaches the network, and sends itself a message, through one cell, with the
core and cell running in the background. Then the phone manages the core through the network, once the core has allowed
it.

Roaming is tested in the virtual network with two operators side by side (`cell_roaming_spec.lua`): a phone walks out
of one's coverage, across the other's two cells and back, with an open connection, and keeps every message. Others
cover going home (only once home is stronger), trying a network the phone hasn't heard is a partner, being told which
network to use (also one it knows of no agreement with, and one which turns it away), a home cell which hears too
faintly to answer (the phone roams, and tries home less and less often until the cell hears it), a partner treated as
home (no roaming there, staying on it, and letting subscribers who mayn't roam use it), a network with no cells of its
own whose phone activates through the partner which carries it (after another network turns it away), agreements
which are missing or ended, cells which only claim to be
a partner's, messages on a bad link, either core restarting, a visited core overstepping, and about 10,000 control
messages between the cores with a field made bad. `cell_service_spec.lua` has two cores make an agreement over a
connection, lose each other, and end it. A game test has three computers: two networks' cores and cells, and a phone
which activates at home, hears of the other network, is told to use it, reaches its home gateway and sends itself a
message through it, and is sent home again, where it stays when left to choose, though the other network's cell is
stronger. While it roams, the test runs `cell gui` on a pocket computer's screen, and checks the status bar's network,
`R` and "1 new msg", opens the message in the menus, and sees the note go.

Shared cells are tested in the virtual network (`cell_sharing_spec.lua`) with one cell serving two operators: each
network's phone attaches through it to its own core, gets its own network's address and reaches the server; a phone
is handed over between the shared cell and its network's own and back with a connection open; a phone roams on the
other network at the shared cell and goes home through it; and the cell stops naming a network whose core it loses,
whose phone moves on, while the other stays. `cell_service_spec.lua` has a cell keep two cores, lose one, and refuse a
second core of a network it serves.

Messages between networks are tested in the virtual network with two operators whose cores exchange messages
(`cell_messaging_spec.lua`): both ways, to a network's own numbers written in full, to numbers nobody has and
prefixes nobody has, kept until the other network's phone is on, kept while the other core can't be reached and sent
when it's back (and the sender told if it's refused then, or kept too long, or the agreement ends), a core which
doesn't answer, a message which comes twice, a peer speaking for numbers not its own, and messages between the cores
with something unexpected in them. `cell_service_spec.lua` has two cores agree
over a connection, take a second role (carrying phones too), change a prefix, and end it; checks prefixes which
are missing or the same are refused; and has a core know a peer's prefix again after a restart, before it connects.

The menus and the bar are tested against a made-up phone (`spec/programs/net/cell_gui_spec.lua`): what the bar shows
in each state and at each width, with and without colours; that it comes and goes with cell service and the SIM; and
each menu with keys and with clicks, on a pocket computer's screen and a wider one. A last group of tests uses the
menus at random (keys, typing, pasting, clicks on and off the screen, resizing, terminating) while the phone changes
at random (states, networks with long names, messages of a thousand characters or sixty empty lines), on screens from
80 by 30 down to 1 by 1: about 16,000 things in all, none of which may raise an error. That found one fault: the
monitor, opened from the menus, took a termination as leaving it, so the menus carried on.
