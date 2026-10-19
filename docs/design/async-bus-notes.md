# Towards a fully-async, tick-ordered bus

Status: design notes only, nothing here is implemented. Written after the
"stop HandlePacket implementations from blocking the dispatch thread" pass
(see `vdrx-async-hardening.patch` / git log) - that pass fixed the acute
symptom (a hung socket/pipe/process freezing the whole bus). This note is
about the bigger, optional next step: making `TVDRX_Kernel.Execute`'s
dispatch itself concurrent, with an explicit ordering model instead of
relying on "it's all one thread so it's trivially ordered."

## Why the acute fix wasn't enough on its own

After the hardening pass, no `HandlePacket` implementation does I/O inline -
they all enqueue onto their own send thread. `TVDRX_Kernel.Execute` itself
is still a single-threaded loop:

```pascal
for Exec in Subscribers do
  Exec.HandlePacket(Msg);
```

That's now *safe* (nothing it calls can block for long - worst case is
memory allocation for the enqueue, and the 250ms `HANDLEPACKET_WARN_MS`
tripwire will shout if a future executive violates the contract). But it's
still fundamentally serial: every subscriber to every topic gets processed
one at a time, on one core, in registration order. For VDRX's current scale
(a handful of processes/connections per instance) that's plausibly fine
forever. It's worth writing this down anyway because "let's finally make the
bus async" is easy to reach for once profiling says otherwise, and the
ordering question below is the part that's easy to get wrong under
schedule pressure.

## The actual hard part: ordering

The moment dispatch fans out to multiple worker threads, you lose the free
ordering guarantee the current single loop gives you for free: if executive
A publishes message 1 then message 2 on the same topic, every subscriber
currently sees them in that order, because one thread processes the queue
front-to-back. Any async redesign has to decide, explicitly, what ordering
guarantee (if any) replaces that - "just use a thread pool and dispatch
whatever's next" quietly drops it, and some existing behaviour probably
depends on it without saying so (e.g. `vdrx_bucket.pas`'s append-only
recorder almost certainly assumes append order == publish order).

### Option sketched: logical ticks

The idea floated in conversation: give the bus a notion of a "tick" - not
necessarily wall-clock, more like a logical frame/generation counter - and
use it as the ordering unit instead of "whatever order a shared queue
happened to hand messages to worker threads in." Rough shape, for whenever
this gets picked up seriously:

- The kernel advances a monotonic `FTick: QWord` once per dispatch cycle
  (either wall-clock-paced - e.g. every N ms - or purely logical, advancing
  once every time the inbound queue is drained to empty, closer to a
  traditional game-loop tick).
- Every `TVDRX_Message` gets stamped with the tick it was published in
  (not the tick it happens to get *processed* in - that's the whole point).
- Within a tick, messages for the *same topic* keep publish order (a plain
  per-topic queue, drained in order by whichever thread owns that topic).
- Messages for *different* topics can dispatch to different worker threads
  concurrently within the same tick, since nothing currently promises
  cross-topic ordering anyway - only same-topic order is a real, load-bearing
  guarantee today.
- A subscriber that cares about strict tick order (processing every tick's
  messages fully before the next tick starts) can opt in; one that doesn't
  (most socket/process bridges) just drains its own queue as fast as its
  worker thread can, tick number along for the ride as metadata/diagnostics
  rather than a hard barrier.

This is deliberately vague past that point - the real design work is in
deciding which of "per-topic worker thread," "per-executive worker thread,"
or "shared pool + per-subscriber queue (much like the Bridge/SocketClient
send-thread shape already in the codebase, just applied to the *receive*
side instead of the send side)" fits VDRX's actual subscriber counts and
message rates best, and that's a decision worth making against real
measurements rather than up front.

## A smaller, lower-risk step in the same direction

Before touching `TVDRX_Kernel.Execute` itself, the same "receive-side
mailbox" shape already proven on the send side (Bridge/SocketClient's
`EnqueueLine`+`SendLoop`) could be applied per-executive on the *dispatch*
side: instead of the kernel thread calling `HandlePacket` directly, it drops
the message into a small per-executive inbound queue and a per-executive
worker thread drains it. That gets you real dispatch-level concurrency
(one wedged - or even just slow - subscriber's queue backing up doesn't
delay any other subscriber's queue) while keeping the ordering story
completely trivial: each executive still sees its own messages in the exact
order the kernel thread enqueued them, because there's still exactly one
producer (the kernel thread) per per-executive queue. No tick concept
needed for this step - it only becomes necessary once you want ordering
guarantees *across* executives/topics, which today's design doesn't
promise anyway. Worth doing as a checkpoint even if the tick-based version
above is the eventual destination, since it's a much smaller diff and
independently useful (real throughput gains under load, not just safety
under a hang).

## Things to measure before committing to either

- Actual message rate and subscriber count in real deployments - the
  current synchronous loop may simply never be the bottleneck.
- Whether anything actually relies on cross-topic ordering today (grep for
  publish/subscribe pairs that assume a happens-before relationship across
  *different* topics - same-topic order is the only guarantee worth
  preserving by default per the above).
- Cost of the per-executive queue/thread approach at whatever the realistic
  upper bound on executive count is (each supervised process, each open
  socket connection, each WS client all become a queue+thread pair).
