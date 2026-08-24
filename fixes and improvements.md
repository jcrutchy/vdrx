Here is a detailed code analysis of the **VDRX** codebase, categorized by **Critical Bugs & Leaks**, **Concurrency & Reliability**, **Protocol & Correctness**, and **Performance & Simplifications**.

---

### 1. Critical Bugs & Resource Leaks

#### A. Massive Thread & Handle Leak on HTTP Connections (`vdrx_network.pas`) - FIXED
* **Location:** `TVDRX_SocketListenerExecutive` / `TVDRX_ListenerConnThread`
* **Issue:** In `TVDRX_ListenerConnThread.Create`, `FreeOnTerminate := False;` is set. When an HTTP connection finishes its request/response cycle, `UnregisterConnection(Self)` removes it from `FActiveConnections`, but **nothing ever calls `.Free` on `ConnThread`**.
* **Impact:** Every single HTTP request leaks a `TThread` object, its OS thread handle, and thread stack memory. Under regular traffic, the daemon will eventually exhaust system thread handles or RAM.
* **Fix:** When a connection finishes normally and `not FOwner.Stopping`, the thread should free itself or be marked for cleanup. Alternatively:
  ```pascal
  // In TVDRX_ListenerConnThread.Execute:
  procedure TVDRX_ListenerConnThread.Execute;
  begin
    FOwner.RegisterConnection(Self);
    try
      try
        FOwner.HandleConnection(FTransport);
      except end;
    finally
      FOwner.UnregisterConnection(Self);
      // Clean up self if terminated naturally
      FreeOnTerminate := True;
    end;
  end;
  ```

#### B. `TVDRX_Config.Reload` Drops Data on Syntax Error (`vdrx_config.pas`) - FIXED (I THINK?)
* **Location:** `TVDRX_Config.Reload`
* **Issue:** 
  ```pascal
  if Assigned(FData) then FData.Free;
  FData := TJSONObject(GetJSON(JSONString.Text));
  ```
  `FData` is freed *before* parsing the new file. If the updated `vdrx.conf` contains any syntax error (e.g., trailing comma), `GetJSON` raises an exception. `FData` remains a freed/invalid pointer (or `nil`), causing all subsequent `GetString`/`GetInteger` calls across the daemon to return default fallback values or crash.
* **Fix:** Parse into a local temporary variable first:
  ```pascal
  var NewData: TJSONData;
  ...
  NewData := GetJSON(JSONString.Text);
  if NewData is TJSONObject then
  begin
    if Assigned(FData) then FData.Free;
    FData := TJSONObject(NewData);
  end else
    NewData.Free;
  ```

#### C. WebSocket Teardown Use-After-Free (`vdrx_network.pas` & `vdrx_core.pas`) - NOT YET FIXED
* **Location:** `TVDRX_WSConnection.RunLoop` and `destructor TVDRX_WSConnection.Destroy`
* **Issue:** 
  1. `RunLoop` runs on `FThread`. At disconnect, it calls `FListener.Registry.UnregisterSelf(ID)`.
  2. `UnregisterSelf` removes `Self` from `FMasterMap` which has `[doOwnsValues]`, immediately executing `TVDRX_WSConnection.Destroy`.
  3. `Destroy` frees `FTransport` and `FSendLock`. However, `FPingThread` may still be running in `PingLoop` and calling `SendFrame` (which touches `FSendLock` and `FTransport`), leading to an Access Violation.
* **Fix:** `Destroy` should ensure `FPingThread` is terminated and joined/freed before freeing transport and synchronization primitives.

---

### 2. Concurrency & Reliability

#### A. Race Condition in `TVDRX_Registry.Unregister` (`vdrx_core.pas`)
* **Location:** `TVDRX_Registry.Unregister`
* **Issue:** `Exec.Shutdown` is called outside `FLock`, while `Exec` is still in `FMasterMap`. If two threads call `Unregister` on the same ID concurrently, both will call `Exec.Shutdown`, and the second thread may attempt to operate on already freed memory when `FMasterMap.Remove` runs.
* **Fix:** Extract the executive from `FMasterMap` inside the lock using `FMasterMap.ExtractPair` (so no other thread can look it up), and then call `Exec.Shutdown; Exec.Free;` outside the lock.

#### B. Double-Close on Listen Sockets (`vdrx_network.pas`)
* **Location:** `TVDRX_SocketListenerExecutive.Shutdown` & `AcceptLoopPlain`
* **Issue:** `Shutdown` calls `CloseSocket(FPlainSocket);`. When `AcceptLoopPlain` breaks out of its loop, it also calls `CloseSocket(FPlainSocket);`. On POSIX platforms, closing an already-closed file descriptor is dangerous because that descriptor ID might have already been re-allocated to another thread.
* **Fix:** Reset the socket variable upon closing:
  ```pascal
  if FPlainSocket <> 0 then
  begin
    CloseSocket(FPlainSocket);
    FPlainSocket := 0;
  end;
  ```

#### C. `AcceptLoop` Busy-Spin on Socket Errors (`vdrx_network.pas`)
* **Location:** `TVDRX_SocketListenerExecutive.AcceptLoopPlain` / `AcceptLoopTLS`
* **Issue:** If `fpAccept` fails with an unexpected error (or if `BindListenSocket` failed to bind and returned an invalid socket), `fpAccept` returns `-1` immediately. The loop executes `if ClientSock = -1 then Continue;` with no delay, causing **100% CPU core spinning**.
* **Fix:** Check if `ClientSock < 0` and sleep briefly (`Sleep(10)`) when `not FStopping`.

#### D. Missing `poSearchPath` for CLI Bridges (`vdrx_network.pas`)
* **Location:** `RunCLIScript`
* **Issue:** `Proc.Options := [poUsePipes, poStderrToOutPut];` lacks `poSearchPath`. If a route defines `command: "php"` rather than an absolute binary path (`"C:\php\php.exe"` or `"/usr/bin/php"`), `TProcess.Execute` will fail on systems where the binary is only resolvable via system `PATH`.
* **Fix:** Add `poSearchPath` to `Proc.Options`.

---

### 3. Protocol & Data Correctness

#### A. Malformed JSON Injection on Non-JSON Payloads (`vdrx_bridge.pas`)
* **Location:** `TVDRX_BridgeExecutive.HandlePacket`
* **Issue:**
  ```pascal
  Line := Format('{"topic":%s,"payload":%s,"source":%s}',
    [JSONString(AMsg.Topic), AMsg.Payload, JSONString(AMsg.SourceID)]) + LineEnding;
  ```
  `AMsg.Topic` and `AMsg.SourceID` are safely wrapped in `JSONString()`, but `AMsg.Payload` is passed raw. If a publisher sends a plain text payload (e.g. `hello world`), the formatted string is `{"topic":"...","payload":hello world,"source":"..."}`, which is invalid JSON.
* **Fix:** Test whether `AMsg.Payload` starts with `{`, `[`, `"`, or is a valid JSON primitive; if it is raw unquoted text, wrap it with `JSONString(AMsg.Payload)`.

#### B. WebSocket 64-bit Extended Length Frame Drop (`vdrx_network.pas`)
* **Location:** `TVDRX_WSConnection.ReadFrame`
* **Issue:** `else if LenByte = 127 then Exit;` immediately aborts and drops the connection if a client sends a frame with a 64-bit payload length (> 65,535 bytes).
* **Fix:** Read the 8-byte extended length header (or at least the lower 32 bits) rather than aborting.

#### C. `fpBind` Failure Silent Ignoring (`vdrx_network.pas`)
* **Location:** `TVDRX_SocketListenerExecutive.BindListenSocket`
* **Issue:** Return codes from `fpBind` and `fpListen` are not checked. If port binding fails (e.g. `EADDRINUSE` port conflict), the listener silently enters a broken accept loop instead of logging a fatal initialization error.
* **Fix:** Check `if fpBind(...) < 0 then` and log/raise a descriptive exception.

---

### 4. Performance Enhancements & Simplifications

#### A. 1-Byte Syscall Bottleneck in Bridge Reader (`vdrx_bridge.pas`)
* **Location:** `TVDRX_BridgeExecutive.ReaderLoop`
* **Issue:** `Proc.Output.Read(Ch, 1)` reads **one byte at a time** from the OS pipe stream. For high-output processes, this triggers hundreds of thousands of OS context switches per second.
* **Improvement:** Read in 4 KB chunks into a buffer and scan for `#10` in memory:
  ```pascal
  var
    Buf: array[0..4095] of AnsiChar;
    BytesRead, i: Integer;
  ...
  BytesRead := Proc.Output.Read(Buf[0], SizeOf(Buf));
  if BytesRead > 0 then
  begin
    for i := 0 to BytesRead - 1 do
    begin
      if Buf[i] = #10 then
      begin
        // Process completed Line
        Line := Trim(AccumulatedStr);
        AccumulatedStr := '';
        DispatchLine(Line);
      end
      else if Buf[i] <> #13 then
        AccumulatedStr := AccumulatedStr + Buf[i];
    end;
  end;
  ```

#### B. High-Frequency String Allocations in Topic Matching (`vdrx_core.pas`)
* **Location:** `TopicMatches`
* **Issue:** `Filter.Split(['.'])` and `Topic.Split(['.'])` allocate two dynamic string arrays on **every single message dispatch** for every wildcard subscriber.
* **Improvement:** Tokenize without dynamic array allocations by scanning with `PosEx` or pointer traversal, or cache pre-split filter segments on `TVDRX_Subscription`.

#### C. Template Cache Lookup from O(N) to O(1) (`vdrx_templates.pas`)
* **Location:** `TVDRX_TemplateStore`
* **Issue:** `FTemplates` is a `TStringList`, requiring `IndexOfName` (linear search) and string parsing on every template load.
* **Improvement:** Replace `TStringList` with `specialize TDictionary<string, string>` for $O(1)$ lock-protected cache queries.

#### D. Temporary Object Allocation in `SetReadTimeout` (`vdrx_network.pas`)
* **Location:** `TVDRX_TLSTransport.SetReadTimeout`
* **Issue:** `TVDRX_PlainTransport.Create(FSocket)` is instantiated and immediately freed just to call `fpSetsockopt`.
* **Improvement:** Extract `SetSocketTimeout(FSocket, ATimeoutMs)` into a standalone utility procedure.


~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


critical bug C1:

### Understanding the Bug

When a WebSocket client disconnects on its own, `TVDRX_WSConnection.RunLoop` breaks out of its read loop and calls:
```pascal
FListener.Registry.UnregisterSelf(ID);
```

Because `FRegistry.FMasterMap` has `[doOwnsValues]`, `UnregisterSelf` immediately invokes `destructor TVDRX_WSConnection.Destroy`, which frees `FTransport` and `FSendLock`.

This triggers three critical issues:
1. **Active Ping Loop Crash:** `FPingThread` is still executing `PingLoop` on a separate thread. The next time it runs `SendFrame('', 9)` or checks `FTransport`, it attempts to acquire `FSendLock` or write to `FTransport` (both of which were just freed), resulting in an **Access Violation**.
2. **Use-After-Free in `RunLoop`:** `RunLoop` is running on `FThread`. Freeing `Self` while inside one of its own methods means any subsequent field/property access or thread termination causes a use-after-free.
3. **Leaked Thread Object:** `FThread` was created with `FreeOnTerminate := False;` and is never freed on natural disconnects.

---

### Step-by-Step Fix

To fix this, we need to:
1. Ensure `FPingThread` is signaled, stopped, and freed **before** `FSendLock` or `FTransport` are destroyed.
2. Mark `TWSConnThread` with `FreeOnTerminate := True` so the connection thread cleans itself up upon exit.
3. Cache local variables in `RunLoop` before invoking `UnregisterSelf` so no member fields of `Self` are touched after deletion.

---

### Code Changes

#### 1. In `vdrx_network.pas` (`TVDRX_WSConnection.Initialize`)
Set `FThread.FreeOnTerminate := True;` so connection worker threads do not leak on disconnect:

```pascal
procedure TVDRX_WSConnection.Initialize;
begin
  FThread := TWSConnThread.Create(Self);
  FThread.FreeOnTerminate := True; // Automatically frees thread resource when RunLoop finishes
  FThread.Start;
end;
```

---

#### 2. In `vdrx_network.pas` (`TVDRX_WSConnection.RunLoop`)
Clean up `FPingThread` before publishing disconnect events and unregistering, and cache local references to prevent referencing a freed `Self`:

```pascal
procedure TVDRX_WSConnection.RunLoop;
var
  Payload: string;
  Opcode: Byte;
  Reg: TVDRX_Registry;
  ConnID: string;
begin
  if not DoHandshake then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake failed, dropping connection', ID);
    Reg := FListener.Registry;
    ConnID := ID;
    Reg.UnregisterSelf(ConnID);
    Exit;
  end;

  FLastPong := Now;
  FPingThread := TVDRX_WorkerThread.Create(@PingLoop);
  FPingThread.FreeOnTerminate := False;
  FPingThread.Start;

  while not FStopping do
  begin
    if not ReadFrame(Payload, Opcode) then Break;
    case Opcode of
      1: HandleRPC(Payload);
      9: SendFrame(Payload, 10); // client ping - echo back as pong, per spec
      10: FLastPong := Now;      // reply to OUR ping
    end;
  end;

  // 1. Signal shutdown to ping loop and join the ping thread FIRST
  FStopping := True;
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 1000);
    FreeAndNil(FPingThread);
  end;

  // 2. Publish disconnection notifications
  Bus.Publish('log.info', 'ws ' + ID + ': disconnected', ID);
  Bus.Publish('sys.ws.disconnected', Format('{"id":%s}', [JSONString(ID)]), ID);

  // 3. Cache registry and ID on stack so we don't access Self fields after UnregisterSelf
  Reg := FListener.Registry;
  ConnID := ID;

  // 4. Unregister (this calls Destroy on Self)
  Reg.UnregisterSelf(ConnID);
end;
```

---

#### 3. In `vdrx_network.pas` (`TVDRX_WSConnection.Shutdown` and `Destroy`)
Guard `Shutdown` and `Destroy` against double-frees and ensure `Destroy` safely tears down remaining resources if shutdown was triggered externally (e.g. via `sys.quit` or `sys.kill`):

```pascal
procedure TVDRX_WSConnection.Shutdown;
begin
  FStopping := True;
  if Assigned(FTransport) then
    FTransport.Close;

  // Stop and free ping thread
  if Assigned(FPingThread) then
  begin
    if WaitThreadOrTimeout(FPingThread, FListener.GracefulTimeoutMs) then
      FreeAndNil(FPingThread)
    else
      Bus.Publish('log.warn', 'ws ' + ID + ': ping thread did not exit in time - abandoning it', ID);
  end;

  // FThread has FreeOnTerminate := True, so we don't call FThread.Free here
  FThread := nil;
end;

destructor TVDRX_WSConnection.Destroy;
begin
  FStopping := True;

  // Fallback cleanup if Destroy was called directly without Shutdown
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 500);
    FreeAndNil(FPingThread);
  end;

  FreeAndNil(FTransport);
  FreeAndNil(FSendLock);
  inherited Destroy;
end;
```
