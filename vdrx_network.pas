unit vdrx_network;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, StrUtils, Sockets, SyncObjs, Process, vdrx_core,
  vdrx_config, vdrx_templates, vdrx_procutil, Generics.Collections,
  openssl, resolve, {$IFDEF UNIX}BaseUnix,{$ENDIF} base64, sha1, fpjson, jsonparser, DateUtils;

type

  TVDRX_SocketListenerExecutive = class;
  TVDRX_WebSocketExecutive = class;

  // One configured reverse-proxy target - see vdrx_daemon.conf's
  // "proxy_bridges" and vdrx_daemon.lpr's SetupProxyBridges. Prefix match is
  // longest-prefix-wins (like nginx location blocks), so overlapping
  // prefixes (e.g. "/app/" and "/app/admin/") behave predictably.
  TVDRX_ProxyRoute = record
    Prefix: string;
    Host: string;
    Port: Word;
  end;
  TVDRX_ProxyRoutes = array of TVDRX_ProxyRoute;

  // A one-shot-per-request PHP (or anything else) invocation, as opposed to
  // TVDRX_ProxyRoute's persistent Bridge-managed backend. No Registry/Bridge
  // involved at all - just this route table, consulted per request; the
  // process is spawned, run, and freed entirely within RunCLIScript (or
  // RunBusCLIScript, for Protocol='bus') below.
  //
  // Protocol distinguishes two entirely different wire contracts sharing one
  // route table and one prefix-matching mechanism (MatchCLIRoute):
  //
  //   'cgi' (default, original/unchanged behaviour) - Command is treated as
  //   just the interpreter ("php", "c:/php/php"); the URL path beyond Prefix
  //   is resolved to a script FILE under ScriptDir (see ResolveScriptPath)
  //   and appended as that interpreter's one parameter. The script talks CGI
  //   env vars (REQUEST_METHOD, QUERY_STRING, ...) and its raw stdout bytes
  //   become the response body verbatim - see RunCLIScript.
  //
  //   'bus' - Command is the FULL command line for a single fixed script
  //   that handles every request under Prefix, however deep
  //   ("php scripts/hello_bus.php", "cmd /c scripts\hello_bus.bat",
  //   "python3 scripts/hello_bus.py" - same free-form string TProcess.
  //   CommandLine already parses for vdrx_bridge.pas's persistent processes,
  //   reused here for a one-shot process instead). There's no per-path file
  //   lookup at all - Prefix behaves like a URL-rewrite base, and whatever
  //   comes after it (path suffix + query string) is handed to the script
  //   as DATA, not resolved to a file, so the script decides what it means.
  //   ScriptDir is optional here (just sets the process's working
  //   directory, default '.') since there's no ScriptDir-relative file
  //   resolution to do. The script reads exactly one JSON line off stdin -
  //   {"method":...,"path":...,"prefix":...,"sub_path":...,"query":...,
  //   "headers":{...},"body":...} - and must write exactly one JSON line
  //   back to stdout - {"status":200,"body":"..."} or
  //   {"status":200,"template":"name","params":{...},"rows":{...}} to have
  //   VDRX's own TVDRX_TemplateStore render it - before exiting. Same "only
  //   ever write the structured envelope to stdout, log anything else to a
  //   file instead" discipline scripts/irc_soylent.php already follows for
  //   vdrx_bridge.pas's persistent-process stdin/stdout protocol - see
  //   RunBusCLIScript's comment for why. This is the mechanism for a
  //   one-shot "script executed only by the HTTP request"; a long-running
  //   daemon that answers HTTP requests via a subscribed bus filter instead
  //   (the other half of the original design discussion) is a separate,
  //   not-yet-built piece - a persistent TVDRX_BridgeExecutive with a
  //   correlation-ID reply-topic scheme, not this one-shot-per-request path.
  //   'bus-daemon' - the persistent-subscriber counterpart to 'bus': instead
  //   of spawning a fresh process per request, the request envelope (same
  //   shape as 'bus' - see above) is published onto InTopic with a
  //   per-request "reply_to" added, and this route just waits (via
  //   TVDRX_OneShotWaiter, TimeoutMs-bounded) for a reply on that topic -
  //   see RunBusDaemonRoute. Whatever's subscribed to InTopic answers it;
  //   typically a persistent `processes` entry (the same kind already used
  //   for irc_bot), so many concurrent requests share one already-running
  //   process instead of paying spawn cost per request. Command/ScriptDir
  //   are unused for this protocol - InTopic is the only routing
  //   information needed, since VDRX isn't starting anything itself here.
  TVDRX_CLIRoute = record
    Prefix: string;
    Command: string;
    ScriptDir: string;
    TimeoutMs: Integer;
    ContentType: string;
    Protocol: string; // 'cgi' (default) | 'bus' | 'bus-daemon' - see comment above
    InTopic: string;  // only used by 'bus-daemon'
  end;
  TVDRX_CLIRoutes = array of TVDRX_CLIRoute;

  // Byte-stream abstraction over an accepted connection - lets every protocol
  // executive (HTTP, WebSocket) do its reads/writes without caring whether
  // the underlying socket is plaintext or TLS. Deliberately mirrors fpRecv/fpSend's
  // blocking, synchronous style - no event-loop rewrite needed anywhere else; every
  // existing "one thread per connection" executive keeps working exactly as before,
  // just talking to ATransport instead of a raw TSocket.
  TVDRX_Transport = class
  public
    function Read(var ABuf; ALen: Integer): Integer; virtual; abstract;
    function Write(const ABuf; ALen: Integer): Integer; virtual; abstract;
    procedure Close; virtual; abstract;
    procedure SetReadTimeout(ATimeoutMs: Integer); virtual; abstract;
  end;

  TVDRX_PlainTransport = class(TVDRX_Transport)
  private
    FSocket: TSocket;
  public
    constructor Create(ASocket: TSocket);
    function Read(var ABuf; ALen: Integer): Integer; override;
    function Write(const ABuf; ALen: Integer): Integer; override;
    procedure Close; override;
    procedure SetReadTimeout(ATimeoutMs: Integer); override;
  end;

  // One shared SSL_CTX per listener (holds the loaded cert/key) hands out one SSL*
  // per connection. The handshake runs in Create, on that connection's own thread -
  // same reasoning as everywhere else in this codebase: a slow/stalled TLS client
  // only blocks its own thread, never the accept loop or any other connection.
  //
  // Built against fpc's actual bundled openssl.pas (packages/openssl/src) - this is
  // a dynamically-loaded (dlopen-style) binding with Pascal-cased names (SslNew,
  // SslCtxNew, etc), NOT the raw C names (SSL_new, SSL_CTX_new). Every wrapper
  // function here lazily calls InitSSLInterface itself, so no explicit init call is
  // required - it'll just return failure/nil if libssl isn't found at runtime.
  TVDRX_TLSTransport = class(TVDRX_Transport)
  private
    FSocket: TSocket;
    FSSL: PSSL;
    FOK: Boolean;
  public
    // Server role (accept side) - unchanged from before.
    constructor Create(ASocket: TSocket; ACtx: PSSL_CTX); overload;
    // Client role (connect side) - SslConnect instead of SslAccept, plus SNI
    // (SSL_CTRL_SET_TLSEXT_HOSTNAME via SslCtrl - FPC's openssl unit has no
    // higher-level wrapper for this) so name-based virtual hosting on the
    // remote end works. AHostname drives SNI only; whether the resulting
    // cert is actually checked against it is governed by ACtx's own
    // verify-mode (see TVDRX_TLSClientContext) - this constructor doesn't
    // duplicate that decision.
    constructor Create(ASocket: TSocket; ACtx: PSSL_CTX; const AHostname: string); overload;
    destructor Destroy; override;
    property Handshook: Boolean read FOK; // caller checks this and drops the connection if False
    function Read(var ABuf; ALen: Integer): Integer; override;
    function Write(const ABuf; ALen: Integer): Integer; override;
    procedure Close; override;
    procedure SetReadTimeout(ATimeoutMs: Integer); override;
  end;

  // One per TLS-enabled listener - loads the cert/key once at Initialize time and
  // hands out the resulting context for TVDRX_TLSTransport to wrap each accepted
  // connection in. Deliberately doesn't crash the daemon if the cert/key don't load
  // - check .OK and skip bringing the TLS listener up if false.
  TVDRX_TLSContext = class
  private
    FCtx: PSSL_CTX;
    FOK: Boolean;
  public
    constructor Create(const ACertFile, AKeyFile: string);
    destructor Destroy; override;
    property OK: Boolean read FOK;
    property Ctx: PSSL_CTX read FCtx;
  end;

  // Client-role counterpart to TVDRX_TLSContext - no cert/key to load (we're
  // not presenting one), instead configures whether/how the REMOTE peer's
  // cert gets checked. AVerifyPeer=False (SSL_VERIFY_NONE) means TLS
  // encrypts the link but authenticates nobody - fine for quick testing
  // against a self-signed dev server, not fine for anything talking to the
  // open internet (see the MITM discussion in session notes). AVerifyPeer=
  // True with no ACAFile relies on whatever default paths FPC's openssl
  // unit's underlying libssl was built with - on Windows (which has no
  // system-wide CA bundle location the way most Linux distros do) that
  // usually means nothing is found and every handshake fails outright, so
  // supplying a real ACAFile is effectively mandatory there - see
  // ApplyOpenSSLDLLOverrides's unit comment for the parallel DLL-location
  // problem. FOK reflects only "was the context itself constructable" -
  // whether verification succeeds is a per-handshake outcome, checked via
  // TVDRX_TLSTransport.Handshook after Create.
  TVDRX_TLSClientContext = class
  private
    FCtx: PSSL_CTX;
    FOK: Boolean;
  public
    constructor Create(const ACAFile: string; AVerifyPeer: Boolean);
    destructor Destroy; override;
    property OK: Boolean read FOK;
    property Ctx: PSSL_CTX read FCtx;
  end;

  TVDRX_ListenerConnThread = class(TThread)
  private
    FOwner: TVDRX_SocketListenerExecutive;
    FTransport: TVDRX_Transport;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
    // Exposed so Shutdown can force-close a hung connection's transport to
    // unblock a blocking Read/Write that FStopping alone can't interrupt.
    property Transport: TVDRX_Transport read FTransport;
  end;

  TVDRX_SocketListenerExecutive = class(TVDRX_Executive)
  private
    FPort: Word;
    FTLSPort: Word;
    FTLSCertFile: string;
    FTLSKeyFile: string;
    FTLSContext: TVDRX_TLSContext;
    FBacklog: Integer;
    FPlainSocket: TSocket;
    FTLSSocket: TSocket;
    FPlainThread: TThread;
    FTLSThread: TThread;
    FStopping: Boolean;
    FGracefulTimeoutMs: Integer;

    // Thread tracking synchronization
    FCriticalSection: TCriticalSection;
    FActiveConnections: TList;

    function BindListenSocket(APort: Word): TSocket;
    procedure AcceptLoopPlain;
    procedure AcceptLoopTLS;
    // Polls FActiveConnections membership (rather than AThread.Finished/Free)
    // to learn when a connection thread is done - see the long comment on
    // Shutdown below for why touching the TThread object itself after it may
    // have self-freed via FreeOnTerminate is unsafe.
    function WaitConnGone(AThread: TVDRX_ListenerConnThread; ATimeoutMs: Integer): Boolean;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); virtual; abstract;

    // Called by TVDRX_ListenerConnThread during life cycle
    procedure RegisterConnection(AThread: TVDRX_ListenerConnThread);
    procedure UnregisterConnection(AThread: TVDRX_ListenerConnThread);
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    property Port: Word read FPort write FPort;
    property TLSPort: Word read FTLSPort;
    function TLSActive: Boolean;
    procedure ConfigureTLS(ATLSPort: Word; const ACertFile, AKeyFile: string);
    property Backlog: Integer read FBacklog write FBacklog;
    property Stopping: Boolean read FStopping;
    // How long Shutdown waits for accept/connection threads to exit on their
    // own before force-closing their sockets to unblock a hung blocking
    // Read/Write. Defaults to 5000ms; set from vdrx_daemon.conf's top-level
    // "shutdown_grace_ms" in vdrx_daemon.lpr.
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    procedure Initialize; override;
    procedure Shutdown; override;
  end;

  TVDRX_WebListenerExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FWebSocket: TVDRX_WebSocketExecutive;
    FTemplates: TVDRX_TemplateStore;
    FConfig: TVDRX_Config;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue;
      AWebSocket: TVDRX_WebSocketExecutive; ATemplates: TVDRX_TemplateStore;
      AConfig: TVDRX_Config; const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes;
      const ACLIRoutes: TVDRX_CLIRoutes); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

  // Bounds RunCLIScript's wall-clock time WITHOUT blocking the read loop that
  // drains the child's stdout - see RunCLIScript's comment for why those two
  // things have to happen concurrently, not one after the other.
  TCLIWatchdog = class
  private
    FProc: TProcess;
    FTimeoutMs: Integer;
    FCancelled: Boolean;
    FFired: Boolean;
  public
    constructor Create(AProc: TProcess; ATimeoutMs: Integer);
    procedure Run;
    procedure Cancel;
    property Fired: Boolean read FFired;
  end;

  // Generic "publish a request, block this thread until a correlated reply
  // arrives (or a timeout), tear down" primitive - the building block behind
  // both RunBusDaemonRoute (a persistent, subscribed process answering many
  // HTTP requests, rather than one spawned per request - see
  // TVDRX_CLIRoute's "bus-daemon" protocol) and a bus-mode reply's optional
  // "template_topic" field (routing template rendering through a specific,
  // explicitly-named TVDRX_TemplateExecutive rather than whichever HTTP
  // site's own TVDRX_TemplateStore happened to answer the connection - see
  // vdrx_templates.pas).
  //
  // Deliberately NOT a long-lived subscriber: one instance answers exactly
  // one reply, on a reply topic minted uniquely per call (see
  // NextReplyTopic) so concurrent callers never collide, then it's torn
  // down. This mirrors what a WS connection or a Bridge already is
  // (registered-with-the-Registry, delivered to via HandlePacket) but for a
  // single request/response instead of a connection's whole lifetime -
  // the same Registry filter-match mechanism, just used for one round trip.
  TVDRX_OneShotWaiter = class(TVDRX_Executive)
  private
    FEvent: TEvent;
    FReplyPayload: string;
    FGotReply: Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue);
    destructor Destroy; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    // Blocks the CALLING thread (not a thread of the waiter's own - it has
    // none) until HandlePacket fires or ATimeoutMs elapses. Caller is
    // responsible for Registry.Unregister(ID)'ing this waiter afterwards
    // either way - see PublishAndWait below, which always does both
    // regardless of which one happened.
    function WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
  end;

  TVDRX_HTTPExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FTemplates: TVDRX_TemplateStore;
    FStaticDir: string;
    FProxyRoutes: TVDRX_ProxyRoutes;
    FCLIRoutes: TVDRX_CLIRoutes;
    FRegistry: TVDRX_Registry;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config;
      ATemplates: TVDRX_TemplateStore;
      const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes;
      const ACLIRoutes: TVDRX_CLIRoutes; ARegistry: TVDRX_Registry); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    class function BuildResponse(const ARequest: string;
      ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
      const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
      ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
  end;

  // Pure connectivity - the WS handshake, frame read/write, ping/pong
  // keepalive, and relaying bus traffic to/from the socket. Deliberately
  // contains NO interpretation of what a client's text frame MEANS - see
  // TVDRX_WSProtocolExecutive below for that half of the split. A text
  // frame's raw JSON is simply republished onto "<ID>.rpc.in" for whichever
  // protocol executive is subscribed there to interpret (see AdoptConnection
  // in TVDRX_WebSocketExecutive, which creates one alongside every
  // connection); this class never parses it. The one thing this class keeps
  // that could be argued as "protocol" is HandlePacket's ordinary bus->socket
  // forwarding envelope - {"topic":...,"payload":...,"source":...,"seq":...}
  // - but that's the wire format for "a browser is a bus participant" itself
  // (see the readme's §5), not any one RPC method's interpretation of it, so
  // it stays here; a "<ID>.rpc.out" topic is special-cased instead, to let
  // the protocol executive send an already-fully-formed reply line (e.g.
  // "auth.ok") verbatim rather than have it wrapped in that envelope too.
  TVDRX_WSConnection = class(TVDRX_Executive)
  private
    FListener: TVDRX_WebSocketExecutive;
    FTransport: TVDRX_Transport;
    FThread: TThread;
    FSendLock: TCriticalSection;
    FPendingRequest: string;

    FPingThread: TThread;
    FStopping: Boolean;
    FLastPong: TDateTime;
    procedure PingLoop;

    function DoHandshake: Boolean;
    function ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
    destructor Destroy; override;
    property PendingRequest: string read FPendingRequest write FPendingRequest;
    procedure SendFrame(const APayload: string; AOpcode: Byte = 1);
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure RunLoop;
    class function IsUpgradeRequest(const ARequest: string): Boolean;
  end;

  // The "protocol" half of the split above - all of what used to be
  // TVDRX_WSConnection.HandleRPC, now living in its own Registry-registered
  // executive, subscribed only to its connection's "<ID>.rpc.in" topic
  // (never touching FTransport, never seeing raw WS frames or opcodes).
  // sys.auth/subscribe/unsubscribe/unsubscribe_all/publish - the entire
  // client-facing JSON-RPC surface - is interpreted here.
  //
  // The one unavoidable coupling to the connectivity object: subscribe/
  // unsubscribe/unsubscribe_all have to call Registry.Register/
  // UnregisterFilter/ClearFilters against the CONNECTIVITY object's own ID
  // (it's the one whose HandlePacket can actually reach the socket) - and
  // Register's signature needs an actual TVDRX_Executive reference, not
  // just an ID string, the one time a NEW filter is being added. FConn
  // exists solely to satisfy that - this class never calls a method on it
  // that touches the transport (SendFrame included: an outgoing reply is
  // published to "<ID>.rpc.out" instead, for the connectivity object's own
  // HandlePacket to relay - see its comment above).
  TVDRX_WSProtocolExecutive = class(TVDRX_Executive)
  private
    FListener: TVDRX_WebSocketExecutive;
    FConn: TVDRX_WSConnection;
    FAuthenticated: Boolean;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; AConn: TVDRX_WSConnection); reintroduce;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

  TVDRX_WebSocketExecutive = class(TVDRX_SocketListenerExecutive)
  private
    FConfig: TVDRX_Config;
    FRegistry: TVDRX_Registry;
    FConnCounter: Integer;
    FPingIntervalMs, FPongTimeoutMs: Integer;
  protected
    procedure HandleConnection(ATransport: TVDRX_Transport); override;
  public
    constructor Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry); reintroduce;
    property Registry: TVDRX_Registry read FRegistry;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
    procedure ApplyConfig; override;
    function NextConnID: string;
    procedure AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
    property PingIntervalMs: Integer read FPingIntervalMs write FPingIntervalMs;
    property PongTimeoutMs: Integer read FPongTimeoutMs write FPongTimeoutMs;
  end;

  // Generic outbound socket client - the dialer counterpart to
  // TVDRX_SocketListenerExecutive's accept side. Deliberately protocol-blind:
  // it moves bytes/lines between one remote TCP/TLS connection and the bus,
  // publishing to "<ID>.out" and writing whatever this executive is
  // registered to receive straight to the socket (see HandlePacket) -
  // exactly mirroring TVDRX_BridgeExecutive's "<ID>.out"/stdin convention,
  // so a bus consumer can't tell an IRC-over-TLS socket client from a
  // bridged PHP process. All actual protocol handling (IRC's NICK/USER,
  // PING/PONG, etc.) lives entirely in whatever's subscribed to this
  // executive's output - same "VDRX owns the wire, something else owns the
  // protocol" split as Bridge, just for a connection VDRX dials itself
  // instead of one it spawns.
  //
  // Framing is deliberately limited to two modes rather than an open-ended
  // plugin system - see session notes for why: line-oriented protocols
  // (IRC, SMTP, ...) and raw byte-chunk protocols cover every case actually
  // in front of this, and a fancier scheme (length-prefixed, etc.) is easy
  // to add later against a second real use case rather than guessed at now.
  // Reading is deliberately more lenient than writing in delimiter mode -
  // see ReaderLoop.
  TVDRX_SocketClientExecutive = class(TVDRX_Executive)
  private
    FHost: string;
    FPort: Word;
    FTLS: Boolean;
    FTLSVerify: Boolean;
    FTLSCAFile: string;
    FTLSPeerName: string; // SNI hostname; falls back to FHost if left blank
    FFraming: string;     // 'delimiter' (default) | 'chunk'
    FDelimiter: string;   // write-side terminator; default #13#10
    FChunkSize: Integer;  // used when FFraming = 'chunk'
    FReconnectPolicy: string; // 'auto' (default, backoff-retry) | 'none' (dial once, stay down)
    FReconnectDelayMs, FMaxReconnectDelayMs: Integer;
    FGracefulTimeoutMs: Integer;

    FTransport: TVDRX_Transport;
    FTransportLock: TCriticalSection;
    FConnected: Boolean; // reader loop's substitute for "process still running" -
                          // there's no exit code for a dropped socket, just
                          // "the last Read failed"
    FReaderThread: TThread;
    FMonitorThread: TThread;
    FStopping: Boolean;

    procedure DoConnect;
    procedure DoDisconnect;
    procedure ReaderLoop;
    procedure MonitorLoop;
  public
    constructor Create(ABus: TVDRX_MessageQueue); override;
    destructor Destroy; override;
    property Host: string read FHost write FHost;
    property Port: Word read FPort write FPort;
    property TLS: Boolean read FTLS write FTLS;
    property TLSVerify: Boolean read FTLSVerify write FTLSVerify;
    property TLSCAFile: string read FTLSCAFile write FTLSCAFile;
    property TLSPeerName: string read FTLSPeerName write FTLSPeerName;
    property Framing: string read FFraming write FFraming;
    property Delimiter: string read FDelimiter write FDelimiter;
    property ChunkSize: Integer read FChunkSize write FChunkSize;
    property ReconnectPolicy: string read FReconnectPolicy write FReconnectPolicy;
    property ReconnectDelayMs: Integer read FReconnectDelayMs write FReconnectDelayMs;
    property MaxReconnectDelayMs: Integer read FMaxReconnectDelayMs write FMaxReconnectDelayMs;
    property GracefulTimeoutMs: Integer read FGracefulTimeoutMs write FGracefulTimeoutMs;
    procedure Initialize; override;
    procedure Shutdown; override;
    procedure HandlePacket(const AMsg: TVDRX_Message); override;
  end;

const
  MAX_HEADER_SIZE = 16384;
  MAX_BODY_SIZE = 10 * 1024 * 1024; // generous for dev/test form posts - not meant for large uploads
  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

// Opens a client TCP connection to AHost:APort - for reverse-proxying to a
// locally-managed backend (see vdrx_http.pas's proxy_bridges). Returns nil
// on failure. IPv4 dotted-quad host only (matches this whole codebase's
// AF_INET-only assumption elsewhere) and plaintext only - nothing here
// talks TLS as a CLIENT, which is fine since backends are loopback-only by
// design (see vdrx_http.pas's ProxyRequest).
function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;

// Same as ConnectTCP, but resolves AHost via DNS (resolve.THostResolver)
// when it isn't a bare IPv4 literal - for TVDRX_SocketClientExecutive
// dialing an arbitrary remote host, unlike ConnectTCP's loopback-only
// backends. Still IPv4/AF_INET only (matches the rest of this codebase).
// Returns nil on either resolution or connect failure - no exception, same
// contract as ConnectTCP.
function ConnectTCPHost(const AHost: string; APort: Word): TVDRX_Transport;

// Reads tls_ssl_dll/tls_crypto_dll (top-level config keys) and, if either
// is set, assigns them to FPC's openssl unit's DLLSSLName/DLLUtilName
// globals before anything calls into it - see vdrx.lpr for call site (must
// run before Registry.InitializeAll, i.e. before any TLS-using executive's
// Initialize). Windows-only: Linux distros almost always have libssl
// discoverable via the unversioned name already (see hogircd's
// libssl-dev-vs-libssl3 note); Windows has no equivalent system-wide
// location, which is the actual problem this solves (see session notes -
// bot.lpr's "Could not initialize OpenSSL library" against OpenSSL 4.x).
// A no-op with nothing configured, so existing Linux-only deployments are
// unaffected either way.
procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);

implementation

// Parses a plain "a.b.c.d" IPv4 address into the 4 bytes sockaddr_in.sin_addr
// needs, in the correct (network) byte order - dotted-quad notation is
// already MSB-first, so filling Bytes[0..3] in left-to-right reading order
// and copying them straight into sin_addr is correct with no byte-swap step.
// Deliberately hand-rolled rather than relying on the Sockets unit's own
// string-to-address helper: an earlier version of this function used
// StrToHostAddr and was never actually verified against this FPC version -
// it silently produced the wrong address, which is why every connect()
// attempt hung for ~21s (Windows' default SYN-retry timeout for a target
// that never responds) instead of failing or succeeding immediately.
function ParseIPv4(const AHost: string; out AAddr: Cardinal): Boolean;
var
  Parts: TStringArray;
  i, b: Integer;
  Bytes: array[0..3] of Byte;
begin
  Result := False;
  Parts := AHost.Split(['.']);
  if Length(Parts) <> 4 then Exit;
  for i := 0 to 3 do
  begin
    if not TryStrToInt(Parts[i], b) then Exit;
    if (b < 0) or (b > 255) then Exit;
    Bytes[i] := Byte(b);
  end;
  Move(Bytes[0], AAddr, 4);
  Result := True;
end;

// to get around lack of poSearchPath in process.TProcessOptions
function ProcessFindInPath(const Exe: string): string;
var
  Paths: TStringList;
  Dir: string;
  Candidate: string;
begin
  Result := Exe;  // default return value

  // If Exe already contains a path, don't search PATH
  if (Pos(PathDelim, Exe) > 0) or (Pos('/', Exe) > 0) then
    Exit;

  Paths := TStringList.Create;
  try
    Paths.Delimiter := PathSeparator;
    Paths.StrictDelimiter := True;
    Paths.DelimitedText := GetEnvironmentVariable('PATH');

    for Dir in Paths do
    begin
      Candidate := IncludeTrailingPathDelimiter(Dir) + Exe;
      if FileExists(Candidate) then
      begin
        Result := Candidate;
        Exit;
      end;
    end;
  finally
    Paths.Free;
  end;
end;


function ConnectTCP(const AHost: string; APort: Word): TVDRX_Transport;
var
  Sock: TSocket;
  Addr: TInetSockAddr;
  IPBytes: Cardinal;
begin
  Result := nil;
  if not ParseIPv4(AHost, IPBytes) then Exit; // dotted-quad IPv4 only - matches the loopback-only proxy design, no DNS resolution needed
  Sock := fpSocket(AF_INET, SOCK_STREAM, 0);
  if Sock < 0 then Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Move(IPBytes, Addr.sin_addr, SizeOf(Addr.sin_addr));
  if fpConnect(Sock, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(Sock);
    Exit;
  end;
  Result := TVDRX_PlainTransport.Create(Sock);
end;

// Shared by ConnectTCPHost (below) and TVDRX_SocketClientExecutive.DoConnect
// - the TLS path needs the raw connected TSocket (to wrap in
// TVDRX_TLSTransport itself), not a TVDRX_Transport already wrapping one, so
// this is the one place the actual resolve+connect happens and both callers
// build on it instead of duplicating it.
function ConnectRawSocket(const AHost: string; APort: Word; out ASocket: TSocket): Boolean;
var
  Addr: TInetSockAddr;
  IPBytes: Cardinal;
  Resolver: THostResolver;
  NetAddr: THostAddr;
begin
  Result := False;
  ASocket := -1;
  if not ParseIPv4(AHost, IPBytes) then
  begin
    // Not a bare dotted-quad - resolve it. THostResolver wraps the
    // platform's own resolver (getaddrinfo/gethostbyname under the hood),
    // so this works the same on Windows and Unix without any extra
    // platform-specific code here.
    Resolver := THostResolver.Create(nil);
    try
      if not Resolver.NameLookup(AHost) then Exit; // resolution failed - no such host, or no network
      NetAddr := Resolver.NetHostAddress; // already network-byte-order (in_addr) - matches sin_addr directly
      Move(NetAddr, IPBytes, SizeOf(IPBytes));
    finally
      Resolver.Free;
    end;
  end;
  ASocket := fpSocket(AF_INET, SOCK_STREAM, 0);
  if ASocket < 0 then Exit;
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Move(IPBytes, Addr.sin_addr, SizeOf(Addr.sin_addr));
  if fpConnect(ASocket, @Addr, SizeOf(Addr)) <> 0 then
  begin
    CloseSocket(ASocket);
    ASocket := -1;
    Exit;
  end;
  Result := True;
end;

function ConnectTCPHost(const AHost: string; APort: Word): TVDRX_Transport;
var
  Sock: TSocket;
begin
  Result := nil;
  if not ConnectRawSocket(AHost, APort, Sock) then Exit;
  Result := TVDRX_PlainTransport.Create(Sock);
end;

// See this function's interface comment for the general shape. Only
// Windows actually needs the override - Linux almost always finds libssl
// via the unversioned name once libssl-dev's symlink is present (see the
// hogircd session notes), so on Unix this is a documented no-op even if
// tls_ssl_dll/tls_crypto_dll happen to be set in a config shared across
// platforms.
procedure ApplyOpenSSLDLLOverrides(AConfig: TVDRX_Config);
{$IFDEF WINDOWS}
var
  SSLDll, CryptoDll: string;
{$ENDIF}
begin
  {$IFDEF WINDOWS}
  SSLDll := AConfig.GetString('tls_ssl_dll', '');
  CryptoDll := AConfig.GetString('tls_crypto_dll', '');
  if SSLDll <> '' then DLLSSLName := SSLDll;
  if CryptoDll <> '' then DLLUtilName := CryptoDll;
  {$ENDIF}
end;

{ TVDRX_PlainTransport }

constructor TVDRX_PlainTransport.Create(ASocket: TSocket);
begin
  inherited Create;
  FSocket := ASocket;
end;

function TVDRX_PlainTransport.Read(var ABuf; ALen: Integer): Integer;
begin
  Result := fpRecv(FSocket, @ABuf, ALen, 0);
end;

function TVDRX_PlainTransport.Write(const ABuf; ALen: Integer): Integer;
begin
  Result := fpSend(FSocket, @ABuf, ALen, 0);
end;

procedure TVDRX_PlainTransport.Close;
begin
  CloseSocket(FSocket);
end;

procedure TVDRX_PlainTransport.SetReadTimeout(ATimeoutMs: Integer);
{$IFDEF UNIX}
var
  TV: TimeVal;
begin
  TV.tv_sec := ATimeoutMs div 1000;
  TV.tv_usec := (ATimeoutMs mod 1000) * 1000;
  fpSetsockopt(FSocket, SOL_SOCKET, SO_RCVTIMEO, @TV, SizeOf(TV));
end;
{$ENDIF}
{$IFDEF WINDOWS}
var
  Timeout: DWORD;
begin
  Timeout := ATimeoutMs;
  fpSetsockopt(FSocket, SOL_SOCKET, SO_RCVTIMEO, @Timeout, SizeOf(Timeout));
end;
{$ENDIF}

{ TVDRX_TLSTransport }

constructor TVDRX_TLSTransport.Create(ASocket: TSocket; ACtx: PSSL_CTX);
begin
  inherited Create;
  FSocket := ASocket;
  FSSL := SslNew(ACtx);
  SslSetFd(FSSL, FSocket);
  FOK := Assigned(FSSL) and (SslAccept(FSSL) = 1); // blocking - fine, runs on this connection's own thread
end;

constructor TVDRX_TLSTransport.Create(ASocket: TSocket; ACtx: PSSL_CTX; const AHostname: string);
begin
  inherited Create;
  FSocket := ASocket;
  if not Assigned(ACtx) then Exit; // FOK stays False (default) - see this constructor's interface comment; guards against SslSetFd(nil, ...) below, which segfaults in native OpenSSL with no nil-check of its own
  FSSL := SslNew(ACtx);
  if not Assigned(FSSL) then Exit;
  SslSetFd(FSSL, FSocket);
  if AHostname <> '' then
    // SNI - FPC's openssl unit has no SslSetTlsExtHostName wrapper, so this
    // goes through the generic SslCtrl the same way the C
    // SSL_set_tlsext_host_name() macro does.
    SslCtrl(FSSL, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, PChar(AHostname));
  FOK := (SslConnect(FSSL) = 1); // blocking - runs on this connection's own thread, same as the server-role constructor above
end;

destructor TVDRX_TLSTransport.Destroy;
begin
  if Assigned(FSSL) then
    SslFree(FSSL);
  inherited Destroy;
end;

function TVDRX_TLSTransport.Read(var ABuf; ALen: Integer): Integer;
begin
  if not FOK then Exit(-1);
  Result := SslRead(FSSL, @ABuf, ALen);
end;

function TVDRX_TLSTransport.Write(const ABuf; ALen: Integer): Integer;
begin
  if not FOK then Exit(-1);
  Result := SslWrite(FSSL, @ABuf, ALen);
end;

procedure TVDRX_TLSTransport.Close;
begin
  if Assigned(FSSL) then
    SslShutdown(FSSL);
  FOK := False;
  CloseSocket(FSocket);
end;

procedure TVDRX_TLSTransport.SetReadTimeout(ATimeoutMs: Integer);
var
  PlainTemp: TVDRX_PlainTransport;
begin
  // Delegate socket timeout configuration to underlying socket via temporary plain wrapper or direct options
  PlainTemp := TVDRX_PlainTransport.Create(FSocket);
  try
    PlainTemp.SetReadTimeout(ATimeoutMs);
  finally
    PlainTemp.Free;
  end;
end;

{ TVDRX_TLSContext }

constructor TVDRX_TLSContext.Create(const ACertFile, AKeyFile: string);
begin
  inherited Create;
  // SslTLSMethod loads the 'TLS_method' symbol - the modern, version-negotiating
  // method that works for both accept (server) and connect (client) roles; which
  // role you get is determined by calling SslAccept vs SslConnect, not by the
  // method object. (SslMethodV23 / 'SSLv23_method' is NOT used here - that symbol
  // was dropped from OpenSSL 1.1+/3.x and this unit itself flags it as
  // "method not supported by lib".)
  FCtx := SslCtxNew(SslTLSMethod);
  FOK := Assigned(FCtx)
    and (SslCtxUseCertificateFile(FCtx, ACertFile, SSL_FILETYPE_PEM) = 1)
    and (SslCtxUsePrivateKeyFile(FCtx, AKeyFile, SSL_FILETYPE_PEM) = 1);
end;

destructor TVDRX_TLSContext.Destroy;
begin
  if Assigned(FCtx) then
    SslCtxFree(FCtx);
  inherited Destroy;
end;

{ TVDRX_TLSClientContext }

constructor TVDRX_TLSClientContext.Create(const ACAFile: string; AVerifyPeer: Boolean);
begin
  inherited Create;
  FCtx := SslCtxNew(SslTLSMethod); // same version-negotiating method as the server context - see its comment
  FOK := Assigned(FCtx);
  if not FOK then Exit;
  if AVerifyPeer then
  begin
    SslCtxSetVerify(FCtx, SSL_VERIFY_PEER, nil);
    if ACAFile <> '' then
      FOK := (SslCtxLoadVerifyLocations(FCtx, ACAFile, '') = 1)
    {$IFDEF UNIX}
    // No CA file configured - fall back to the common Debian/Ubuntu/RHEL
    // bundle location most Linux systems already have, rather than silently
    // failing every handshake. Windows has no equivalent well-known path -
    // ACAFile is effectively mandatory there (see this class's interface
    // comment) - so no fallback attempt is made under {$IFDEF WINDOWS}.
    else if FileExists('/etc/ssl/certs/ca-certificates.crt') then
      FOK := (SslCtxLoadVerifyLocations(FCtx, '/etc/ssl/certs/ca-certificates.crt', '') = 1)
    {$ENDIF}
    ;
  end
  else
    SslCtxSetVerify(FCtx, SSL_VERIFY_NONE, nil);
end;

destructor TVDRX_TLSClientContext.Destroy;
begin
  if Assigned(FCtx) then
    SslCtxFree(FCtx);
  inherited Destroy;
end;

constructor TVDRX_ListenerConnThread.Create(AOwner: TVDRX_SocketListenerExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(True);
  FOwner := AOwner;
  FTransport := ATransport;
  FreeOnTerminate := False; // Managed manually by the executive for graceful shutdown tracking
end;

procedure TVDRX_ListenerConnThread.Execute;
begin
  FOwner.RegisterConnection(Self);
  try
    try
      FOwner.HandleConnection(FTransport);
    except
      // Isolate connection exceptions
    end;
  finally
    FOwner.UnregisterConnection(Self);
    FreeOnTerminate := True;
  end;
end;

{ TVDRX_SocketListenerExecutive }

constructor TVDRX_SocketListenerExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FBacklog := 16;
  FGracefulTimeoutMs := 5000;
  FCriticalSection := TCriticalSection.Create;
  FActiveConnections := TList.Create;
end;

destructor TVDRX_SocketListenerExecutive.Destroy;
begin
  FActiveConnections.Free;
  FCriticalSection.Free;
  FTLSContext.Free;
  inherited Destroy;
end;

procedure TVDRX_SocketListenerExecutive.RegisterConnection(AThread: TVDRX_ListenerConnThread);
begin
  FCriticalSection.Acquire;
  try
    if not FStopping then
      FActiveConnections.Add(AThread);
  finally
    FCriticalSection.Release;
  end;
end;

procedure TVDRX_SocketListenerExecutive.UnregisterConnection(AThread: TVDRX_ListenerConnThread);
begin
  FCriticalSection.Acquire;
  try
    FActiveConnections.Remove(AThread);
  finally
    FCriticalSection.Release;
  end;
end;

procedure TVDRX_SocketListenerExecutive.ConfigureTLS(ATLSPort: Word; const ACertFile, AKeyFile: string);
begin
  FTLSPort := ATLSPort;
  FTLSCertFile := ACertFile;
  FTLSKeyFile := AKeyFile;
end;

function TVDRX_SocketListenerExecutive.BindListenSocket(APort: Word): TSocket;
var
  Addr: TInetSockAddr;
  OptVal: LongInt;
begin
  Result := fpSocket(AF_INET, SOCK_STREAM, 0);
  OptVal := 1;
  fpSetSockOpt(Result, SOL_SOCKET, SO_REUSEADDR, @OptVal, SizeOf(OptVal));
  FillChar(Addr, SizeOf(Addr), 0);
  Addr.sin_family := AF_INET;
  Addr.sin_port := htons(APort);
  Addr.sin_addr.s_addr := 0;
  if fpBind(Result, @Addr, SizeOf(Addr)) <> 0 then
  begin
    Bus.Publish('log.error', ID + ': fpBind failed on port ' + IntToStr(APort) +
      ' (errno ' + IntToStr(socketerror) + ') - port likely already in use', ID);
    CloseSocket(Result);
    Exit(-1); // caller must check for -1 rather than trying to accept on a dead/invalid socket
  end;
  if fpListen(Result, FBacklog) <> 0 then
  begin
    Bus.Publish('log.error', ID + ': fpListen failed on port ' + IntToStr(APort) +
      ' (errno ' + IntToStr(socketerror) + ')', ID);
    CloseSocket(Result);
    Exit(-1);
  end;
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopPlain;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  ConnThread: TVDRX_ListenerConnThread;
begin
  FPlainSocket := BindListenSocket(FPort);
  if FPlainSocket = -1 then
  begin
    FPlainSocket := 0;
    Exit; // bind/listen already logged the reason above; nothing to accept on
  end;
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FPlainSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
    begin
      // An unexpected accept error (anything other than the socket having
      // just been closed for shutdown, which the FStopping check above
      // already handles) used to hit this in a tight loop with no wait,
      // pegging a CPU core. Give the error a moment to clear.
      if not FStopping then
        Sleep(10);
      Continue;
    end;

    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        CloseSocket(ClientSock);
        Break;
      end;
      ConnThread := TVDRX_ListenerConnThread.Create(Self, TVDRX_PlainTransport.Create(ClientSock));
    finally
      FCriticalSection.Release;
    end;
    ConnThread.Start;
  end;
  // Shutdown may have already closed FPlainSocket to unblock fpAccept above -
  // guard against closing an already-closed (and possibly since-reused, on
  // POSIX) descriptor a second time.
  if FPlainSocket <> 0 then
  begin
    CloseSocket(FPlainSocket);
    FPlainSocket := 0;
  end;
end;

procedure TVDRX_SocketListenerExecutive.AcceptLoopTLS;
var
  ClientAddr: TInetSockAddr;
  AddrLen: TSockLen;
  ClientSock: TSocket;
  Transport: TVDRX_TLSTransport;
  ConnThread: TVDRX_ListenerConnThread;
begin
  FTLSSocket := BindListenSocket(FTLSPort);
  if FTLSSocket = -1 then
  begin
    FTLSSocket := 0;
    Exit;
  end;
  while not FStopping do
  begin
    AddrLen := SizeOf(ClientAddr);
    ClientSock := fpAccept(FTLSSocket, @ClientAddr, @AddrLen);
    if ClientSock = -1 then
    begin
      if not FStopping then
        Sleep(10);
      Continue;
    end;

    Transport := TVDRX_TLSTransport.Create(ClientSock, FTLSContext.Ctx);
    if not Transport.Handshook then
    begin
      Transport.Free;
      Continue;
    end;

    FCriticalSection.Acquire;
    try
      if FStopping then
      begin
        Transport.Free;
        Break;
      end;
      ConnThread := TVDRX_ListenerConnThread.Create(Self, Transport);
    finally
      FCriticalSection.Release;
    end;
    ConnThread.Start;
  end;
  if FTLSSocket <> 0 then
  begin
    CloseSocket(FTLSSocket);
    FTLSSocket := 0;
  end;
end;

function TVDRX_SocketListenerExecutive.TLSActive: Boolean;
begin
  Result := Assigned(FTLSThread);
end;

procedure TVDRX_SocketListenerExecutive.Initialize;
begin
  FStopping := False;
  if FPort <> 0 then
  begin
    FPlainThread := TVDRX_WorkerThread.Create(@AcceptLoopPlain);
    FPlainThread.FreeOnTerminate := False;
    FPlainThread.Start;
  end;
  if FTLSPort <> 0 then
  begin
    FTLSContext := TVDRX_TLSContext.Create(FTLSCertFile, FTLSKeyFile);
    if not FTLSContext.OK then
    begin
      FTLSContext.Free;
      FTLSContext := nil;
    end
    else
    begin
      FTLSThread := TVDRX_WorkerThread.Create(@AcceptLoopTLS);
      FTLSThread.FreeOnTerminate := False;
      FTLSThread.Start;
    end;
  end;
end;

// FActiveConnections membership (kept in sync by Register/UnregisterConnection,
// both called from the connection thread itself) is used as the completion
// signal instead of AThread.Finished, and nothing here ever calls AThread.Free -
// see the Shutdown comment below.
function TVDRX_SocketListenerExecutive.WaitConnGone(AThread: TVDRX_ListenerConnThread; ATimeoutMs: Integer): Boolean;
var
  Waited: Integer;

  function StillActive: Boolean;
  begin
    FCriticalSection.Acquire;
    try
      Result := FActiveConnections.IndexOf(AThread) >= 0;
    finally
      FCriticalSection.Release;
    end;
  end;

begin
  Waited := 0;
  while StillActive and (Waited < ATimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  Result := not StillActive;
end;

procedure TVDRX_SocketListenerExecutive.Shutdown;
var
  I: Integer;
  ConnThread: TVDRX_ListenerConnThread;
  CopyList: TList;
begin
  FStopping := True;

  // 1. Unblock accept loops. Guard + zero each socket var so the accept
  // loop's own closing code (AcceptLoopPlain/AcceptLoopTLS) won't also try
  // to close it again once it wakes up from fpAccept - double-closing a fd
  // on POSIX is dangerous once the number has been recycled for another
  // thread's socket.
  if FPlainSocket <> 0 then
  begin
    CloseSocket(FPlainSocket);
    FPlainSocket := 0;
  end;
  if FTLSSocket <> 0 then
  begin
    CloseSocket(FTLSSocket);
    FTLSSocket := 0;
  end;

  // 2. Join accept threads (bounded - these should return almost immediately
  // once their listen socket is closed above).
  if Assigned(FPlainThread) then
  begin
    if WaitThreadOrTimeout(FPlainThread, FGracefulTimeoutMs) then
      FPlainThread.Free
    else
      Bus.Publish('log.warn', ID + ': plain accept thread did not exit in time - abandoning it', ID);
    FPlainThread := nil;
  end;
  if Assigned(FTLSThread) then
  begin
    if WaitThreadOrTimeout(FTLSThread, FGracefulTimeoutMs) then
      FTLSThread.Free
    else
      Bus.Publish('log.warn', ID + ': TLS accept thread did not exit in time - abandoning it', ID);
    FTLSThread := nil;
  end;

  // 3. Thread-safe snapshot of active connection threads to close
  FCriticalSection.Acquire;
  try
    CopyList := TList.Create;
    CopyList.Assign(FActiveConnections);
  finally
    FCriticalSection.Release;
  end;

  try
    for I := 0 to CopyList.Count - 1 do
    begin
      ConnThread := TVDRX_ListenerConnThread(CopyList[I]);
      // ConnThread.Execute sets FreeOnTerminate := True right before it
      // returns, so the RTL frees the TThread object itself, on the
      // connection's own thread, the moment Execute exits - possibly before
      // this loop even gets here. That means this code must never touch
      // ConnThread's own fields (.Finished, .Free) once it's had a chance to
      // exit, since the object may already be gone: doing so risks a
      // use-after-free, and calling ConnThread.Free here on top of that would
      // be a double free. WaitConnGone sidesteps this entirely by polling
      // FActiveConnections membership (a separate, still-live data
      // structure) instead of the thread object, and this code never calls
      // ConnThread.Free - FreeOnTerminate already owns that.
      //
      // First give it FGracefulTimeoutMs to notice FStopping/EOF and exit on
      // its own; if it doesn't, force its transport closed - that unblocks a
      // blocking Read/Write (a connection idling on a client that never
      // sends/disconnects, the classic hang case) and lets HandleConnection
      // return. Give it one more short window after that before giving up.
      if not WaitConnGone(ConnThread, FGracefulTimeoutMs) then
      begin
        Bus.Publish('log.warn', ID + ': connection thread did not exit in time - forcing its socket closed', ID);
        try ConnThread.Transport.Close; except end;
        if not WaitConnGone(ConnThread, FGracefulTimeoutMs) then
          // Genuinely stuck even after a forced close (shouldn't happen) -
          // abandon it; its transport is already closed so it should
          // unblock and self-free shortly via FreeOnTerminate regardless.
          Bus.Publish('log.warn', ID + ': connection thread still stuck after forcing its socket closed - abandoning it', ID);
      end;
    end;
  finally
    CopyList.Free;
  end;

  // 4. Safe to tear down shared resources like context now that all threads are dead
  FTLSContext.Free;
  FTLSContext := nil;
end;

constructor TVDRX_WebListenerExecutive.Create(ABus: TVDRX_MessageQueue; AWebSocket: TVDRX_WebSocketExecutive;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes);
begin
  inherited Create(ABus);
  FWebSocket := AWebSocket;
  FTemplates := ATemplates;
  FConfig := AConfig;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
  Port := 80;
end;

procedure TVDRX_WebListenerExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Buf: array[0..2047] of Byte;
  Received: Integer;
  Request, Response: string;
begin
  Received := ATransport.Read(Buf[0], SizeOf(Buf));
  if Received <= 0 then
  begin
    ATransport.Close;
    ATransport.Free;
    Exit;
  end;
  SetString(Request, PAnsiChar(@Buf[0]), Received);

  if TVDRX_WSConnection.IsUpgradeRequest(Request) then
    FWebSocket.AdoptConnection(ATransport, Request)
  else
  begin
    Response := TVDRX_HTTPExecutive.BuildResponse(Request, FTemplates, FConfig, FStaticDir, FProxyRoutes, FCLIRoutes, Bus, FWebSocket.Registry, ID);
    ATransport.Write(Response[1], Length(Response));
    ATransport.Close;
    ATransport.Free;
  end;
end;

procedure TVDRX_WebListenerExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // Request/response + hand-off only.
end;

constructor TCLIWatchdog.Create(AProc: TProcess; ATimeoutMs: Integer);
begin
  inherited Create;
  FProc := AProc;
  FTimeoutMs := ATimeoutMs;
end;

procedure TCLIWatchdog.Cancel;
begin
  FCancelled := True;
end;

procedure TCLIWatchdog.Run;
var
  Waited: Integer;
begin
  Waited := 0;
  while (not FCancelled) and (Waited < FTimeoutMs) do
  begin
    Sleep(50);
    Inc(Waited, 50);
  end;
  if (not FCancelled) and FProc.Running then
  begin
    FFired := True;
    ForceKillProcess(FProc);
  end;
end;

function PlainResponse(const AStatus, AContentType, ABody: string): string;
begin
  Result := 'HTTP/1.1 ' + AStatus + #13#10 +
            'Content-Type: ' + AContentType + #13#10 +
            'Content-Length: ' + IntToStr(Length(ABody)) + #13#10#13#10 + ABody;
end;

function StatusOf(const AResponse: string): string;
var
  LineEnd, SpacePos: Integer;
begin
  LineEnd := Pos(#13#10, AResponse);
  if LineEnd = 0 then LineEnd := Length(AResponse) + 1;
  SpacePos := Pos(' ', AResponse);
  if (SpacePos = 0) or (SpacePos >= LineEnd) then Exit('?');
  Result := Copy(AResponse, SpacePos + 1, LineEnd - SpacePos - 1);
end;

procedure ParseRequestLine(const ARequest: string; out AMethod, APath: string);
var
  LineEnd, Sp1, Sp2: Integer;
  Line: string;
begin
  AMethod := '';
  APath := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Pos(#10, ARequest);
  if LineEnd = 0 then Line := ARequest else Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  AMethod := Copy(Line, 1, Sp1 - 1);
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  APath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  Sp1 := Pos('?', APath);
  if Sp1 > 0 then APath := Copy(APath, 1, Sp1 - 1);
end;

function ExtractQueryString(const ARequest: string): string;
var
  LineEnd, Sp1, Sp2, QPos: Integer;
  Line, RawPath: string;
begin
  Result := '';
  LineEnd := Pos(#13#10, ARequest);
  if LineEnd = 0 then LineEnd := Length(ARequest) + 1;
  Line := Copy(ARequest, 1, LineEnd - 1);
  Sp1 := Pos(' ', Line);
  if Sp1 = 0 then Exit;
  Sp2 := PosEx(' ', Line, Sp1 + 1);
  if Sp2 = 0 then Sp2 := Length(Line) + 1;
  RawPath := Copy(Line, Sp1 + 1, Sp2 - Sp1 - 1);
  QPos := Pos('?', RawPath);
  if QPos > 0 then
    Result := Copy(RawPath, QPos + 1, MaxInt);
end;

function ExtractHeaderValue(const AHeaderBlock, AName: string): string;
var
  SL: TStringList;
  i, Colon: Integer;
begin
  Result := '';
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do // line 0 is the request line, not a header
    begin
      Colon := Pos(':', SL[i]);
      if (Colon > 0) and SameText(Trim(Copy(SL[i], 1, Colon - 1)), AName) then
        Exit(Trim(Copy(SL[i], Colon + 1, MaxInt)));
    end;
  finally
    SL.Free;
  end;
end;

// Reads a full request off the wire: headers (up to the blank line), then -
// if a Content-Length header is present - exactly that many more body bytes.
// Needed for the proxy path (a PHP app expects to see the whole POST body,
// not the first ~1KB a single Read happened to return) but applies to every
// request now, board/static included, since it's strictly more correct.
function ReadFullRequest(ATransport: TVDRX_Transport): string;
var
  Buf: array[0..4095] of Byte;
  Received, HeaderEnd, ContentLength, BodySoFar, ToRead, TotalLen: Integer;
  HeaderBlock, CLStr: string;
begin
  Result := '';
  HeaderEnd := 0;
  while (HeaderEnd = 0) and (Length(Result) < MAX_HEADER_SIZE) do
  begin
    Received := ATransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then Exit(Result); // closed before headers finished - hand back whatever we have
    SetLength(Result, Length(Result) + Received);
    Move(Buf[0], Result[Length(Result) - Received + 1], Received);
    HeaderEnd := Pos(#13#10#13#10, Result);
  end;
  if HeaderEnd = 0 then Exit; // headers too large or never terminated - drop rather than hang

  HeaderBlock := Copy(Result, 1, HeaderEnd - 1);
  CLStr := ExtractHeaderValue(HeaderBlock, 'Content-Length');
  ContentLength := 0;
  if CLStr <> '' then
    ContentLength := StrToIntDef(Trim(CLStr), 0);
  if ContentLength > MAX_BODY_SIZE then ContentLength := MAX_BODY_SIZE; // clamp rather than reject

  BodySoFar := Length(Result) - (HeaderEnd + 3);
  // Grow Result to its final known size in one shot up front, rather than
  // via SetLength(Result, Length(Result) + Received) on every 4KB chunk
  // below - each of those was a full realloc-and-copy of everything read so
  // far, so a multi-megabyte POST body (up to MAX_BODY_SIZE = 10MB) meant
  // thousands of reallocations copying an ever-growing buffer, quadratic in
  // the body size. Extending once here makes each chunk below a plain Move
  // into already-allocated space.
  if ContentLength > BodySoFar then
  begin
    TotalLen := Length(Result) + (ContentLength - BodySoFar);
    SetLength(Result, TotalLen);
  end;
  while BodySoFar < ContentLength do
  begin
    ToRead := ContentLength - BodySoFar;
    if ToRead > SizeOf(Buf) then ToRead := SizeOf(Buf);
    Received := ATransport.Read(Buf[0], ToRead);
    if Received <= 0 then
    begin
      // Client stopped sending early - forward whatever we actually got,
      // trimming off the space we pre-allocated for bytes that never
      // arrived (SetLength above assumed the client would send exactly
      // ContentLength bytes).
      SetLength(Result, HeaderEnd + 3 + BodySoFar);
      Break;
    end;
    Move(Buf[0], Result[HeaderEnd + 3 + BodySoFar + 1], Received);
    Inc(BodySoFar, Received);
  end;
end;

function IsValidBoardName(const AName: string): Boolean;
var
  i: Integer;
begin
  Result := (Length(AName) > 0) and (Length(AName) <= 64);
  if not Result then Exit;
  for i := 1 to Length(AName) do
    if not (AName[i] in ['a'..'z', 'A'..'Z', '0'..'9', '_', '-']) then
      Exit(False);
end;

function GuessContentType(const APath: string): string;
var
  Ext: string;
begin
  Ext := LowerCase(ExtractFileExt(APath));
  if Ext = '.js' then Result := 'application/javascript'
  else if Ext = '.css' then Result := 'text/css'
  else if Ext = '.html' then Result := 'text/html'
  else if Ext = '.json' then Result := 'application/json'
  else if Ext = '.svg' then Result := 'image/svg+xml'
  else Result := 'application/octet-stream';
end;

function ServeStaticFile(const APath, AStaticDir: string; ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  FilePath, Body: string;
  FS: TFileStream;
begin
  ABus.Publish('log.info', 'http: static path: "' + APath + '"', ASourceID);
  if (AStaticDir = '') or (Pos('..', APath) > 0) or (APath = '') or (APath[1] <> '/') then
  begin
    ABus.Publish('log.warn', 'http: rejected static path "' + APath + '"', ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;
  FilePath := IncludeTrailingPathDelimiter(AStaticDir) + Copy(APath, 2, MaxInt);
  if (not FileExists(FilePath)) or DirectoryExists(FilePath) then
  begin
    ABus.Publish('log.warn', 'http: static file not found: ' + FilePath, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;
  FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Body, FS.Size);
    if FS.Size > 0 then
      FS.ReadBuffer(Body[1], FS.Size);
  finally
    FS.Free;
  end;
  ABus.Publish('log.info', Format('http: served static %s (%d bytes)', [FilePath, Length(Body)]), ASourceID);
  Result := PlainResponse('200 OK', GuessContentType(APath), Body);
end;

function MatchProxyRoute(const APath: string; const ARoutes: TVDRX_ProxyRoutes; out AMatch: TVDRX_ProxyRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if (Copy(APath, 1, Length(ARoutes[i].Prefix)) = ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

// Strips any existing Connection header and forces 'Connection: close' -
// without this, a keep-alive-capable backend (php -S included) would hold
// the socket open waiting for a second request over the same connection,
// and the "read until the backend closes" loop in ProxyRequest below would
// then block forever on every single proxied request. Same shape of bug as
// the WebSocket self-join deadlock from earlier in this project: a blocking
// read with no other signal for "the response is actually done."
function ForceConnectionClose(const ARequest: string): string;
var
  HeaderEnd, i: Integer;
  OutLines: TStringList;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit(ARequest); // malformed - forward as-is rather than guess
  OutLines := TStringList.Create;
  try
    OutLines.Text := Copy(ARequest, 1, HeaderEnd - 1);
    for i := OutLines.Count - 1 downto 0 do
      if Pos('connection:', LowerCase(OutLines[i])) = 1 then
        OutLines.Delete(i);
    OutLines.Add('Connection: close');
    Result := OutLines.Text + #13#10 + Copy(ARequest, HeaderEnd + 4, MaxInt);
  finally
    OutLines.Free;
  end;
end;

function ProxyRequest(const ARequest: string; const ARoute: TVDRX_ProxyRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
const
  MAX_CONNECT_ATTEMPTS = 5;
  RETRY_DELAY_MS = 150;
var
  Transport: TVDRX_Transport;
  Buf: array[0..8191] of Byte;
  Received, Attempt: Integer;
  Outgoing: string;
begin
  Transport := nil;
  for Attempt := 1 to MAX_CONNECT_ATTEMPTS do
  begin
    Transport := ConnectTCP(ARoute.Host, ARoute.Port);
    if Assigned(Transport) then Break;
    // The backend can take a moment to finish starting and bind its port
    // after Bridge spawns it - a request landing in that window (most
    // likely right after the daemon itself just started, or right after
    // 'sys.restart') would otherwise get a spurious 502 on an
    // otherwise-healthy setup. A few short retries covers that startup
    // race without masking a genuinely-down backend for long.
    if Attempt < MAX_CONNECT_ATTEMPTS then
      Sleep(RETRY_DELAY_MS);
  end;
  if not Assigned(Transport) then
  begin
    ABus.Publish('log.error', Format('http proxy: could not connect to %s:%d after %d attempt(s) - is the bridge process up? (check its own log lines above, and "kill <bridge-id>" to bounce it if it looks wedged)', [ARoute.Host, ARoute.Port, MAX_CONNECT_ATTEMPTS]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Upstream unavailable'));
  end;

  try
    Outgoing := ForceConnectionClose(ARequest);
    Transport.Write(Outgoing[1], Length(Outgoing));
    Result := '';
    repeat
      Received := Transport.Read(Buf[0], SizeOf(Buf));
      if Received > 0 then
      begin
        SetLength(Result, Length(Result) + Received);
        Move(Buf[0], Result[Length(Result) - Received + 1], Received);
      end;
    until Received <= 0;
  finally
    Transport.Close;
    Transport.Free;
  end;

  if Result = '' then
  begin
    ABus.Publish('log.warn', Format('http proxy: empty response from %s:%d', [ARoute.Host, ARoute.Port]), ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from upstream'));
  end;
  ABus.Publish('log.info', Format('http proxy: %s:%d -> %d bytes', [ARoute.Host, ARoute.Port, Length(Result)]), ASourceID);
end;

function MatchCLIRoute(const APath: string; const ARoutes: TVDRX_CLIRoutes; out AMatch: TVDRX_CLIRoute): Boolean;
var
  i, bestLen: Integer;
begin
  Result := False;
  bestLen := -1;
  for i := 0 to High(ARoutes) do
    if (Copy(APath, 1, Length(ARoutes[i].Prefix)) = ARoutes[i].Prefix) and (Length(ARoutes[i].Prefix) > bestLen) then
    begin
      AMatch := ARoutes[i];
      bestLen := Length(ARoutes[i].Prefix);
      Result := True;
    end;
end;

// Same '..'-rejection posture as ServeStaticFile - a literal-substring check,
// not full canonicalization. Consistent risk level to what's already
// accepted for static files in this codebase; fine for the "not secure yet"
// bar everything else here is at.
function ResolveScriptPath(const APath, APrefix, AScriptDir: string; out AScriptPath: string): Boolean;
var
  Rel: string;
begin
  Result := False;
  Rel := Copy(APath, Length(APrefix) + 1, MaxInt);
  if (Rel = '') or (Pos('..', Rel) > 0) then Exit;
  AScriptPath := IncludeTrailingPathDelimiter(AScriptDir) + Rel;
  Result := FileExists(AScriptPath);
end;

// Spawns ARoute.Command ScriptPath fresh, feeds it a handful of CGI-ish env
// vars (works whether ARoute.Command is plain 'php' - readable via
// getenv()/$_SERVER - or 'php-cgi', which auto-populates $_GET/$_POST from
// them like a real CGI SAPI would), and returns its stdout verbatim as the
// response body. The read loop and TCLIWatchdog run CONCURRENTLY - see the
// type's comment above for why draining stdout can't wait until after the
// process exits.
function RunCLIScript(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ABus: TVDRX_MessageQueue; const ASourceID: string): string;
var
  Method, Path, ScriptPath, QueryString, HeaderBlock: string;
  Proc: TProcess;
  Watchdog: TCLIWatchdog;
  WatchdogThread: TThread;
  Buf: array[0..4095] of Byte;
  Received, HdrEnd: Integer;
  Output: string;
begin
  ParseRequestLine(ARequest, Method, Path);
  if not ResolveScriptPath(Path, ARoute.Prefix, ARoute.ScriptDir, ScriptPath) then
  begin
    ABus.Publish('log.warn', 'http cli: no script found for "' + Path + '" under ' + ARoute.ScriptDir, ASourceID);
    Exit(PlainResponse('404 Not Found', 'text/plain', 'Not found'));
  end;

  QueryString := ExtractQueryString(ARequest);
  HdrEnd := Pos(#13#10#13#10, ARequest);
  if HdrEnd > 0 then HeaderBlock := Copy(ARequest, 1, HdrEnd - 1) else HeaderBlock := ARequest;

  Proc := TProcess.Create(nil);
  try
    if FileExists(ARoute.Command) then
      Proc.Executable := ARoute.Command
    else
      Proc.Executable := ProcessFindInPath(ARoute.Command);
    Proc.Parameters.Add(ScriptPath);
    Proc.Environment.Add('REQUEST_METHOD=' + Method);
    Proc.Environment.Add('QUERY_STRING=' + QueryString);
    Proc.Environment.Add('REQUEST_URI=' + Path + IfThen(QueryString <> '', '?' + QueryString, ''));
    Proc.Environment.Add('CONTENT_TYPE=' + ExtractHeaderValue(HeaderBlock, 'Content-Type'));
    Proc.Environment.Add('CONTENT_LENGTH=' + ExtractHeaderValue(HeaderBlock, 'Content-Length'));
    // poSearchPath: without it, ARoute.Command only works as an absolute
    // path ("/usr/bin/php") - a bare command name like "php" from
    // vdrx.conf would fail to launch on any system where it's only
    // resolvable via the shell's PATH.
    //Proc.Options := [poUsePipes, poStderrToOutPut, poSearchPath]; // poSearchPath not in process.TProcessOptions
    Proc.Options := [poUsePipes, poStderrToOutPut];

    // NOT Proc.CurrentDirectory := ARoute.ScriptDir here - ScriptPath (the
    // Parameters.Add above) was already built by ResolveScriptPath as
    // ARoute.ScriptDir + Rel, i.e. relative to the DAEMON's own working
    // directory. Setting CurrentDirectory to ScriptDir as well doubled that
    // prefix - the child ended up looking for ScriptDir/ScriptPath (e.g.
    // "phpcli/phpcli/index.php") from inside ScriptDir, which never
    // resolved once ScriptDir was a relative path (an absolute ScriptDir
    // masked this, since PHP would just fail to find ITS half and the
    // symptom looked identical). Leaving CurrentDirectory unset lets the
    // child inherit the daemon's own CWD, which is exactly the base
    // ScriptPath was already computed against.
    Proc.Execute;

    Watchdog := TCLIWatchdog.Create(Proc, ARoute.TimeoutMs);
    WatchdogThread := TVDRX_WorkerThread.Create(@Watchdog.Run);
    WatchdogThread.FreeOnTerminate := False;
    WatchdogThread.Start;
    try
      Output := '';
      repeat
        Received := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if Received > 0 then
        begin
          SetLength(Output, Length(Output) + Received);
          Move(Buf[0], Output[Length(Output) - Received + 1], Received);
        end;
      until Received <= 0;

      Watchdog.Cancel;
      WaitThreadOrTimeout(WatchdogThread, 500); // polls every 50ms internally - should return almost immediately

      if Watchdog.Fired then
      begin
        ABus.Publish('log.error', Format('http cli: %s exceeded %dms, killed it', [ScriptPath, ARoute.TimeoutMs]), ASourceID);
        Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'Script timed out'));
      end;
    finally
      WatchdogThread.Free;
      Watchdog.Free;
    end;
  finally
    Proc.Free;
  end;

  ABus.Publish('log.info', Format('http cli: %s -> %d bytes', [ScriptPath, Length(Output)]), ASourceID);
  Result := PlainResponse('200 OK', ARoute.ContentType, Output);
end;

// Common status-code -> reason-phrase text for the handful of codes a bus
// CLI script is realistically going to return. Falls back to a generic
// phrase for anything else - the phrase is cosmetic (RFC 7230 says clients
// MUST ignore it), so an approximate one for an unlisted code is harmless.
function HTTPStatusText(ACode: Integer): string;
begin
  case ACode of
    200: Result := 'OK';
    201: Result := 'Created';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    307: Result := 'Temporary Redirect';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    500: Result := 'Internal Server Error';
    502: Result := 'Bad Gateway';
    504: Result := 'Gateway Timeout';
  else
    if (ACode >= 200) and (ACode < 300) then Result := 'OK'
    else if (ACode >= 400) and (ACode < 500) then Result := 'Error'
    else if ACode >= 500 then Result := 'Server Error'
    else Result := 'Unknown';
  end;
end;

// Everything after the blank line that ends the headers - '' if the request
// never got that far (see ReadFullRequest, which is what actually put the
// body there in the first place; this just re-locates it from the combined
// string rather than threading a separate parameter through every caller).
function ExtractBody(const ARequest: string): string;
var
  HeaderEnd: Integer;
begin
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd = 0 then Exit('');
  Result := Copy(ARequest, HeaderEnd + 4, MaxInt);
end;

// Every "Name: Value" header line (skipping the request line itself) as one
// flat JSON object. A repeated header name overwrites rather than
// accumulating into an array - a simplification consistent with
// ExtractHeaderValue's existing "first/only match wins" contract elsewhere
// in this unit, fine for the common single-value headers a bus CLI script
// actually cares about (Host, Content-Type, Cookie, ...).
function HeadersToJSON(const AHeaderBlock: string): TJSONObject;
var
  SL: TStringList;
  i, Colon: Integer;
  Name, Value: string;
begin
  Result := TJSONObject.Create;
  SL := TStringList.Create;
  try
    SL.Text := AHeaderBlock;
    for i := 1 to SL.Count - 1 do // line 0 is the request line, not a header
    begin
      Colon := Pos(':', SL[i]);
      if Colon > 0 then
      begin
        Name := Trim(Copy(SL[i], 1, Colon - 1));
        Value := Trim(Copy(SL[i], Colon + 1, MaxInt));
        if Name <> '' then
          Result.Strings[Name] := Value;
      end;
    end;
  finally
    SL.Free;
  end;
end;

// Find-with-type-check helper - TJSONObject.Find can return a member of any
// JSON type (or nil), and a plain "as TJSONObject" cast on a non-nil but
// wrong-typed result raises EInvalidCast rather than failing gracefully.
// A bus CLI script sending malformed shapes (e.g. "params": "oops", a
// string instead of an object) should degrade to "field absent", not crash
// the HTTP executive's connection thread.
function FindJSONObject(AObj: TJSONObject; const AName: string): TJSONObject;
var
  D: TJSONData;
begin
  D := AObj.Find(AName);
  if Assigned(D) and (D is TJSONObject) then
    Result := TJSONObject(D)
  else
    Result := nil;
end;

// Converts a bus CLI reply's optional "rows" object - {"loopName": [{...
// row fields ...}, ...], ...} - into the TVDRX_TemplateNamedRows shape
// TVDRX_TemplateStore.Fill expects for ##loop:loopName##...##endloop##
// blocks. Only scalar fields within each row object are kept (same
// restriction GetObjectArray already applies to config rows in
// vdrx_config.pas - a template row is a flat Name=Value record, same as
// there). Non-array values under a loop name, or non-object entries within
// one, are silently skipped rather than raising - a malformed "rows" value
// from a buggy script should render that loop as empty, not 500 the whole
// response. Caller owns and frees the result (it owns its TVDRX_TemplateRows
// values too, via doOwnsValues).
{ TVDRX_OneShotWaiter }

constructor TVDRX_OneShotWaiter.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FEvent := TEvent.Create(nil, True, False, '');
  FGotReply := False;
end;

destructor TVDRX_OneShotWaiter.Destroy;
begin
  FEvent.Free;
  inherited;
end;

procedure TVDRX_OneShotWaiter.HandlePacket(const AMsg: TVDRX_Message);
begin
  // Only ever expecting exactly one message (this waiter's reply topic is
  // unique per request - see NextReplyTopic) - a second one showing up
  // before teardown would just overwrite FReplyPayload harmlessly, since
  // WaitForReply's caller stops waiting after the first SetEvent anyway.
  FReplyPayload := AMsg.Payload;
  FGotReply := True;
  FEvent.SetEvent;
end;

function TVDRX_OneShotWaiter.WaitForReply(ATimeoutMs: Integer; out APayload: string): Boolean;
begin
  Result := (FEvent.WaitFor(ATimeoutMs) = wrSignaled) and FGotReply;
  if Result then APayload := FReplyPayload else APayload := '';
end;

var
  GReplyTopicCounter: Integer = 0;
  GReplyTopicLock: TCriticalSection;

// Mints a reply topic unique for the lifetime of this daemon process -
// "<prefix>.N", N from a lock-protected counter (not InterlockedIncrement:
// this only runs once per request/render-call, nowhere near hot enough for
// a lock-free path to matter, and a plain critical section is one less
// platform-specific primitive to get subtly wrong). Same naming shape as
// TVDRX_WebSocketExecutive.NextConnID's "ws.conn.N" - deliberately, so a
// glance at vdrx_daemon.log's topic names tells you what KIND of thing
// minted a given identifier.
function NextReplyTopic(const APrefix: string): string;
begin
  GReplyTopicLock.Enter;
  try
    Inc(GReplyTopicCounter);
    Result := APrefix + '.' + IntToStr(GReplyTopicCounter);
  finally
    GReplyTopicLock.Leave;
  end;
end;

// The shared "publish a request, block for a correlated reply" primitive
// behind both RunBusDaemonRoute (§3 of the readme) and BuildBusCLIResponse's
// "template_topic" routing (§2). AEnvelope is the full JSON payload to
// publish to AInTopic - this function only adds and manages "reply_to"
// itself (via NextReplyTopic(AReplyPrefix)) so every caller doesn't have to
// duplicate the mint/register/publish/wait/unregister sequence, or risk
// forgetting the Unregister on a timeout path.
function PublishAndWait(ARegistry: TVDRX_Registry; ABus: TVDRX_MessageQueue;
  const AInTopic, AReplyPrefix: string; AEnvelope: TJSONObject;
  ATimeoutMs: Integer; const ASourceID: string; out AReply: string): Boolean;
var
  ReplyTopic: string;
  Waiter: TVDRX_OneShotWaiter;
begin
  ReplyTopic := NextReplyTopic(AReplyPrefix);
  AEnvelope.Add('reply_to', ReplyTopic);

  Waiter := TVDRX_OneShotWaiter.Create(ABus);
  ARegistry.Register(Waiter, ReplyTopic, ReplyTopic); // ID = filter = the reply topic itself - nothing else needs to address this waiter by name

  ABus.Publish(AInTopic, AEnvelope.AsJSON, ASourceID);
  Result := Waiter.WaitForReply(ATimeoutMs, AReply);

  ARegistry.Unregister(ReplyTopic); // external teardown (this call runs on the HTTP connection thread, not the waiter's own - it has none) - see TVDRX_OneShotWaiter's comment and vdrx_core.pas's Unregister-vs-UnregisterSelf distinction
  if not Result then
    ABus.Publish('log.warn', Format('bus wait: no reply on "%s" (published to "%s") within %dms', [ReplyTopic, AInTopic, ATimeoutMs]), ASourceID);
end;

// Turns a bus CLI script's one-line JSON reply into an actual HTTP response.
// Two response shapes, chosen by which fields are present:
//   {"status":200,"content_type":"...","headers":{...},"body":"..."}
//     - body is used verbatim.
//   {"status":200,"template":"name","params":{...},"rows":{...}}
//     - rendered server-side. Two ways this can resolve, chosen by whether
//       "template_topic" is also present:
//         - absent (the original, still-supported shape): ATemplates.Fill
//           runs in-process against whichever HTTP site's own template
//           store answered THIS connection - simple, zero bus round trip,
//           but implicit: which store answers depends on which site's port
//           the request happened to arrive on, which is surprising the
//           moment more than one site could plausibly serve the same
//           route (see the readme's §4b note on this).
//         - present, e.g. {"template_topic":"template.vdrx_admin.render",
//           "template":"greeting",...} - the render request is instead
//           PUBLISHED to that explicit topic via PublishAndWait, and
//           whichever TVDRX_TemplateExecutive is subscribed there (see
//           vdrx_templates.pas and the "templates" config section)
//           answers it, regardless of which HTTP site's connection this
//           is. This is the fix for that ambiguity: the script says
//           exactly which template store it means, instead of VDRX
//           guessing from connection topology.
// "status"/"content_type" fall back to 200/ADefaultContentType if omitted;
// extra "headers" entries are appended as-is (last-write-wins with the
// Content-Type/Content-Length lines this function always sets itself).
function BuildBusCLIResponse(const AReplyLine, ADefaultContentType: string;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  J: TJSONData;
  Obj, ParamsObj, RowsObj, HeadersObj, RenderEnvelope, ReplyObj: TJSONObject;
  ReplyJSON: TJSONData;
  Status, ContentType, Body, TemplateName, TemplateTopic, ReplyRaw: string;
  StatusCode, i: Integer;
  Params: TStringList;
  NamedRows: TVDRX_TemplateNamedRows;
begin
  if Trim(AReplyLine) = '' then
  begin
    ABus.Publish('log.warn', 'http bus cli: empty reply from script (nothing written to stdout before exit)', ASourceID);
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Empty response from script'));
  end;

  J := nil;
  try
    J := GetJSON(AReplyLine);
  except
    J := nil; // same "nil result AND exception both mean unparseable" handling as EnsureJSONPayload in vdrx_bridge.pas
  end;
  if not Assigned(J) or not (J is TJSONObject) then
  begin
    ABus.Publish('log.warn', 'http bus cli: reply was not a JSON object: ' + AReplyLine, ASourceID);
    if Assigned(J) then J.Free;
    Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Malformed response from script'));
  end;

  Obj := TJSONObject(J);
  try
    StatusCode := Obj.Get('status', 200);
    Status := IntToStr(StatusCode) + ' ' + HTTPStatusText(StatusCode);
    ContentType := Obj.Get('content_type', ADefaultContentType);
    TemplateName := Obj.Get('template', '');
    TemplateTopic := Obj.Get('template_topic', '');

    if (TemplateName <> '') and (TemplateTopic <> '') then
    begin
      // Explicit routing - see this function's header comment. Forward
      // exactly the fields a render request needs (template/params/rows)
      // as their own envelope; PublishAndWait adds "reply_to" itself.
      RenderEnvelope := TJSONObject.Create;
      try
        RenderEnvelope.Add('template', TemplateName);
        if Assigned(FindJSONObject(Obj, 'params')) then RenderEnvelope.Add('params', FindJSONObject(Obj, 'params').Clone);
        if Assigned(FindJSONObject(Obj, 'rows')) then RenderEnvelope.Add('rows', FindJSONObject(Obj, 'rows').Clone);

        if not PublishAndWait(ARegistry, ABus, TemplateTopic, 'template.reply', RenderEnvelope, 5000, ASourceID, ReplyRaw) then
        begin
          ABus.Publish('log.warn', Format('http bus cli: no template executive answered "%s" for template "%s"', [TemplateTopic, TemplateName]), ASourceID);
          Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Template executive did not respond'));
        end;
      finally
        RenderEnvelope.Free;
      end;

      Body := '';
      ReplyJSON := nil;
      try
        try ReplyJSON := GetJSON(ReplyRaw); except ReplyJSON := nil; end;
        if Assigned(ReplyJSON) and (ReplyJSON is TJSONObject) then
        begin
          ReplyObj := TJSONObject(ReplyJSON);
          Body := ReplyObj.Get('body', '');
        end;
      finally
        if Assigned(ReplyJSON) then ReplyJSON.Free;
      end;
      if Body = '' then
        ABus.Publish('log.warn', Format('http bus cli: template executive "%s" returned no body for template "%s"', [TemplateTopic, TemplateName]), ASourceID);
    end
    else if TemplateName <> '' then
    begin
      // Original, still-supported shape - render in-process against
      // whichever site's own TVDRX_TemplateStore answered this connection.
      // See this function's header comment for the trade-off vs. above.
      ParamsObj := FindJSONObject(Obj, 'params');
      Params := JSONParamsToStringList(ParamsObj);
      try
        RowsObj := FindJSONObject(Obj, 'rows');
        NamedRows := JSONRowsToTemplateRows(RowsObj);
        try
          Body := ATemplates.Fill(TemplateName, Params, NamedRows);
        finally
          NamedRows.Free;
        end;
      finally
        Params.Free;
      end;
      if Body = '' then
        ABus.Publish('log.warn', Format('http bus cli: template "%s" not found or rendered empty - looked for %s', [TemplateName, IncludeTrailingPathDelimiter(ATemplates.Dir) + TemplateName + '.tpl']), ASourceID);
    end
    else
      Body := Obj.Get('body', '');

    Result := 'HTTP/1.1 ' + Status + #13#10 + 'Content-Type: ' + ContentType + #13#10;

    HeadersObj := FindJSONObject(Obj, 'headers');
    if Assigned(HeadersObj) then
      for i := 0 to HeadersObj.Count - 1 do
        if HeadersObj.Items[i].JSONType in [jtString, jtNumber, jtBoolean] then
          Result := Result + HeadersObj.Names[i] + ': ' + HeadersObj.Items[i].AsString + #13#10;

    Result := Result + 'Content-Length: ' + IntToStr(Length(Body)) + #13#10#13#10 + Body;
  finally
    Obj.Free;
  end;
end;

// The 'bus' counterpart to RunCLIScript above - spawns ARoute.Command fresh
// per request (same TCLIWatchdog-bounded lifetime), but talks the bus's own
// JSON-envelope shape instead of CGI env vars + raw body passthrough. Prefix
// behaves as a URL-rewrite base rather than a filesystem lookup root: the
// path beyond it (SubPath) and the raw query string are handed to the
// script as data in the request envelope, exactly like the original design
// discussion's "base_uri" idea - the script decides what a request for
// "/irc/channel/%23blah" or "/irc?channel=%23blah" under a "/irc" route
// means, VDRX doesn't parse it for them.
//
// Only the FIRST non-empty line the script writes to stdout is treated as
// its reply - same "one structured line, nothing else, ever" discipline
// scripts/irc_soylent.php already documents for vdrx_bridge.pas's
// persistent-process protocol (see that script's header comment). A script
// that wants to log its own activity should write to a local file, not
// stdout/stderr - poStderrToOutPut merges both into the same stream read
// here, so anything printed before the JSON reply line would otherwise
// corrupt it.
function RunBusCLIScript(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  Method, Path, SubPath, QueryString, HeaderBlock, Body, ReqLine, Output, FirstLine: string;
  HeaderEnd: Integer;
  ReqObj: TJSONObject;
  Proc: TProcess;
  Watchdog: TCLIWatchdog;
  WatchdogThread: TThread;
  Buf: array[0..4095] of Byte;
  Received, i: Integer;
  Cwd: string;
begin
  ParseRequestLine(ARequest, Method, Path);
  QueryString := ExtractQueryString(ARequest);
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd > 0 then HeaderBlock := Copy(ARequest, 1, HeaderEnd - 1) else HeaderBlock := ARequest;
  Body := ExtractBody(ARequest);

  if Length(Path) >= Length(ARoute.Prefix) then
    SubPath := Copy(Path, Length(ARoute.Prefix) + 1, MaxInt)
  else
    SubPath := '';

  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('method', Method);
    ReqObj.Add('path', Path);
    ReqObj.Add('prefix', ARoute.Prefix);
    ReqObj.Add('sub_path', SubPath);
    ReqObj.Add('query', QueryString);
    ReqObj.Add('headers', HeadersToJSON(HeaderBlock));
    ReqObj.Add('body', Body);
    ReqLine := ReqObj.AsJSON + LineEnding;
  finally
    ReqObj.Free;
  end;

  Proc := TProcess.Create(nil);
  try
    {$WARN SYMBOL_DEPRECATED OFF} // CommandLine: same free-form "let TProcess parse the quoting" style as vdrx_bridge.pas's FCommand
    Proc.CommandLine := ARoute.Command;
    {$WARN SYMBOL_DEPRECATED ON}
    // Resolved to absolute up front (ExpandFileName is a no-op on an
    // already-absolute path) so every log line below - and, more
    // importantly, whatever error a language-specific interpreter prints
    // when it can't find its own script - names an unambiguous location
    // rather than a path that's only meaningful relative to wherever the
    // daemon happened to be launched from. Worth having explicitly in mind
    // once several cli_bridges entries (in different languages, possibly
    // with different script_dir values) are all resolving relative paths
    // against the same shared daemon CWD - see the readme's §4b gotcha.
    Cwd := ExpandFileName(IfThen(ARoute.ScriptDir <> '', ARoute.ScriptDir, GetCurrentDir));
    Proc.CurrentDirectory := Cwd;
    Proc.Options := [poUsePipes, poStderrToOutPut];
    try
      Proc.Execute;
    except
      on E: Exception do
      begin
        ABus.Publish('log.error', Format('http bus cli: failed to start "%s" (cwd=%s) - %s', [ARoute.Command, Cwd, E.Message]), ASourceID);
        Exit(PlainResponse('502 Bad Gateway', 'text/plain', 'Could not start script'));
      end;
    end;

    Proc.Input.Write(ReqLine[1], Length(ReqLine));
    try Proc.CloseInput; except end; // EOF hint - same as vdrx_bridge.pas's StopProcess

    Watchdog := TCLIWatchdog.Create(Proc, ARoute.TimeoutMs);
    WatchdogThread := TVDRX_WorkerThread.Create(@Watchdog.Run);
    WatchdogThread.FreeOnTerminate := False;
    WatchdogThread.Start;
    try
      Output := '';
      repeat
        Received := Proc.Output.Read(Buf[0], SizeOf(Buf));
        if Received > 0 then
        begin
          SetLength(Output, Length(Output) + Received);
          Move(Buf[0], Output[Length(Output) - Received + 1], Received);
        end;
      until Received <= 0;

      Watchdog.Cancel;
      WaitThreadOrTimeout(WatchdogThread, 500);

      if Watchdog.Fired then
      begin
        ABus.Publish('log.error', Format('http bus cli: %s (cwd=%s) exceeded %dms, killed it', [ARoute.Command, Cwd, ARoute.TimeoutMs]), ASourceID);
        Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'Script timed out'));
      end;
    finally
      WatchdogThread.Free;
      Watchdog.Free;
    end;
  finally
    Proc.Free;
  end;

  // Take the first line that actually LOOKS like our JSON envelope, not
  // blindly Strings[0] - two things commonly land ahead of it in practice
  // and shouldn't sink the whole response:
  //   1. A UTF-8 BOM (EF BB BF) at the very start of Output if the script
  //      file itself was saved with one (common on Windows editors) - PHP
  //      happily echoes those 3 bytes before anything else, so line 0
  //      would start with garbage instead of '{'.
  //   2. A PHP notice/warning/deprecation line - poStderrToOutPut merges
  //      stderr into this same stream, and PHP's CLI SAPI writes those
  //      immediately when triggered, i.e. potentially before the script's
  //      final fwrite(STDOUT, ...) line even if that write comes later in
  //      the source.
  // So: strip a leading BOM if present, then scan lines for the first one
  // that, trimmed, actually starts with '{' - that's the reply; anything
  // before it is noise the script printed (or an accidental warning) and
  // is logged in full below (at WARN, since silently discarding it would
  // hide the real cause of a "malformed response") rather than treated as
  // fatal on its own.
  if (Length(Output) >= 3) and (Output[1] = #$EF) and (Output[2] = #$BB) and (Output[3] = #$BF) then
    Delete(Output, 1, 3);

  FirstLine := '';
  with TStringList.Create do
  try
    Text := Output;
    for i := 0 to Count - 1 do
    begin
      if Copy(TrimLeft(Strings[i]), 1, 1) = '{' then
      begin
        FirstLine := Trim(Strings[i]);
        Break;
      end;
    end;
    if (FirstLine = '') and (Count > 0) then
      ABus.Publish('log.warn', Format('http bus cli: %s (cwd=%s) produced no line starting with "{" - raw output: %s', [ARoute.Command, Cwd, Output]), ASourceID);
  finally
    Free;
  end;

  ABus.Publish('log.info', Format('http bus cli: %s %s (sub_path="%s", cwd=%s) -> %d bytes', [ARoute.Command, Path, SubPath, Cwd, Length(Output)]), ASourceID);
  Result := BuildBusCLIResponse(FirstLine, ARoute.ContentType, ATemplates, ABus, ARegistry, ASourceID);
end;

// The 'bus-daemon' counterpart to RunBusCLIScript above - same request
// envelope shape (method/path/prefix/sub_path/query/headers/body), same
// reply shape (BuildBusCLIResponse handles both identically - a persistent
// subscriber and a spawned script answer in exactly the same JSON), but no
// process is spawned here at all: the request is published to ARoute.InTopic
// and this just waits for a reply, via the same PublishAndWait primitive a
// template_topic lookup uses. Whatever answers InTopic - typically a
// persistent `processes` entry already subscribed to it, the same kind of
// thing already running irc_bot - handles as many concurrent requests as
// arrive, each getting its own uniquely-minted reply topic, without paying
// spawn cost per request.
function RunBusDaemonRoute(const ARequest: string; const ARoute: TVDRX_CLIRoute;
  ATemplates: TVDRX_TemplateStore; ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  Method, Path, SubPath, QueryString, HeaderBlock, Body, ReplyRaw: string;
  HeaderEnd: Integer;
  ReqObj: TJSONObject;
begin
  ParseRequestLine(ARequest, Method, Path);
  QueryString := ExtractQueryString(ARequest);
  HeaderEnd := Pos(#13#10#13#10, ARequest);
  if HeaderEnd > 0 then HeaderBlock := Copy(ARequest, 1, HeaderEnd - 1) else HeaderBlock := ARequest;
  Body := ExtractBody(ARequest);

  if Length(Path) >= Length(ARoute.Prefix) then
    SubPath := Copy(Path, Length(ARoute.Prefix) + 1, MaxInt)
  else
    SubPath := '';

  ReqObj := TJSONObject.Create;
  try
    ReqObj.Add('method', Method);
    ReqObj.Add('path', Path);
    ReqObj.Add('prefix', ARoute.Prefix);
    ReqObj.Add('sub_path', SubPath);
    ReqObj.Add('query', QueryString);
    ReqObj.Add('headers', HeadersToJSON(HeaderBlock));
    ReqObj.Add('body', Body);

    if not PublishAndWait(ARegistry, ABus, ARoute.InTopic, 'http.reply', ReqObj, ARoute.TimeoutMs, ASourceID, ReplyRaw) then
    begin
      ABus.Publish('log.error', Format('http bus-daemon: no subscriber on "%s" answered %s within %dms', [ARoute.InTopic, Path, ARoute.TimeoutMs]), ASourceID);
      Exit(PlainResponse('504 Gateway Timeout', 'text/plain', 'No daemon answered in time'));
    end;
  finally
    ReqObj.Free;
  end;

  ABus.Publish('log.info', Format('http bus-daemon: %s %s (in_topic=%s) -> %d bytes', [Method, Path, ARoute.InTopic, Length(ReplyRaw)]), ASourceID);
  Result := BuildBusCLIResponse(ReplyRaw, ARoute.ContentType, ATemplates, ABus, ARegistry, ASourceID);
end;

constructor TVDRX_HTTPExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ATemplates: TVDRX_TemplateStore;
  const AStaticDir: string; const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FTemplates := ATemplates;
  FStaticDir := AStaticDir;
  FProxyRoutes := AProxyRoutes;
  FCLIRoutes := ACLIRoutes;
  FRegistry := ARegistry;
  Port := 8081;
end;

class function TVDRX_HTTPExecutive.BuildResponse(const ARequest: string;
  ATemplates: TVDRX_TemplateStore; AConfig: TVDRX_Config; const AStaticDir: string;
  const AProxyRoutes: TVDRX_ProxyRoutes; const ACLIRoutes: TVDRX_CLIRoutes;
  ABus: TVDRX_MessageQueue; ARegistry: TVDRX_Registry; const ASourceID: string): string;
var
  Method, Path, BoardName: string;
  Route: TVDRX_ProxyRoute;
  CLIRoute: TVDRX_CLIRoute;
begin
  ParseRequestLine(ARequest, Method, Path);

  if MatchProxyRoute(Path, AProxyRoutes, Route) then
  begin
    ABus.Publish('log.info', Format('http: %s %s -> proxy %s:%d', [Method, Path, Route.Host, Route.Port]), ASourceID);
    Exit(ProxyRequest(ARequest, Route, ABus, ASourceID));
  end;

  if MatchCLIRoute(Path, ACLIRoutes, CLIRoute) then
  begin
    if SameText(CLIRoute.Protocol, 'bus-daemon') then
    begin
      ABus.Publish('log.info', Format('http: %s %s -> bus-daemon %s', [Method, Path, CLIRoute.InTopic]), ASourceID);
      Exit(RunBusDaemonRoute(ARequest, CLIRoute, ATemplates, ABus, ARegistry, ASourceID));
    end
    else if SameText(CLIRoute.Protocol, 'bus') then
    begin
      ABus.Publish('log.info', Format('http: %s %s -> bus cli %s', [Method, Path, CLIRoute.Command]), ASourceID);
      Exit(RunBusCLIScript(ARequest, CLIRoute, ATemplates, ABus, ARegistry, ASourceID));
    end
    else
    begin
      ABus.Publish('log.info', Format('http: %s %s -> cli %s', [Method, Path, CLIRoute.Command]), ASourceID);
      Exit(RunCLIScript(ARequest, CLIRoute, ABus, ASourceID));
    end;
  end;

  if Method = 'GET' then
    Result := ServeStaticFile(Path, AStaticDir, ABus, ASourceID)
  else
  begin
    ABus.Publish('log.warn', 'http: unhandled method "' + Method + '" for ' + Path, ASourceID);
    Result := PlainResponse('404 Not Found', 'text/plain', 'Not found');
  end;
end;

procedure TVDRX_HTTPExecutive.HandleConnection(ATransport: TVDRX_Transport);
var
  Request, Response, Method, Path: string;
begin
  Request := ReadFullRequest(ATransport);
  if Request <> '' then
  begin
    ParseRequestLine(Request, Method, Path);
    Response := BuildResponse(Request, FTemplates, FConfig, FStaticDir, FProxyRoutes, FCLIRoutes, Bus, FRegistry, ID);
    Bus.Publish('log.info', Format('http: %s %s -> %s', [Method, Path, StatusOf(Response)]), ID);
    ATransport.Write(Response[1], Length(Response));
  end
  else
    Bus.Publish('log.warn', 'http: connection closed before a request arrived', ID);
  ATransport.Close;
  ATransport.Free;
end;

procedure TVDRX_HTTPExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // HTTP is request/response, not bus-driven - nothing to do here.
end;

procedure TVDRX_HTTPExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  FStaticDir := FConfig.GetString('static_dir', FStaticDir);
  NewPort := FConfig.GetInteger('executives.http.port', 8081);
  NewTLSPort := FConfig.GetInteger('executives.http.tls_port', 0);
  CertFile := FConfig.GetString('executives.http.tls_cert', '');
  KeyFile := FConfig.GetString('executives.http.tls_key', '');
  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
  // NB: FProxyRoutes is NOT rebuilt here yet - proxy_bridges is only read at
  // startup (see vdrx_daemon.lpr's SetupProxyBridges). A 'sys.reload' picks
  // up template/board-nav/port changes live but not new/changed proxy
  // routes - restart the daemon (or 'sys.restart') for those.
end;

function ComputeAcceptKey(const AClientKey: string): string;
var
  Digest: TSHA1Digest;
  RawStr: string;
begin
  Digest := SHA1String(AClientKey + WS_GUID);
  SetString(RawStr, PAnsiChar(@Digest[0]), SizeOf(Digest));
  Result := EncodeStringBase64(RawStr);
end;

type
  TWSConnThread = class(TThread)
  private
    FConn: TVDRX_WSConnection;
  protected
    procedure Execute; override;
  public
    constructor Create(AConn: TVDRX_WSConnection);
  end;

constructor TWSConnThread.Create(AConn: TVDRX_WSConnection);
begin
  inherited Create(True);
  FConn := AConn;
  // Natural (client-initiated) disconnects finish inside RunLoop by calling
  // UnregisterSelf, which frees the owning TVDRX_WSConnection (and this
  // thread's FConn along with it) while still running on this very thread.
  // Nothing outside ever holds a reference to FThread to Free it in that
  // path (see RunLoop), so this thread must clean up its own TThread object
  // when it terminates or it leaks. Shutdown's forced-close path still works
  // fine with this set True: it just stops calling FThread.Free itself
  // (see TVDRX_WSConnection.Shutdown).
  FreeOnTerminate := True;
end;

procedure TWSConnThread.Execute;
begin
  FConn.RunLoop;
end;

{ TVDRX_WSConnection }

constructor TVDRX_WSConnection.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; ATransport: TVDRX_Transport);
begin
  inherited Create(ABus);
  FListener := AListener;
  FTransport := ATransport;
  FSendLock := TCriticalSection.Create;
end;

destructor TVDRX_WSConnection.Destroy;
begin
  FStopping := True;
  // Fallback cleanup: normally RunLoop already stops and frees FPingThread
  // itself before calling UnregisterSelf (which is what drives us here), so
  // this is a no-op on that path. But Destroy can also be reached via
  // Shutdown's FMasterMap.Remove, so guard here too - freeing FTransport/
  // FSendLock below while FPingThread's PingLoop might still be mid-SendFrame
  // on another thread is the exact use-after-free this used to hit.
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 500);
    FreeAndNil(FPingThread);
  end;
  FTransport.Free;
  FSendLock.Free;
  inherited Destroy;
end;

class function TVDRX_WSConnection.IsUpgradeRequest(const ARequest: string): Boolean;
begin
  Result := (Pos('Upgrade:', ARequest) > 0) and (Pos('websocket', LowerCase(ARequest)) > 0);
end;

function TVDRX_WSConnection.DoHandshake: Boolean;
var
  Buf: array[0..2047] of Byte;
  Received, i, tailLen: Integer;
  Request, Key, AcceptKey, Header: string;
begin
  Result := False;
  if FPendingRequest <> '' then
    Request := FPendingRequest
  else
  begin
    Received := FTransport.Read(Buf[0], SizeOf(Buf));
    if Received <= 0 then
    begin
      Bus.Publish('log.warn', 'ws ' + ID + ': no bytes received for handshake', ID);
      Exit;
    end;
    SetString(Request, PAnsiChar(@Buf[0]), Received);
  end;
  i := Pos('Sec-WebSocket-Key:', Request);
  if i = 0 then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake request had no Sec-WebSocket-Key header', ID);
    Exit;
  end;
  tailLen := Pos(#13, Copy(Request, i, Length(Request))) - 20;
  if tailLen < 1 then Exit;
  Key := Trim(Copy(Request, i + 19, tailLen));
  AcceptKey := ComputeAcceptKey(Key);
  Header := 'HTTP/1.1 101 Switching Protocols'#13#10 +
            'Upgrade: websocket'#13#10 +
            'Connection: Upgrade'#13#10 +
            'Sec-WebSocket-Accept: ' + AcceptKey + #13#10#13#10;
  FTransport.Write(Header[1], Length(Header));
  Bus.Publish('log.info', 'ws ' + ID + ': handshake OK', ID);
  Result := True;
end;

// Frames declaring a payload bigger than this are rejected outright rather
// than trusting the client's stated 64-bit length as-is - without a cap, a
// single malicious/buggy frame could claim an enormous length and force a
// huge SetLength allocation before we've even read that much data.
const
  WS_MAX_FRAME_LEN = 64 * 1024 * 1024; // 64MB

function TVDRX_WSConnection.ReadFrame(out APayload: string; out AOpcode: Byte): Boolean;
var
  Hdr: array[0..1] of Byte;
  Ext: array[0..1] of Byte;
  Ext8: array[0..7] of Byte;
  Len: Int64;
  Mask: array[0..3] of Byte;
  Data: array of Byte;
  Received, i: Integer;
  LenByte: Byte;
begin
  Result := False;
  if FTransport.Read(Hdr[0], 2) <> 2 then Exit;
  AOpcode := Hdr[0] and $0F;
  if AOpcode = 8 then Exit;
  LenByte := Hdr[1] and $7F;
  Len := LenByte;
  if LenByte = 126 then
  begin
    if FTransport.Read(Ext[0], 2) <> 2 then Exit;
    Len := (Ext[0] shl 8) or Ext[1];
  end
  else if LenByte = 127 then
  begin
    // 64-bit extended length (RFC 6455 5.2) - previously this branch just
    // aborted and dropped the connection for any frame over 65,535 bytes.
    if FTransport.Read(Ext8[0], 8) <> 8 then Exit;
    Len := 0;
    for i := 0 to 7 do
      Len := (Len shl 8) or Ext8[i];
    if (Len < 0) or (Len > WS_MAX_FRAME_LEN) then Exit; // oversized/malformed - drop rather than allocate
  end;
  if (Hdr[1] and $80) <> 0 then
  begin
    if FTransport.Read(Mask[0], 4) <> 4 then Exit;
  end
  else
    FillChar(Mask, SizeOf(Mask), 0);
  SetLength(Data, Integer(Len));
  Received := 0;
  while Received < Len do
  begin
    i := FTransport.Read(Data[Received], Integer(Len - Received));
    if i <= 0 then Exit; // connection closed/errored mid-frame
    Inc(Received, i);
  end;
  for i := 0 to Integer(Len) - 1 do
    Data[i] := Data[i] xor Mask[i mod 4];
  if Len > 0 then
    SetString(APayload, PAnsiChar(@Data[0]), Integer(Len))
  else
    APayload := '';
  Result := True;
end;

procedure TVDRX_WSConnection.SendFrame(const APayload: string; AOpcode: Byte);
var
  Hdr: array[0..9] of Byte; // 2 base + up to 8 for the 64-bit extended length (RFC 6455 5.2)
  HdrLen: Integer;
  Buf: string;
  PayloadLen: UInt64;
  i: Integer;
begin
  FSendLock.Enter;
  try
    PayloadLen := UInt64(Length(APayload));
    Hdr[0] := $80 or AOpcode;
    if PayloadLen < 126 then
    begin
      Hdr[1] := Byte(PayloadLen);
      HdrLen := 2;
    end
    else if PayloadLen <= 65535 then
    begin
      Hdr[1] := 126;
      Hdr[2] := (PayloadLen shr 8) and $FF;
      Hdr[3] := PayloadLen and $FF;
      HdrLen := 4;
    end
    else
    begin
      // 127 = 64-bit extended length follows, big-endian. Without this branch
      // any payload over 65535 bytes (large history dumps, bulk responses)
      // wrote a truncated 16-bit length via the Hdr[1]:=126 path above,
      // producing a malformed frame the client would reject and disconnect on.
      Hdr[1] := 127;
      for i := 0 to 7 do
        Hdr[2 + i] := (PayloadLen shr ((7 - i) * 8)) and $FF;
      HdrLen := 10;
    end;
    SetString(Buf, PAnsiChar(@Hdr[0]), HdrLen);
    Buf := Buf + APayload;
    FTransport.Write(Buf[1], Length(Buf));
  finally
    FSendLock.Leave;
  end;
end;

{ TVDRX_WSProtocolExecutive }

constructor TVDRX_WSProtocolExecutive.Create(ABus: TVDRX_MessageQueue; AListener: TVDRX_WebSocketExecutive; AConn: TVDRX_WSConnection);
begin
  inherited Create(ABus);
  FListener := AListener;
  FConn := AConn;
  FAuthenticated := False;
end;

// AMsg.Payload is one raw client text frame's worth of JSON - published by
// TVDRX_WSConnection.RunLoop onto this executive's own "<connID>.rpc.in"
// subscription (see TVDRX_WebSocketExecutive.AdoptConnection), never parsed
// by the connectivity object itself. Same method set and behaviour as the
// original in-connection HandleRPC; only WHERE it runs, and how a reply
// reaches the browser (FConn.ID + '.rpc.out' instead of a direct SendFrame
// call - see TVDRX_WSConnection's class comment), has changed.
procedure TVDRX_WSProtocolExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  J: TJSONData;
  Obj: TJSONObject;
  PayloadData: TJSONData;
  Method, Topic, Payload, Token, Src: string;
begin
  try
    J := GetJSON(AMsg.Payload);
  except
    Bus.Publish('log.warn', 'ws ' + FConn.ID + ': dropped malformed JSON RPC: ' + AMsg.Payload, ID);
    Exit;
  end;
  try
    if not (J is TJSONObject) then Exit;
    Obj := TJSONObject(J);
    Method := Obj.Get('method', '');

    if Method = 'sys.auth' then
    begin
      Token := Obj.Get('token', '');
      Src := Obj.Get('source', FConn.ID);
      FAuthenticated := Token <> '';
      if FAuthenticated then
        Bus.Publish('log.info', 'ws ' + FConn.ID + ': authenticated (stub - any nonempty token passes)', ID)
      else
        Bus.Publish('log.warn', 'ws ' + FConn.ID + ': sys.auth sent with an empty token, rejected', ID);
      Bus.Publish(FConn.ID + '.rpc.out', Format('{"event":"auth.ok","source":%s}', [JSONString(Src)]), ID);
      Exit;
    end;

    if not FAuthenticated then
    begin
      Bus.Publish('log.warn', 'ws ' + FConn.ID + ': "' + Method + '" ignored - not authenticated yet', ID);
      Exit;
    end;

    if Method = 'subscribe' then
    begin
      Topic := Obj.Get('filter', '');
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': subscribe "' + Topic + '"', ID);
      FListener.Registry.Register(FConn, FConn.ID, Topic);
    end
    else if Method = 'unsubscribe' then
    begin
      Topic := Obj.Get('filter', '');
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': unsubscribe "' + Topic + '"', ID);
      FListener.Registry.UnregisterFilter(FConn.ID, Topic);
    end
    else if Method = 'unsubscribe_all' then
    begin
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': unsubscribe_all', ID);
      FListener.Registry.ClearFilters(FConn.ID);
    end
    else if Method = 'publish' then
    begin
      Topic := Obj.Get('topic', '');
      PayloadData := Obj.Find('payload');
      if not Assigned(PayloadData) then
        Payload := '{}'
      else if PayloadData.JSONType = jtString then
        Payload := PayloadData.AsString
      else
        Payload := PayloadData.AsJSON;
      Bus.Publish('log.info', 'ws ' + FConn.ID + ': publish "' + Topic + '" ' + Payload, ID);
      Bus.Publish(Topic, Payload, FConn.ID);
    end
    else
      Bus.Publish('log.warn', 'ws ' + FConn.ID + ': unrecognised RPC method "' + Method + '"', ID);
  finally
    J.Free;
  end;
end;

procedure TVDRX_WSConnection.RunLoop;
var
  Payload: string;
  Opcode: Byte;
begin
  if not DoHandshake then
  begin
    Bus.Publish('log.warn', 'ws ' + ID + ': handshake failed, dropping connection', ID);
    Exit;
  end;

  // Only safe to start pinging after the handshake completes - anything sent
  // before that would corrupt the raw HTTP upgrade exchange.
  FLastPong := Now;
  FPingThread := TVDRX_WorkerThread.Create(@PingLoop);
  FPingThread.Start;

  while True do
  begin
    if not ReadFrame(Payload, Opcode) then Break;
    case Opcode of
      // Text frames are pure connectivity's job to MOVE, not interpret -
      // republished onto the bus for TVDRX_WSProtocolExecutive (see its
      // class comment) rather than parsed here.
      1: Bus.Publish(ID + '.rpc.in', Payload, ID);
      9: SendFrame(Payload, 10); // client ping - echo back as pong, per spec
      10: FLastPong := Now;      // reply to OUR ping - see PingLoop
    end;
  end;

  // Stop and free FPingThread BEFORE UnregisterSelf below, which frees Self
  // (FMasterMap has [doOwnsValues]). FPingThread's PingLoop touches FSendLock
  // and FTransport on its own thread; freeing those out from under a still-
  // running PingLoop was a real Access Violation. Setting FStopping here also
  // makes PingLoop notice and exit on its own between iterations even without
  // the join below.
  FStopping := True;
  if Assigned(FPingThread) then
  begin
    WaitThreadOrTimeout(FPingThread, 1000);
    FreeAndNil(FPingThread);
  end;

  Bus.Publish('log.info', 'ws ' + ID + ': disconnected', ID);
  Bus.Publish('sys.ws.disconnected', Format('{"id":%s}', [JSONString(ID)]), ID);
  FListener.Registry.Unregister(ID + '.rpc'); // the protocol executive - external teardown (still running on THIS thread, not its own - it has none), must happen before we UnregisterSelf below
  FListener.Registry.UnregisterSelf(ID); // NOT Unregister - this is our own thread, see vdrx_core.pas's UnregisterSelf comment
  // Self (and every field on it, including FTransport/FSendLock) is invalid
  // from this point on - do not touch anything after the call above.
end;

// Sends a ping every PingIntervalMs and force-closes the transport if no
// pong (ours or a stray client one - either counts as "link is alive") has
// been seen within PingIntervalMs + PongTimeoutMs. Closing FTransport here
// unblocks RunLoop's blocking ReadFrame on another thread - the same
// close-to-unblock idiom Shutdown already relies on (see
// TVDRX_ListenerConnThread.Transport's comment) - so the normal disconnect/
// unregister path in RunLoop runs exactly as it would for a real close,
// no special-casing needed there.
// FLastPong is read/written across threads without a lock - a one-cycle
// stale read just delays detection by ~PingIntervalMs, never causes a false
// disconnect, so it isn't worth a CriticalSection for a heartbeat check.
procedure TVDRX_WSConnection.PingLoop;
var
  Waited: Integer;
begin
  while not FStopping do
  begin
    Waited := 0;
    while (not FStopping) and (Waited < FListener.PingIntervalMs) do
    begin
      Sleep(200);
      Inc(Waited, 200);
    end;
    if FStopping then Break;

    if MilliSecondsBetween(Now, FLastPong) > (FListener.PingIntervalMs + FListener.PongTimeoutMs) then
    begin
      Bus.Publish('log.warn', 'ws ' + ID + ': no pong within timeout, closing stale connection', ID);
      FTransport.Close;
      Break;
    end;

    try
      SendFrame('', 9); // opcode 9 = ping
    except
      Break; // transport already gone - natural disconnect raced us here, RunLoop will handle cleanup
    end;
  end;
end;

procedure TVDRX_WSConnection.Initialize;
begin
  FThread := TWSConnThread.Create(Self);
  FThread.Start;
end;

procedure TVDRX_WSConnection.Shutdown;
begin
  FStopping := True;
  FTransport.Close;
  if Assigned(FThread) then
  begin
    // FThread now has FreeOnTerminate := True (see TWSConnThread.Create), so
    // it frees itself when RunLoop returns - we must NOT call FThread.Free
    // here too, or we'd double-free it. Just wait for it to finish, then
    // drop our own now-dangling reference.
    WaitThreadOrTimeout(FThread, FListener.GracefulTimeoutMs);
    FThread := nil;
  end;
  if Assigned(FPingThread) then
  begin
    if WaitThreadOrTimeout(FPingThread, FListener.GracefulTimeoutMs) then
    begin
      FPingThread.Free;
      FPingThread := nil;
    end
    else
      Bus.Publish('log.warn', 'ws ' + ID + ': ping thread did not exit in time - abandoning it', ID);
  end;
end;

procedure TVDRX_WSConnection.HandlePacket(const AMsg: TVDRX_Message);
begin
  // The protocol executive's own reply channel - already a complete,
  // fully-formed JSON line (e.g. the "auth.ok" event) - relayed to the
  // browser verbatim, NOT wrapped in the topic/payload/source/seq envelope
  // below (which is this connection's own "a browser is a bus participant"
  // wire format for genuine bus traffic, not an RPC reply) - see this
  // class's declaration comment and TVDRX_WSProtocolExecutive's.
  if AMsg.Topic = ID + '.rpc.out' then
  begin
    SendFrame(AMsg.Payload);
    Exit;
  end;
  Bus.Publish('log.info', 'ws ' + ID + ': -> "' + AMsg.Topic + '" ' + AMsg.Payload, ID);
  SendFrame(Format('{"topic":%s,"payload":%s,"source":%s,"seq":%d}',
    [JSONString(AMsg.Topic), AMsg.Payload, JSONString(AMsg.SourceID), AMsg.Seq]));
end;

{ TVDRX_WebSocketExecutive }

constructor TVDRX_WebSocketExecutive.Create(ABus: TVDRX_MessageQueue; AConfig: TVDRX_Config; ARegistry: TVDRX_Registry);
begin
  inherited Create(ABus);
  FConfig := AConfig;
  FRegistry := ARegistry;
  Port := 8082;
  FConnCounter := 0;
  FPingIntervalMs := 15000;
  FPongTimeoutMs := 10000;
end;

function TVDRX_WebSocketExecutive.NextConnID: string;
begin
  Inc(FConnCounter);
  Result := 'ws.conn.' + IntToStr(FConnCounter);
end;

procedure TVDRX_WebSocketExecutive.AdoptConnection(ATransport: TVDRX_Transport; const AInitialRequest: string);
var
  Conn: TVDRX_WSConnection;
  Protocol: TVDRX_WSProtocolExecutive;
  NewID: string;
begin
  Conn := TVDRX_WSConnection.Create(Bus, Self, ATransport);
  Conn.PendingRequest := AInitialRequest;
  NewID := NextConnID;
  Bus.Publish('sys.ws.connected', Format('{"id":%s}', [JSONString(NewID)]), ID);
  Bus.Publish('log.info', 'ws: new connection ' + NewID, ID);
  // Registered on its own "<id>.rpc.out" from the start (not the old
  // "sys.none" placeholder) - that's how a TVDRX_WSProtocolExecutive reply
  // (an auth.ok event, say) reaches this connection at all before the
  // browser has subscribed to anything of its own yet. Further filters
  // (whatever the browser 'subscribe's to) are added on top by the
  // protocol executive below - see its HandlePacket.
  FRegistry.Register(Conn, NewID, NewID + '.rpc.out');
  Protocol := TVDRX_WSProtocolExecutive.Create(Bus, Self, Conn);
  FRegistry.Register(Protocol, NewID + '.rpc', NewID + '.rpc.in');
  Conn.Initialize;
end;

procedure TVDRX_WebSocketExecutive.HandleConnection(ATransport: TVDRX_Transport);
begin
  AdoptConnection(ATransport, '');
end;

procedure TVDRX_WebSocketExecutive.HandlePacket(const AMsg: TVDRX_Message);
begin
  // The listener itself isn't a message recipient - each TVDRX_WSConnection is.
end;

procedure TVDRX_WebSocketExecutive.ApplyConfig;
var
  NewPort, NewTLSPort: Integer;
  CertFile, KeyFile: string;
begin
  NewPort := FConfig.GetInteger('executives.ws.port', 8082);
  NewTLSPort := FConfig.GetInteger('executives.ws.tls_port', 0);
  CertFile := FConfig.GetString('executives.ws.tls_cert', '');
  KeyFile := FConfig.GetString('executives.ws.tls_key', '');
  FPingIntervalMs := FConfig.GetInteger('executives.ws.ping_interval_ms', 15000);
  FPongTimeoutMs := FConfig.GetInteger('executives.ws.pong_timeout_ms', 10000);
  if (NewPort <> Port) or (NewTLSPort <> TLSPort) then
  begin
    Shutdown;
    Port := NewPort;
    ConfigureTLS(NewTLSPort, CertFile, KeyFile);
    Initialize;
  end;
end;

{ TVDRX_SocketClientExecutive }

constructor TVDRX_SocketClientExecutive.Create(ABus: TVDRX_MessageQueue);
begin
  inherited Create(ABus);
  FTransportLock := TCriticalSection.Create;
  FPort := 0;
  FTLS := False;
  FTLSVerify := True;
  FFraming := 'delimiter';
  FDelimiter := #13#10;
  FChunkSize := 4096;
  FReconnectPolicy := 'auto';
  FReconnectDelayMs := 500;
  FMaxReconnectDelayMs := 30000;
  FGracefulTimeoutMs := 5000;
  FStopping := False;
  FConnected := False;
end;

destructor TVDRX_SocketClientExecutive.Destroy;
begin
  FTransportLock.Free;
  inherited Destroy;
end;

// Dials out and, on success, starts the reader thread. Does NOT retry on
// its own - MonitorLoop owns retry/backoff decisions, same division of
// labour as Bridge's StartProcess/MonitorLoop split.
procedure TVDRX_SocketClientExecutive.DoConnect;
var
  Sock: TSocket;
  Ctx: TVDRX_TLSClientContext;
  Transport: TVDRX_Transport;
  PeerName: string;
begin
  Bus.Publish('log.info', Format('%s: (re)connecting to %s:%d ...', [ID, FHost, FPort]), ID);
  if not ConnectRawSocket(FHost, FPort, Sock) then
  begin
    Bus.Publish('log.warn', Format('%s: connect to %s:%d failed', [ID, FHost, FPort]), ID);
    Exit;
  end;

  if FTLS then
  begin
    PeerName := IfThen(FTLSPeerName <> '', FTLSPeerName, FHost);
    Ctx := TVDRX_TLSClientContext.Create(FTLSCAFile, FTLSVerify);
    try
      if not Ctx.OK then
      begin
        Bus.Publish('log.warn', Format('%s: TLS context setup failed for %s:%d (libssl not loadable, or CA file "%s" could not be loaded) - not connecting',
          [ID, FHost, FPort, FTLSCAFile]), ID);
        CloseSocket(Sock);
        Exit;
      end;
      Transport := TVDRX_TLSTransport.Create(Sock, Ctx.Ctx, PeerName);
      if not TVDRX_TLSTransport(Transport).Handshook then
      begin
        Bus.Publish('log.warn', Format('%s: TLS handshake to %s:%d failed (verify_peer=%s, ca_file="%s")',
          [ID, FHost, FPort, BoolToStr(FTLSVerify, True), FTLSCAFile]), ID);
        Transport.Close;
        Transport.Free;
        Exit;
      end;
    finally
      Ctx.Free;
    end;
  end
  else
    Transport := TVDRX_PlainTransport.Create(Sock);

  FTransportLock.Enter;
  try
    FTransport := Transport;
    FConnected := True;
  finally
    FTransportLock.Leave;
  end;

  Bus.Publish('log.info', Format('%s: connected to %s:%d%s', [ID, FHost, FPort, IfThen(FTLS, ' (TLS)', '')]), ID);
  FReaderThread := TVDRX_WorkerThread.Create(@ReaderLoop);
  FReaderThread.FreeOnTerminate := False;
  FReaderThread.Start;
end;

// Same close-to-unblock idiom used throughout this unit (Shutdown on the
// listener side, PingLoop on the WS side) - closing FTransport unblocks
// ReaderLoop's blocking Read on its own thread, so the normal "read
// returned <=0" cleanup path in ReaderLoop runs exactly as it would for a
// genuine remote disconnect, no special-casing needed here.
procedure TVDRX_SocketClientExecutive.DoDisconnect;
var
  Transport: TVDRX_Transport;
  ReaderThread: TThread;
begin
  FTransportLock.Enter;
  try
    Transport := FTransport;
    FTransport := nil;
    FConnected := False;
    ReaderThread := FReaderThread;
    FReaderThread := nil;
  finally
    FTransportLock.Leave;
  end;

  if Assigned(Transport) then
  begin
    Transport.Close;
    if WaitThreadOrTimeout(ReaderThread, FGracefulTimeoutMs) then
    begin
      if Assigned(ReaderThread) then ReaderThread.Free;
    end
    else
      Bus.Publish('log.warn', ID + ': reader thread did not exit in time - abandoning it', ID);
    Transport.Free;
  end;
end;

// Reads in chunks and frames per FFraming, publishing each complete
// message to "<ID>.out". Delimiter mode splits on LINE FEED and silently
// drops any immediately-preceding CR - so both bare \n and \r\n on the wire
// parse identically, regardless of what FDelimiter (write-side only) is set
// to. This mirrors TVDRX_BridgeExecutive.ReaderLoop's existing #13/#10
// handling exactly, not a new behaviour invented for this class.
procedure TVDRX_SocketClientExecutive.ReaderLoop;
const
  BufSize = 4096;
var
  Buf: array[0..BufSize - 1] of Byte;
  Received, i: Integer;
  LineBuf, Line: string;
  Ch: Char;
  Transport: TVDRX_Transport;
  ChunkBuf: string;
begin
  LineBuf := '';
  while not FStopping do
  begin
    FTransportLock.Enter;
    Transport := FTransport;
    FTransportLock.Leave;
    if not Assigned(Transport) then Break;

    if FFraming = 'chunk' then
    begin
      SetLength(ChunkBuf, FChunkSize);
      Received := Transport.Read(ChunkBuf[1], FChunkSize);
      if Received > 0 then
        Bus.Publish(ID + '.out', Copy(ChunkBuf, 1, Received), ID)
      else
      begin
        FTransportLock.Enter;
        FConnected := False;
        FTransportLock.Leave;
        Break;
      end;
    end
    else
    begin
      Received := Transport.Read(Buf, SizeOf(Buf));
      if Received > 0 then
      begin
        for i := 0 to Received - 1 do
        begin
          Ch := Chr(Buf[i]);
          if Ch = #10 then
          begin
            Line := LineBuf;
            LineBuf := '';
            if Line <> '' then
              Bus.Publish(ID + '.out', Line, ID);
          end
          else if Ch <> #13 then
            LineBuf := LineBuf + Ch;
        end;
      end
      else
      begin
        FTransportLock.Enter;
        FConnected := False;
        FTransportLock.Leave;
        Break;
      end;
    end;
  end;
end;

// Watches FConnected and applies FReconnectPolicy - the direct counterpart
// to TVDRX_BridgeExecutive.MonitorLoop, same 500ms-doubling-to-30000ms
// backoff shape, reset to FReconnectDelayMs's starting value after a clean
// (re)connect. There's no exit-code distinction to make here the way
// Bridge's 'on-failure' has (a dropped socket doesn't carry one), so this
// only supports the two policies actually asked for.
procedure TVDRX_SocketClientExecutive.MonitorLoop;
var
  StillConnected: Boolean;
  StartDelayMs: Integer;
begin
  StartDelayMs := FReconnectDelayMs;
  while not FStopping do
  begin
    Sleep(1000);
    if FStopping then Break;

    FTransportLock.Enter;
    StillConnected := FConnected;
    FTransportLock.Leave;

    if (not StillConnected) and (not FStopping) then
    begin
      DoDisconnect; // clears FTransport/FReaderThread even if ReaderLoop already exited on its own

      if FReconnectPolicy = 'none' then
      begin
        Bus.Publish('log.info', Format('%s: disconnected, reconnect policy "none" - leaving it down', [ID]), ID);
        Exit;
      end;

      Sleep(FReconnectDelayMs);
      if FReconnectDelayMs < FMaxReconnectDelayMs then
        FReconnectDelayMs := FReconnectDelayMs * 2; // exponential backoff on a reconnect loop
      if not FStopping then
      begin
        DoConnect;
        FReconnectDelayMs := StartDelayMs; // reset after a clean (re)connect attempt
      end;
    end;
  end;
end;

procedure TVDRX_SocketClientExecutive.Initialize;
begin
  FStopping := False;
  DoConnect;
  FMonitorThread := TVDRX_WorkerThread.Create(@MonitorLoop);
  FMonitorThread.FreeOnTerminate := False;
  FMonitorThread.Start;
end;

procedure TVDRX_SocketClientExecutive.Shutdown;
begin
  FStopping := True;
  DoDisconnect;
  if Assigned(FMonitorThread) then
  begin
    if WaitThreadOrTimeout(FMonitorThread, FGracefulTimeoutMs) then
      FMonitorThread.Free
    else
      Bus.Publish('log.warn', ID + ': monitor thread did not exit in time - abandoning it', ID);
    FMonitorThread := nil;
  end;
end;

// Writes AMsg.Payload straight to the socket, framed per FFraming - NOT
// JSON-wrapped the way Bridge's stdin protocol is, because the payload IS
// the wire protocol here (an IRC line, an SMTP command, ...), not an
// envelope around one. Which messages even reach this executive at all is
// governed entirely by its Registry subscription filter(s), set up
// alongside every other config-driven executive in vdrx.lpr - this method
// doesn't re-check the topic itself.
procedure TVDRX_SocketClientExecutive.HandlePacket(const AMsg: TVDRX_Message);
var
  Transport: TVDRX_Transport;
  OutStr: string;
begin
  FTransportLock.Enter;
  Transport := FTransport;
  FTransportLock.Leave;
  if not Assigned(Transport) then Exit; // not currently connected - message is dropped, not queued

  if FFraming = 'chunk' then
    OutStr := AMsg.Payload
  else
    OutStr := AMsg.Payload + FDelimiter;

  if Length(OutStr) > 0 then
    Transport.Write(OutStr[1], Length(OutStr));
end;

initialization
  GReplyTopicLock := TCriticalSection.Create;

finalization
  GReplyTopicLock.Free;

end.

