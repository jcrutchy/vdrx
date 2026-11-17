unit vdrx_sha256;

{$mode ObjFPC}{$H+}

// SHA-256 (FIPS 180-4), for one job: storing a WebSocket token as a hash instead of in the clear
// ("token_hash"). A fast, unsalted hash is the right tool ONLY because those tokens are long random
// values (vdrx --new-token makes 256-bit ones): an attacker who reads the config still cannot recover
// one, and nothing is gained by slowing down a guess at 2^256 possibilities. It is NOT suitable for
// hashing human-chosen passwords. The unit is checked against the NIST test vectors in
// tests/unit/test_sha256.lpr.

interface

uses
  SysUtils;

// Lower-case hex SHA-256 of the bytes of S (64 characters).
function VDRX_SHA256Hex(const S: string): string;

implementation

const
  K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2);

function RotR(X: Cardinal; N: Integer): Cardinal; inline;
begin
  Result := (X shr N) or (X shl (32 - N));
end;

procedure Block(var H: array of Cardinal; const P: PByte);
var
  W: array[0..63] of Cardinal;
  A, B, C, D, E, F, G, HH, T1, T2, S0, S1: Cardinal;
  i: Integer;
begin
  for i := 0 to 15 do
    W[i] := (Cardinal(P[i * 4]) shl 24) or (Cardinal(P[i * 4 + 1]) shl 16) or (Cardinal(P[i * 4 + 2]) shl 8) or P[i * 4 + 3];
  for i := 16 to 63 do
  begin
    S0 := RotR(W[i - 15], 7) xor RotR(W[i - 15], 18) xor (W[i - 15] shr 3);
    S1 := RotR(W[i - 2], 17) xor RotR(W[i - 2], 19) xor (W[i - 2] shr 10);
    W[i] := W[i - 16] + S0 + W[i - 7] + S1;
  end;
  A := H[0]; B := H[1]; C := H[2]; D := H[3]; E := H[4]; F := H[5]; G := H[6]; HH := H[7];
  for i := 0 to 63 do
  begin
    S1 := RotR(E, 6) xor RotR(E, 11) xor RotR(E, 25);
    T1 := HH + S1 + ((E and F) xor ((not E) and G)) + K[i] + W[i];
    S0 := RotR(A, 2) xor RotR(A, 13) xor RotR(A, 22);
    T2 := S0 + ((A and B) xor (A and C) xor (B and C));
    HH := G; G := F; F := E; E := D + T1; D := C; C := B; B := A; A := T1 + T2;
  end;
  H[0] := H[0] + A; H[1] := H[1] + B; H[2] := H[2] + C; H[3] := H[3] + D;
  H[4] := H[4] + E; H[5] := H[5] + F; H[6] := H[6] + G; H[7] := H[7] + HH;
end;

function VDRX_SHA256Hex(const S: string): string;
var
  H: array[0..7] of Cardinal;
  Buf: array of Byte;
  Len, PadLen, i: Integer;
  Bits: QWord;
begin
  H[0] := $6a09e667; H[1] := $bb67ae85; H[2] := $3c6ef372; H[3] := $a54ff53a;
  H[4] := $510e527f; H[5] := $9b05688c; H[6] := $1f83d9ab; H[7] := $5be0cd19;
  Len := Length(S);
  PadLen := ((Len + 8) div 64 + 1) * 64;                  // message + 0x80 + zeros + 8 length bytes, whole blocks
  SetLength(Buf, PadLen);
  FillChar(Buf[0], PadLen, 0);
  if Len > 0 then Move(S[1], Buf[0], Len);
  Buf[Len] := $80;
  Bits := QWord(Len) * 8;
  for i := 0 to 7 do Buf[PadLen - 1 - i] := (Bits shr (8 * i)) and $FF;
  for i := 0 to PadLen div 64 - 1 do Block(H, @Buf[i * 64]);
  Result := '';
  for i := 0 to 7 do Result := Result + LowerCase(IntToHex(H[i], 8));
end;

end.
