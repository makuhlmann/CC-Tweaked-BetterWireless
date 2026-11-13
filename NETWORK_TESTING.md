# Testing the network stack

What each round of testing found, and what was done about it: for the stack, connections and security, cellular
networks, several networks at once, and wired networks through unloaded chunks. How the stack is tested is in
`NETWORK_STACK.md` §13; this was the rest of that section.

## Robustness

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

## Robustness of connections and security

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
| A connection took any message a modem can send, but an encrypted link on its way dropped those `cc.net.codec` can't encode without a word: tables which contain themselves, tables as keys, and tables nested too deeply. The connection sent the message again and again, and failed a minute and a half later, along with everything queued behind it. A few messages were also bigger encoded than a radio can send, though small enough as modems estimate sizes. | Connections only take what the codec can encode, with tables up to 60 deep and 61 KiB once encoded. Anything else is refused when it's sent, with the reason, and the connection carries on. |
| Datagrams had the same trouble, and one more. A datagram holding a function arrived on a plain link with the function left out, but was dropped whole by an encrypted link, while `send` said it had been sent. | Datagrams take the same values as connections, and `send` refuses the rest. (`cc.internal.net.message` holds the rules for both.) |

**Left as they are:**

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

## Robustness of cellular networks

After phase 6, the cellular layer was tested the same way (`cell_stress_spec.lua`, and additions to
`cell_service_spec.lua` and `noise_spec.lua`):

- **Pretending to be a phone's cell:** refusals, handshake answers which don't read, and competing requests "from" the
  phone, sent between a phone's request and the real answer, while attaching and while activating. About 3,000 frames
  with each field made bad, as from the phone's cell and as broadcasts from anyone.
- **Cells and cores which send odd things:** sealed messages to phones and from them, and control messages both ways,
  with each field made bad: about 5,000 in all. A phone doesn't choose its operator's software, so a cell may refuse
  to serve it, but mustn't be able to break it.
- **Bad radio links:** attaching and walking past three cells with an open connection at 15% loss. Twelve trips back
  and forth between two cells at 25% loss. Thirty messages at 25% loss.
- **Restarts:** a cell which restarts and is back before its phones notice, and a core which does.
- **Scale and floods:** 60 phones through one cell. 800 messages to a phone which is never there and to numbers nobody
  has. 2,000 activations which never finish. 300 made-up cells.
- **Management:** about 600 requests to a running core with each field made bad, and 170 computers which introduce
  themselves oddly.
- **Handshakes:** every byte of every message of all four Noise patterns changed, messages cut short and lengthened,
  and keys which give everyone the same secret.

**What broke, and what changed:**

| Found | Change |
|---|---|
| A phone whose cell restarted, or whose core did, stayed "attached" for good with nothing getting through, if the cell was broadcasting again within 4 seconds. Nothing told it the cell had forgotten it. | Phones ask a quiet cell whether it still knows them, and cells tell computers they don't know (see "Keeping in touch" in `NETWORK_CELLULAR.md`). Service is back within a few seconds. |
| One lost frame at the end of a handover left a phone on a cell which wasn't serving it. At 25% loss, a phone walking between two cells was stranded within a dozen trips. | The phone says it has arrived until the cell acknowledges it. |
| Messages were sent over the air once. At 25% loss, 30 messages never all arrived. | Phones send each message until the core has it, and the core drops repeats. Programs are told what became of each (`cell_sent`). |
| The core numbered messages from 1 each time it started, and phones remembered every number they'd had for good, so after a restart new messages would be dropped as repeats. | Numbers start from a random place, and phones remember the last 128. |
| The core kept every message for a number nobody has, for good, and looked for a phone for each of them every 10 seconds, taking time proportional to messages × subscribers. | Unknown numbers are refused, mailboxes are limited, old messages are forgotten, and looking is one pass. |
| A frame which said it was from a phone's cell could stop it attaching: a refusal made it give up (waiting up to a minute before trying again), and a handshake answer which didn't read spoiled the handshake. A request "from" the phone replaced the phone's own at the core. The same went for activating. | See "What can't be checked can't interrupt" in `NETWORK_CELLULAR.md`. |
| A sealed message from a cell with an odd number in it (NaN as a message's ID, say) raised an error in the phone, as did a control message at a cell or a frame from a sender which isn't an ID. A cell claiming the ID 10^18 raised one in the core each time it connected. | IDs are checked wherever they arrive (`common.is_id`), and the stack drops frames whose sender isn't one. |
| Activations which never finished were kept for good: 2,000 requests, 2,000 handshakes in memory. | At most 64, the newest, for 30 seconds each. |
| Any cell could send a message, or acknowledge one, for any phone, knowing its tunnel's ID. | Only the phone's own cell speaks for it. |
| Two phones could be given the same tunnel ID, picked at random from 2^31. | IDs in use aren't picked. |
| A phone remembered the first 32 cells it heard. With 300 made-up cells about, it never listed the real one, so couldn't be activated. | It remembers the 32 strongest. |
| Phones took any string of up to 64 bytes as a network's name, and show names to people. | Names are letters, digits and dashes, up to 32, as `cellcore setup` allows. |
| Timers due at the same moment ran in no particular order, so control messages queued together could swap. | They run in the order they were set. |

**Left as they are:**

- **Using up a code.** A code's first group is sent in the clear. Someone in range who hears it, or answers a phone's
  activation before the cell does, can make the three wrong tries which cancel the code. The administrator makes
  another.
- **False alarms.** At 25% loss a phone sometimes loses four checks in a row, and attaches again though its cell knew
  it. That costs a second or so, and its address stays.
- **Floods of attaches.** Each still costs the core three X25519 operations (`NETWORK_CELLULAR.md`).
- **Pretending to be a cell which is out of the phone's hearing.** A frame which says a cell doesn't know a phone
  makes the phone ask, once a second at most. Nothing else which can't be checked makes a phone do anything.

## Robustness of several networks

Once phones chose between networks, cells were shared and networks exchanged messages, those were tested the same way
(`cell_networks_stress_spec.lua`, and additions to `cell_service_spec.lua`):

- **Everything at once:** two operators which carry each other's phones, share a cell and exchange messages, with four
  phones wandering along the line at 15% loss and sending each other messages, within a network and between them.
  Meanwhile cells restart, the shared cell loses and regains its second network, the cores lose and find each other,
  and phones are told which network to use. Then everything is mended and left alone for a few minutes. Thirty such
  runs of 280 seconds, four of which are kept as shorter tests: every phone ends up attached and reaches the server, every message the network
  took arrives once, and no session, visitor, attach or message is left over.
- **Made-up cells and networks:** 96 network names a second, which keep changing, for 200 seconds, heard by a phone
  with no service, and for 120 seconds by a phone with service, along with cells which say they're its own network's
  and frames which say they're from its cell.
- **One phone sending all it can** to another network whose core can't be reached: 2,400 messages.
- **Odd things:** system information with each field made bad, in the whole and in each network's part, with 2,000
  parts, and with paths of 5,000 relays; about 1,500 frames to a shared cell, from a stranger and from each phone it
  serves, with each field made bad, the network a phone chose among them; activations passed between two cores with
  each field made bad; a core which answers a cell with a name, certificate or key which can't be used; and computers
  which introduce themselves oddly as another network's core, to exchange messages.
- **A core claiming another network's phone** at a cell both networks share.

**What broke, and what changed:**

| Found | Change |
|---|---|
| A phone remembered every network which turned it away, or didn't answer, for good. Where it had no service and someone made up network names, the list grew by one every few seconds. | Networks whose minute is up are forgotten whenever another is added. |
| One phone could take all 1,000 places for messages waiting for other networks, within a minute, while another network's core couldn't be reached. Nobody else could then send that way until the core was back, or a week had passed. | At most 50 of one subscriber's messages wait for other networks. |
| At a shared cell, any network's core could give the cell a context for any phone, which replaced the one the phone had through another network. One operator's core could so cut the other's phones off, again and again. | A core only takes over a phone which is at the cell through another network if the phone asked to attach through its own. |
| A cell used whatever network name, certificate and tunnel key a core gave it. All networks' parts are broadcast together, so a name or certificate too long for a modem to send would have taken every network at the cell off the air. | A cell refuses a core whose answer isn't a network's name, a certificate of at most 1,024 bytes and a 32-byte key, and serves its other networks. |

**Left as they are:**

- **A phone which names a network its cell doesn't serve** is taken to the cell's only network, if it has just one.
  Phones only name networks the cell broadcast, so this happens for a second or so after a shared cell loses a core.
  The phone then attaches as a visitor, notices its network is gone from the cell, and attaches again.
- **Two cores which say they're the same network** at one cell: the first is served, the second refused. The cell
  can't tell which is real. Phones can, as only one has the operator's key, so the worst a false one does is keep that
  network off this cell.
- **Unsigned system information which says it's from a real cell** changes what the monitor shows for that cell
  (its signal, and whether it checked out) until the cell's next broadcast. It doesn't change which cell is used.
- **Another network's core is trusted with its own numbers:** a peer can send messages from any number with its
  prefix, and fill the mailboxes of subscribers who aren't reachable (50 each, 1,000 in all).

## Robustness of wired networks through unloaded chunks

The wiring remembered for chunks which aren't loaded (NETWORK_STACK.md §4) was tested apart from the game
(`DormantWiringRandomTest`, and additions to `DormantWiringTest`, `NetworkTest` and `UnloadedWiringFileTest`):

- **Random loading and unloading:** a pretend level of twelve chunks, with negative coordinates and blocks at the
  bottom and top of the world. Wired blocks are placed and broken while chunks load, join their networks a tick later,
  stop being fully loaded, unload, and are saved and restored, or lost, across restarts: 16 runs of 250 steps. After
  every step the networks are compared with what a search of the blocks says is connected, as are the pieces
  remembered, their ports, the peripherals each block sees and the chunks which aren't known.
- **Edges:** ports at corners and at every height, blocks which only touch at a corner, chunks with no wiring, loading
  or unloading twice, a chunk in between which was never seen, two levels, 2,000 chunks restored at once, and pieces
  with 6,144 ports.
- **The file:** a bit changed in every byte, files cut short, files which aren't wiring at all, other versions,
  counts which can't be, dimension names which can't be, and writes which fail.

**What broke, and what changed:**

| Found | Change |
|---|---|
| Splitting a network locks it and then the new networks made from it, but joining two locked whichever was asked first. Breaking a cable and placing it again so took the two halves' locks the other way round, half the time. Only the server thread takes two at once, so nothing deadlocks, but the lock checker (on in development and in tests) throws. Disconnecting two nodes and connecting them again always could do this; remembered wiring made it common. | Each network knows its age, and the older network's lock is taken first. |
| A `wiring.dat` with a bit changed was read as different wiring, with ports where there are none, which could connect networks which aren't connected until those chunks loaded. Reading stopped before the end of the compressed data, where its checksum is. | The file is read to its end. One which doesn't match its checksum, is cut short, or holds more than the wiring is ignored, like any other which can't be read. |

**Not tested:** the side which talks to the game (`UnloadedWiring` scanning chunks, joining, saving, and the `wiring`
commands) has no automated test, and the NeoForge hooks were only read. What was noticed there by reading, and not
confirmed, is in `NETWORK_STACK_PLAN.md`.

## The test suite's stalls

The Lua specs stalled now and then, and sometimes every test after one which stalled failed too. Three things came of
looking into it (`NETWORK_STACK_PLAN.md` 5.2):

- **The test runner and the test delegate fell out of step:** a test which ran past its ten seconds took the event
  which asked for the next test and dropped it. `mcfly` now runs each test in a coroutine of its own, and an event
  asking for the next test ends the one which ran on.
- **Events were lost:** a computer's queue holds 256 events, and drops one queued while it's full. Waiting for an event
  which was dropped waits for good. The specs' shared `yield` and `mcfly`'s wait before each test queue theirs again
  once a full queue's worth of others has come first.
- **What filled the queue was the network stack's timers.** `net.run`, which the BIOS runs beside the shell (and so
  beside every test), started a timer for the stack's next deadline, and took one which was a second overdue to be
  lost: it started another without cancelling it, and still took the overdue deadline as when the new one would fire.
  Once a test had kept the computer busy for over a second, every event started another timer, those timers' own
  events included, and only the newest would run the stack, so they multiplied until the queue was full: 716,065 in
  one run of the suite. Outside the tests, any computer which was busy for a second could have done the same. The
  loop now keeps one timer, with when it will fire, and cancels any it replaces; the whole suite starts a few hundred
  timers. A test keeps the computer busy and counts them (the old loop started 1,001).

Under the test delegate, `mcfly` notes where each timer was started, which the shared `yield` prints when it finds the
queue full, and writes how many each place and each test started to `/timers.txt` in the test computer's folder.
