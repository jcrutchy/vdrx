program test_jsonconf;

{$mode ObjFPC}{$H+}

// Self-contained tests for jsonconf.pas (variables, includes, safe reload).
// Writes its own fixture files into a temp directory and removes them again.
//
//   fpc -Mobjfpc -Sh test_jsonconf.lpr
//   ./test_jsonconf          (exit code 0 = all passed)

uses
  SysUtils, Classes, fpjson, jsonparser, jsonconf;

var
  TmpDir: string;
  Passed, Failed: Integer;

procedure Check(ACond: Boolean; const AName: string);
begin
  if ACond then
  begin
    Inc(Passed);
    WriteLn('  ok    ', AName);
  end
  else
  begin
    Inc(Failed);
    WriteLn('  FAIL  ', AName);
  end;
end;

procedure CheckStr(const AActual, AExpected, AName: string);
begin
  if AActual = AExpected then
    Check(True, AName)
  else
  begin
    Check(False, AName);
    WriteLn('          expected: [', AExpected, ']');
    WriteLn('          actual:   [', AActual, ']');
  end;
end;

procedure WriteFile(const ARelPath, AContent: string);
var
  SL: TStringList;
  P: string;
begin
  P := TmpDir + ARelPath;
  ForceDirectories(ExtractFileDir(P));
  SL := TStringList.Create;
  try
    SL.Text := AContent;
    SL.SaveToFile(P);
  finally
    SL.Free;
  end;
end;

procedure RemoveTree(const ADir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(ADir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
        RemoveTree(IncludeTrailingPathDelimiter(ADir) + SR.Name)
      else
        DeleteFile(IncludeTrailingPathDelimiter(ADir) + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(ADir);
end;

function Contains(const AText, ASub: string): Boolean;
begin
  Result := Pos(ASub, AText) > 0;
end;

procedure TestBasics;
var
  C: TJsonConf;
  Plat, Arch: string;
begin
  WriteLn('reserved + user variables');
  {$IFDEF MSWINDOWS} Plat := 'windows'; {$ELSE} Plat := 'linux'; {$ENDIF}
  {$IFDEF CPUX86_64} Arch := 'x86_64'; {$ELSE} Arch := 'other'; {$ENDIF}
  WriteFile('basic.conf',
    '{"variables": {' +
    '  "PHP_BIN_FILENAME": "php{EXE_EXT}",' +
    '  "ADMIN_EMAIL_ADDRESS": "admin@example.com",' +
    '  "ROOT": "{APP_ROOT_PATH}{PATH_SEPARATOR}x",' +
    '  "PORT": "8080"' +
    '},' +
    '"plat": "{PLATFORM}", "arch": "{ARCHITECTURE}", "sep": "{PATH_SEPARATOR}",' +
    '"php": "{PHP_BIN_FILENAME}", "root": "{ROOT}", "email": "mailto:{ADMIN_EMAIL_ADDRESS}",' +
    '"port": "{PORT}", "braces": "{LBRACE}x{RBRACE}",' +
    '"app": "{APP_BIN_FILENAME}",' +
    '"json_literal": "{\"a\":1}", "csv_literal": "{status,body}", "plain_brace": "a { b } c",' +
    '"description": "docs may mention {NOT_DEFINED_ANYWHERE} freely",' +
    '"x_description": "{ALSO_NOT_DEFINED}"}');
  C := TJsonConf.Create(TmpDir + 'basic.conf');
  try
    Check(C.Loaded, 'loads');
    CheckStr(C.LastErrors, '', 'no errors');
    CheckStr(C.GetString('plat', ''), Plat, '{PLATFORM}');
    CheckStr(C.GetString('arch', ''), Arch, '{ARCHITECTURE}');
    CheckStr(C.GetString('sep', ''), DirectorySeparator, '{PATH_SEPARATOR}');
    {$IFDEF MSWINDOWS}
    CheckStr(C.GetString('php', ''), 'php.exe', 'variable using reserved EXE_EXT (windows)');
    {$ELSE}
    CheckStr(C.GetString('php', ''), 'php', 'variable using reserved EXE_EXT (empty on unix)');
    {$ENDIF}
    CheckStr(C.GetString('root', ''), ExtractFileDir(ExpandFileName(ParamStr(0))) + DirectorySeparator + 'x',
      'variable using APP_ROOT_PATH + PATH_SEPARATOR');
    CheckStr(C.GetString('email', ''), 'mailto:admin@example.com', 'variable inside longer string');
    Check(C.GetInteger('port', 0) = 8080, 'string variable read back via GetInteger');
    CheckStr(C.GetString('braces', ''), '{x}', '{LBRACE}/{RBRACE}');
    CheckStr(C.GetString('app', ''), ExtractFileName(ParamStr(0)), '{APP_BIN_FILENAME}');
    CheckStr(C.GetString('json_literal', ''), '{"a":1}', 'JSON text in a string is left alone');
    CheckStr(C.GetString('csv_literal', ''), '{status,body}', '{status,body} is left alone');
    CheckStr(C.GetString('plain_brace', ''), 'a { b } c', 'brace pair with spaces is left alone');
    CheckStr(C.GetString('description', ''), 'docs may mention {NOT_DEFINED_ANYWHERE} freely', '"description" is never expanded');
    CheckStr(C.GetString('x_description', ''), '{ALSO_NOT_DEFINED}', '"*_description" is never expanded');
    CheckStr(C.GetString('variables.ADMIN_EMAIL_ADDRESS', ''), 'admin@example.com', 'resolved variables readable via variables.*');
    CheckStr(C.GetString('variables.PHP_BIN_FILENAME', 'missing'), C.GetString('php', ''), 'variables.* holds the resolved value');
  finally
    C.Free;
  end;
end;

procedure TestRecursion;
var
  C: TJsonConf;
begin
  WriteLn('recursive variables, variables in names and keys');
  WriteLn('  (env PATH is ', Length(GetEnvironmentVariable('PATH')), ' chars)');
  WriteFile('rec.conf',
    '{"variables": {' +
    '  "A": "{B}/a", "B": "{C}-b", "C": "c",' +
    '  "PFX": "my", "{PFX}_NAME": "named", "WHICH": "1", "VAR_1": "one",' +
    '  "LATE": "{EARLY}!", "EARLY": "e"' +
    '},' +
    '"a": "{A}", "dyn_name": "{my_NAME}", "nested_ref": "{VAR_{WHICH}}", "late": "{LATE}",' +
    '"{PFX}_key": "value-under-templated-key",' +
    '"list": ["{C}", "{A}"],' +
    '"obj": {"inner": "{B}"},' +
    '"env_path": "{ENV:PATH}", "env_default": "{ENV:SURELY_NOT_SET_ABC_123:-fallback}",' +
    '"env_default_vars": "{ENV:SURELY_NOT_SET_ABC_123:-{C}/d}", "env_empty_default": "[{ENV:SURELY_NOT_SET_ABC_123:-}]"}');
  C := TJsonConf.Create(TmpDir + 'rec.conf');
  try
    Check(C.Loaded, 'loads');
    CheckStr(C.LastErrors, '', 'no errors');
    CheckStr(C.GetString('a', ''), 'c-b/a', 'A -> B -> C chain');
    CheckStr(C.GetString('dyn_name', ''), 'named', 'variable whose NAME contains a variable');
    CheckStr(C.GetString('nested_ref', ''), 'one', '{VAR_{WHICH}} nested reference');
    CheckStr(C.GetString('late', ''), 'e!', 'use-before-declare order');
    CheckStr(C.GetString('my_key', ''), 'value-under-templated-key', 'object KEY containing a variable');
    CheckStr(C.GetStringArray('list')[1], 'c-b/a', 'inside arrays');
    CheckStr(C.GetString('obj.inner', ''), 'c-b', 'inside nested objects');
    CheckStr(C.GetString('env_path', ''), GetEnvironmentVariable('PATH'), '{ENV:PATH}');
    CheckStr(C.GetString('env_default', ''), 'fallback', '{ENV:X:-default}');
    CheckStr(C.GetString('env_default_vars', ''), 'c/d', 'variables inside an ENV default');
    CheckStr(C.GetString('env_empty_default', ''), '[]', '{ENV:X:-} (empty default)');
  finally
    C.Free;
  end;
end;

procedure TestErrors;
var
  C: TJsonConf;
begin
  WriteLn('errors');
  WriteFile('cyc2.conf', '{"variables": {"A": "{B}", "B": "{A}"}, "x": "{A}"}');
  C := TJsonConf.Create(TmpDir + 'cyc2.conf');
  try
    Check(not C.Loaded, '2-cycle rejected');
    Check(Contains(C.LastErrors, 'circular variable reference: A -> B -> A'), '2-cycle message names the chain: ' + C.LastErrors);
  finally
    C.Free;
  end;

  WriteFile('cyc1.conf', '{"variables": {"A": "x{A}"}}');
  C := TJsonConf.Create(TmpDir + 'cyc1.conf');
  try
    Check(not C.Loaded, 'self-reference rejected');
    Check(Contains(C.LastErrors, 'A -> A'), 'self-reference message');
  finally
    C.Free;
  end;

  WriteFile('cyc3.conf', '{"variables": {"A": "{B}", "B": "{C}", "C": "{A}", "UNUSED": "fine"}}');
  C := TJsonConf.Create(TmpDir + 'cyc3.conf');
  try
    Check(not C.Loaded, '3-cycle rejected even though no key uses the variables');
    Check(Contains(C.LastErrors, 'A -> B -> C -> A'), '3-cycle message');
  finally
    C.Free;
  end;

  WriteFile('cycname.conf', '{"variables": {"{X}": "v", "X": "{{X}}"}}');
  C := TJsonConf.Create(TmpDir + 'cycname.conf');
  try
    Check(not C.Loaded, 'variable whose name needs itself is rejected');
  finally
    C.Free;
  end;

  WriteFile('undef.conf', '{"processes": [{"command": "{NO_SUCH_VAR} --go"}]}');
  C := TJsonConf.Create(TmpDir + 'undef.conf');
  try
    Check(not C.Loaded, 'undefined variable rejected');
    Check(Contains(C.LastErrors, 'processes[0].command') and Contains(C.LastErrors, '{NO_SUCH_VAR}'),
      'undefined-variable message gives the key path: ' + C.LastErrors);
  finally
    C.Free;
  end;

  WriteFile('envunset.conf', '{"x": "{ENV:SURELY_NOT_SET_ABC_123}"}');
  C := TJsonConf.Create(TmpDir + 'envunset.conf');
  try
    Check(not C.Loaded, 'unset env var without default rejected');
    Check(Contains(C.LastErrors, 'SURELY_NOT_SET_ABC_123'), 'message names the env var');
  finally
    C.Free;
  end;

  WriteFile('reserved.conf', '{"variables": {"PLATFORM": "beos"}}');
  C := TJsonConf.Create(TmpDir + 'reserved.conf');
  try
    Check(not C.Loaded, 'redeclaring a reserved name rejected');
    Check(Contains(C.LastErrors, 'reserved'), 'message says reserved');
  finally
    C.Free;
  end;

  WriteFile('badname.conf', '{"variables": {"bad name": "x"}}');
  C := TJsonConf.Create(TmpDir + 'badname.conf');
  try
    Check(not C.Loaded, 'invalid variable name rejected');
  finally
    C.Free;
  end;

  WriteFile('dupkey.conf', '{"variables": {"K": "same"}, "same": 1, "{K}": 2}');
  C := TJsonConf.Create(TmpDir + 'dupkey.conf');
  try
    Check(not C.Loaded, 'key that expands onto an existing key rejected');
  finally
    C.Free;
  end;

  WriteFile('badjson.conf', '{"x": ');
  C := TJsonConf.Create(TmpDir + 'badjson.conf');
  try
    Check(not C.Loaded, 'malformed JSON rejected');
  finally
    C.Free;
  end;

  C := TJsonConf.Create(TmpDir + 'does_not_exist.conf');
  try
    Check(not C.Loaded, 'missing top-level file rejected');
    Check(Contains(C.LastErrors, 'not found'), 'message says not found');
  finally
    C.Free;
  end;
end;

procedure TestReloadKeepsOld;
var
  C: TJsonConf;
begin
  WriteLn('reload keeps the last good config');
  WriteFile('reload.conf', '{"variables": {"V": "one"}, "x": "{V}", "keep": 1}');
  C := TJsonConf.Create(TmpDir + 'reload.conf');
  try
    CheckStr(C.GetString('x', ''), 'one', 'initial load');

    WriteFile('reload.conf', '{"variables": {"V": "{W}", "W": "{V}"}, "x": "{V}", "keep": 2}');
    Check(not C.Reload, 'Reload returns False for a circular config');
    CheckStr(C.GetString('x', ''), 'one', 'old value still in force');
    Check(C.GetInteger('keep', 0) = 1, 'old config entirely intact');
    Check(Contains(C.LastErrors, 'circular'), 'LastErrors explains why');
    Check(C.Loaded, 'still Loaded');

    WriteFile('reload.conf', '{"variables": {"V": "two"}, "x": "{V}", "keep": 3}');
    Check(C.Reload, 'Reload returns True once fixed');
    CheckStr(C.GetString('x', ''), 'two', 'new value in force');
    CheckStr(C.LastErrors, '', 'LastErrors cleared');
  finally
    C.Free;
  end;
end;

procedure TestIncludes;
var
  C: TJsonConf;
  Rows: TJsonConfRows;
begin
  WriteLn('includes');
  WriteFile('inc/top.conf',
    '{"includes": ["{CONF_DIR}/{SUBDIR}/child.conf", "sub2/other.conf", "does/not/exist.conf"],' +
    ' "variables": {"SUBDIR": "sub1", "SHARED": "from-top", "TOP_ONLY": "t"},' +
    ' "scalar": "top-wins", "processes": [{"id": "top_proc", "dir": "{CONF_DIR}"}]}');
  WriteFile('inc/sub1/child.conf',
    '{"variables": {"SHARED": "from-child", "CHILD_VAR": "cv-{TOP_ONLY}"},' +
    ' "scalar": "child-loses", "child_only": "{CHILD_VAR}/{SHARED}",' +
    ' "processes": [{"id": "child_proc", "dir": "{CONF_DIR}", "file": "{CONF_FILE}"}]}');
  WriteFile('inc/sub2/other.conf',
    '{"includes": ["../sub3/deep.conf"], "processes": [{"id": "other_proc"}]}');
  WriteFile('inc/sub3/deep.conf',
    '{"processes": [{"id": "deep_proc", "main": "{MAIN_CONF_DIR}"}]}');
  C := TJsonConf.Create(TmpDir + 'inc/top.conf');
  try
    Check(C.Loaded, 'loads: ' + C.LastErrors);
    CheckStr(C.GetString('scalar', ''), 'top-wins', 'including file wins on scalars');
    CheckStr(C.GetString('child_only', ''), 'cv-t/from-top', 'include sees top-level variables; top-level overrides include default');
    Rows := C.GetObjectArray('processes');
    try
      Check(Rows.Count = 4, 'arrays accumulate across 3 levels of includes (' + IntToStr(Rows.Count) + ')');
      if Rows.Count = 4 then
      begin
        CheckStr(Rows[0].Values['dir'], ExtractFileDir(ExpandFileName(TmpDir + 'inc/top.conf')), '{CONF_DIR} in the top file');
        CheckStr(Rows[1].Values['dir'], ExtractFileDir(ExpandFileName(TmpDir + 'inc/sub1/child.conf')), '{CONF_DIR} in an included file is ITS directory');
        CheckStr(Rows[1].Values['file'], 'child.conf', '{CONF_FILE}');
        CheckStr(Rows[3].Values['main'], ExtractFileDir(ExpandFileName(TmpDir + 'inc/top.conf')), '{MAIN_CONF_DIR} always names the top-level file''s directory');
      end;
    finally
      Rows.Free;
    end;
  finally
    C.Free;
  end;

  WriteFile('inc/badinc.conf', '{"includes": ["sub_bad/broken.conf"], "x": 1}');
  WriteFile('inc/sub_bad/broken.conf', '{"oops": ');
  C := TJsonConf.Create(TmpDir + 'inc/badinc.conf');
  try
    Check(not C.Loaded, 'an include with a JSON syntax error rejects the whole load');
  finally
    C.Free;
  end;

  WriteFile('inc/badpath.conf', '{"includes": ["{NOPE}/x.conf"], "x": 1}');
  C := TJsonConf.Create(TmpDir + 'inc/badpath.conf');
  try
    Check(not C.Loaded, 'undefined variable in an include path rejected');
  finally
    C.Free;
  end;
end;

procedure TestArrayRows;
var
  C: TJsonConf;
  Rows: TJsonConfRows;
  J: TJSONData;
begin
  WriteLn('arrays in config rows');
  WriteFile('rows.conf', '{"items": [{"id": "a", "args": ["--x=1,2", "plain", "has space"]}]}');
  C := TJsonConf.Create(TmpDir + 'rows.conf');
  try
    Rows := C.GetObjectArray('items');
    try
      CheckStr(Rows[0].Values['args'], '--x=1,2,plain,has space', 'array comma-joined (legacy form)');
      J := GetJSON(Rows[0].Values['args#json']);
      try
        Check((J is TJSONArray) and (TJSONArray(J).Count = 3) and (TJSONArray(J).Strings[0] = '--x=1,2')
          and (TJSONArray(J).Strings[2] = 'has space'), 'array also kept exactly as args#json (element boundaries intact)');
      finally
        J.Free;
      end;
    finally
      Rows.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TestLegacy;
var
  C: TJsonConf;
begin
  WriteLn('legacy ${VAR:-default} still works');
  WriteFile('legacy.conf', '{"x": "${SURELY_NOT_SET_ABC_123:-legacy-default}"}');
  C := TJsonConf.Create(TmpDir + 'legacy.conf');
  try
    CheckStr(C.GetString('x', ''), 'legacy-default', 'legacy env expansion');
  finally
    C.Free;
  end;
end;

begin
  Passed := 0;
  Failed := 0;
  TmpDir := IncludeTrailingPathDelimiter(GetTempDir) + 'jsonconf_test_' + IntToStr(GetProcessID) + PathDelim;
  ForceDirectories(TmpDir);
  try
    TestBasics;
    TestRecursion;
    TestErrors;
    TestReloadKeepsOld;
    TestIncludes;
    TestLegacy;
    TestArrayRows;
  finally
    RemoveTree(ExcludeTrailingPathDelimiter(TmpDir));
  end;
  WriteLn;
  WriteLn(Passed, ' passed, ', Failed, ' failed');
  if Failed > 0 then Halt(1);
end.
