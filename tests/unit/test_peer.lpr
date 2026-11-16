program test_peer;

{$mode objfpc}{$H+}

// DecodePeer (vdrx_connection.pas): what accept() wrote into the address buffer, turned into the text vdrx
// reports. The buffers are built byte by byte in the Linux x86-64 kernel ABI (struct sockaddr_in / sockaddr_in6),
// NOT with FPC's records, so this also catches FPC's record layout disagreeing with the kernel's - the thing an
// IPv6 listener silently depends on and that cannot be exercised on a host without IPv6.
//
//   fpc -Mobjfpc -Fu../../src test_peer.lpr ; ./test_peer        (exit code 0 = all passed)

uses
  SysUtils, vdrx_connection;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

type
  TBytes16 = array[0..15] of Byte;

procedure Put16LE(var S: TVDRX_SockStorage; AOfs: Integer; V: Word);
begin
  PByte(@S)[AOfs] := V and $FF; PByte(@S)[AOfs + 1] := V shr 8;
end;
procedure Put16BE(var S: TVDRX_SockStorage; AOfs: Integer; V: Word);
begin
  PByte(@S)[AOfs] := V shr 8; PByte(@S)[AOfs + 1] := V and $FF;
end;

procedure MakeV4(var S: TVDRX_SockStorage; A, B, C, D: Byte; APort: Word);
begin
  FillChar(S, SizeOf(S), 0);
  Put16LE(S, 0, 2);                                   // AF_INET
  Put16BE(S, 2, APort);
  PByte(@S)[4] := A; PByte(@S)[5] := B; PByte(@S)[6] := C; PByte(@S)[7] := D;
end;

procedure MakeV6(var S: TVDRX_SockStorage; const AAddr: TBytes16; APort: Word);
begin
  FillChar(S, SizeOf(S), 0);
  Put16LE(S, 0, 10);                                  // AF_INET6
  Put16BE(S, 2, APort);                               // offset 2
  PByte(@S)[4] := $DE; PByte(@S)[5] := $AD; PByte(@S)[6] := $BE; PByte(@S)[7] := $EF;   // flowinfo (offset 4), must be ignored
  Move(AAddr, PByte(@S)[8], 16);                      // sin6_addr at offset 8
  PByte(@S)[24] := 7;                                 // scope id (offset 24), must be ignored
end;

var
  S: TVDRX_SockStorage;
  A: string;
  P: Word;
  Loop6, Mapped, Glob: TBytes16;
begin
  Passed := 0; Failed := 0;

  WriteLn('-- IPv4');
  MakeV4(S, 203, 0, 113, 9, 8080);
  Check(DecodePeer(S, A, P) and (A = '203.0.113.9') and (P = 8080), 'IPv4 address and port');

  WriteLn('-- IPv6');
  FillChar(Loop6, 16, 0); Loop6[15] := 1;
  MakeV6(S, Loop6, 443);
  Check(DecodePeer(S, A, P) and (A = '::1') and (P = 443), 'IPv6 loopback and port 443');
  Glob[0] := $20; Glob[1] := $01; Glob[2] := $0d; Glob[3] := $b8; FillChar(Glob[4], 12, 0); Glob[7] := $42; Glob[15] := $99;
  MakeV6(S, Glob, 54321);
  Check(DecodePeer(S, A, P) and (A = '2001:db8:0:42::99') and (P = 54321), 'a global address, port above 32767');
  FillChar(Mapped, 16, 0); Mapped[10] := $FF; Mapped[11] := $FF; Mapped[12] := 10; Mapped[13] := 1; Mapped[14] := 2; Mapped[15] := 3;
  MakeV6(S, Mapped, 1234);
  Check(DecodePeer(S, A, P) and (A = '10.1.2.3') and (P = 1234), 'an IPv4-mapped peer (dual-stack socket) is reported as plain IPv4');

  WriteLn('-- anything else is refused');
  FillChar(S, SizeOf(S), 0); Put16LE(S, 0, 1);       // AF_UNIX
  Check(not DecodePeer(S, A, P) and (A = ''), 'an unknown address family is not decoded');
  FillChar(S, SizeOf(S), 0);
  Check(not DecodePeer(S, A, P), 'an all-zero buffer (family 0) is not decoded');

  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
