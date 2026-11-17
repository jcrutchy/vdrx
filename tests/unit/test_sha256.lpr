program test_sha256;

{$mode objfpc}{$H+}

// vdrx_sha256.pas against the NIST / FIPS 180-4 test vectors (and block-boundary lengths).
//
//   fpc -Mobjfpc -Fu../../src test_sha256.lpr ; ./test_sha256        (exit code 0 = all passed)

uses
  SysUtils, vdrx_sha256;

var
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then begin Inc(Passed); WriteLn('  ok    ', AName); end
  else begin Inc(Failed); WriteLn('  FAIL  ', AName); end;
end;

var
  S: string;
  i: Integer;
begin
  Passed := 0; Failed := 0;
  Check(VDRX_SHA256Hex('') = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'empty string');
  Check(VDRX_SHA256Hex('abc') = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', '"abc"');
  Check(VDRX_SHA256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq') =
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', 'the 448-bit NIST message (padding spills into a second block)');
  Check(VDRX_SHA256Hex('abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu') =
    'cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1', 'the 896-bit NIST message');
  S := StringOfChar('a', 1000000);
  Check(VDRX_SHA256Hex(S) = 'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0', 'one million "a"');
  // lengths around the 55/56/63/64-byte padding edges, compared with values computed independently (Python hashlib)
  Check(VDRX_SHA256Hex(StringOfChar('x', 55)) = 'd5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072', '55 bytes (padding just fits)');
  Check(VDRX_SHA256Hex(StringOfChar('x', 56)) = '04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e', '56 bytes (length no longer fits in the block)');
  Check(VDRX_SHA256Hex(StringOfChar('x', 63)) = '75220b47218278e656f2013bb8f0c455a25eaf01e86c64924e9d48d89776d6f2', '63 bytes');
  Check(VDRX_SHA256Hex(StringOfChar('x', 64)) = '7ce100971f64e7001e8fe5a51973ecdfe1ced42befe7ee8d5fd6219506b5393c', '64 bytes (exactly one block)');
  Check(VDRX_SHA256Hex(StringOfChar('x', 65)) = '9537c5fdf120482f7d58d25e9ed583f52c02b4e304ea814db1633ad565aed7e9', '65 bytes');
  Check(VDRX_SHA256Hex(StringOfChar('x', 119)) = '000b48d4edf0fa7bee3c6236ecd2785baa5db4eeb8bb54341b029e0d9fa5fb0c', '119 bytes');
  Check(VDRX_SHA256Hex(StringOfChar('x', 120)) = '13f05a0b594787f5ecd315edc96141bd3243203d1b7d4f0836f37308b276ba98', '120 bytes');
  Check(VDRX_SHA256Hex(#0#255#128) = 'f742b965f156c10374bc23aea96e3a8aff8facd6fc079defeaa30219ad86f211', 'bytes outside ASCII (0, 255, 128)');
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
