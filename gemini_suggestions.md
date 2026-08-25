Here is a detailed technical analysis of the codebase across critical bugs,
performance bottlenecks, edge cases, and architectural refinements.

1. Critical & High Priority Issues

A. Race Condition & Double-Free in TVDRX_SocketListenerExecutive.Shutdown

  - Location: vdrx_network.pas (TVDRX_ListenerConnThread &
    TVDRX_SocketListenerExecutive.Shutdown)
  - Problem:
    1.  TVDRX_ListenerConnThread.Execute sets FreeOnTerminate := True in its
        finally block before exiting. When the thread terminates naturally, Free
        Pascal frees the TThread object instance automatically.
    2.  In TVDRX_SocketListenerExecutive.Shutdown, active threads are snapped
        into CopyList. If a connection thread finishes and self-destructs while
        Shutdown is waiting, Shutdown proceeds to call:
        if WaitThreadOrTimeout(ConnThread, FGracefulTimeoutMs) then
          ConnThread.Free;
    3.  This causes an Access Violation / Double-Free (Heap Corruption) because
        ConnThread was already freed by FreeOnTerminate.
  - Fix: Either:
      - Keep FreeOnTerminate := False permanently and let the connection
        manager/executive destroy threads after joining, or
      - Do not call ConnThread.Free in Shutdown if using FreeOnTerminate := True
        (use synchronization events or wait counters instead of retaining raw
        TThread pointers).

B. WebSocket Frames \ge 64\text{ KB} Broken in SendFrame (RFC 6455)

  - Location: vdrx_network.pas (TVDRX_WSConnection.SendFrame)
  - Problem: SendFrame only supports 7-bit (< 126) and 16-bit extended length
    (126):
    if Length(APayload) < 126 then
      ...
    else
    begin
      Hdr[1] := 126;
      Hdr[2] := (Length(APayload) shr 8) and $FF;
      Hdr[3] := Length(APayload) and $FF;
      HdrLen := 4;
    end;
    If an outbound payload is \ge 65,536\text{ bytes} (e.g. large history
    responses, data dumps), Hdr[2..3] overflows / truncates the length. The
    WebSocket client receives a malformed frame size, fails the frame
    validation, and abruptly terminates the connection.
  - Fix: Implement the 64-bit length header path (Hdr[1] := 127, with 8-byte
    big-endian length) when Length(APayload) > 65535.

C. Destruction Lifecycle Inversion in TVDRX_Kernel

  - Location: vdrx_core.pas (TVDRX_Kernel.Execute & Destroy)
  - Problem: FQueue.Free and FRegistry.Free are called at the bottom of
    TVDRX_Kernel.Execute on the worker thread. However, FRegistry and FQueue are
    created in TVDRX_Kernel.Create and exposed as public properties to the main
    thread. If the main thread accesses Kernel.Registry or Kernel.Queue around
    termination, it hits dangling pointers.
  - Fix: Move FQueue.Free and FRegistry.Free into TVDRX_Kernel.Destroy, ensuring
    the worker thread only performs ShutdownAll before exiting its loop.

2. Performance Bottlenecks & High-Churn Areas

A. 1-Byte Pipe Reads in TVDRX_BridgeExecutive.ReaderLoop

  - Location: vdrx_bridge.pas (ReaderLoop)
  - Problem:
    if Proc.Output.Read(Ch, 1) = 1 then
    Reading external process stdout one character at a time issues a syscall /
    stream read per byte. For processes outputting high-volume logs or JSON
    streams, this consumes significant CPU time and hurts throughput.
  - Fix: Read into an intermediate buffer (e.g. array[0..4095] of Byte) and
    parse lines using buffer scanning (Pos / scan pointer).

B. Premature Process Pipe Exit in TVDRX_BridgeExecutive

  - Location: vdrx_bridge.pas (ReaderLoop)
  - Problem: The loop condition while (not FStopping) and Assigned(Proc) and
    Proc.Running do terminates as soon as Proc.Running becomes False. If a child
    process prints output and immediately exits (short-lived processes or fast
    commands), there may still be buffered data in the OS pipe. The loop
    terminates early and discards the trailing process output.
  - Fix: Continue reading from Proc.Output until Proc.Output.Read returns <= 0
    (EOF).

C. Repetitive String Allocation in ReadFullRequest (HTTP)

  - Location: vdrx_network.pas (ReadFullRequest)
  - Problem: During request body reception, Result is repeatedly resized:
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    For multi-megabyte POST requests (up to MAX_BODY_SIZE = 10MB), this triggers
    thousands of reallocations and memory copies.
  - Fix: Once the Content-Length header is extracted, pre-allocate the exact
    total length with a single SetLength(Result, HeaderEnd + 3 + ContentLength)
    and copy subsequent chunks directly by offset.

D. Repeated Heap Allocations in ExtractHeaderValue & TopicMatches

  - ExtractHeaderValue: Instantiates and parses a full TStringList on every
    header check for every HTTP/CLI request. A direct zero-allocation string
    scanner (looking for \r\nHeader-Name:) avoids heap churn.
  - TopicMatches: Calls Filter.Split(['.']) and Topic.Split(['.']) on every
    message dequeue for every wildcard subscriber. Under high bus throughput,
    splitting strings per message creates continuous garbage. Tokenizing or
    indexing without dynamic array allocations will improve bus throughput.

3. Edge Cases & Robustness

1.  vdrx_procutil.pas Polling Inefficiencies: WaitThreadOrTimeout and
    WaitProcessOrTimeout poll at Sleep(50) intervals. When stopping multiple
    processes or threads, these 50ms increments accumulate. A shorter initial
    backoff (e.g. 5ms ramping up to 25ms) or OS event handles would reduce
    shutdown latency.

2.  vdrx_templates.pas Row Allocation in Loops: ReplaceLoops instantiates and
    frees a new TStringList for every single row in a template loop (Merged :=
    TStringList.Create;). Reusing a single Merged instance across iterations
    within the loop avoids allocating objects in large table rendering.

3.  TVDRX_MessageQueue Queue Shift: TVDRX_MessageQueue.TryDequeue uses
    FList.Delete(0) on a TList<T>. In Free Pascal, deleting index 0 shifts the
    underlying array (O(N)). For large queue backlogs, switching to a
    ring-buffer or head-index queue maintains O(1) dequeues.

Suggested Priority for Refinements

| Priority | Item                                                                        | Impact                                            |
| :------- | :-------------------------------------------------------------------------- | :------------------------------------------------ |
| **P1**   | Fix `SendFrame` 64-bit frame header in `vdrx_network.pas`                   | Prevents WebSocket disconnects on large payloads  |
| **P1**   | Fix `ConnThread` lifecycle / double-free in `TVDRX_SocketListenerExecutive` | Prevents intermittent crashes on shutdown/reload  |
| **P2**   | Buffer `ReaderLoop` in `vdrx_bridge.pas` + drain on EOF                     | High CPU reduction & prevents lost process output |
| **P2**   | Pre-allocate HTTP body buffer in `ReadFullRequest`                          | Major performance gain for POST requests          |
| **P3**   | Optimize `ExtractHeaderValue` & `TopicMatches`                              | Reduces GC/heap allocation overhead on the bus    |

