// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.HookEntryTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  THookEntryTests = class
  public
    // ParseSessionStartPayload
    [Test] procedure ParseStart_ValidJson_ExtractsBoth;
    [Test] procedure ParseStart_MissingCwd_ReturnsTrueWithEmpty;
    [Test] procedure ParseStart_MissingSessionId_ReturnsTrueWithEmpty;
    [Test] procedure ParseStart_ExtraFields_Ignored;
    [Test] procedure ParseStart_InvalidJson_ReturnsFalse;
    [Test] procedure ParseStart_NotAnObject_ReturnsFalse;
    [Test] procedure ParseStart_EmptyString_ReturnsFalse;
    [Test] procedure ParseStart_HandlesEscapedBackslashes;

    // ParseSessionEndPayload
    [Test] procedure ParseEnd_ValidJson_ExtractsBoth;
    [Test] procedure ParseEnd_OnlySessionId;
    [Test] procedure ParseEnd_InvalidJson_ReturnsFalse;
    [Test] procedure ParseEnd_AllReasonValues;
  end;

implementation

uses
  System.SysUtils,
  DelphiLsp.HookEntry;

procedure THookEntryTests.ParseStart_ValidJson_ExtractsBoth;
var
  SessionId, Cwd: string;
begin
  Assert.IsTrue(ParseSessionStartPayload(
    '{"session_id":"abc-123","cwd":"D:\\foo"}', SessionId, Cwd));
  Assert.AreEqual('abc-123', SessionId);
  Assert.AreEqual('D:\foo', Cwd);
end;

procedure THookEntryTests.ParseStart_MissingCwd_ReturnsTrueWithEmpty;
var
  SessionId, Cwd: string;
begin
  Assert.IsTrue(ParseSessionStartPayload(
    '{"session_id":"abc"}', SessionId, Cwd));
  Assert.AreEqual('abc', SessionId);
  Assert.AreEqual('', Cwd);
end;

procedure THookEntryTests.ParseStart_MissingSessionId_ReturnsTrueWithEmpty;
var
  SessionId, Cwd: string;
begin
  Assert.IsTrue(ParseSessionStartPayload(
    '{"cwd":"D:\\foo"}', SessionId, Cwd));
  Assert.AreEqual('', SessionId);
  Assert.AreEqual('D:\foo', Cwd);
end;

procedure THookEntryTests.ParseStart_ExtraFields_Ignored;
var
  SessionId, Cwd: string;
begin
  // Real hook payloads include transcript_path, hook_event_name, source.
  // Only session_id and cwd should be picked up.
  Assert.IsTrue(ParseSessionStartPayload(
    '{"session_id":"x","cwd":"y","transcript_path":"z","hook_event_name":"SessionStart","source":"startup"}',
    SessionId, Cwd));
  Assert.AreEqual('x', SessionId);
  Assert.AreEqual('y', Cwd);
end;

procedure THookEntryTests.ParseStart_InvalidJson_ReturnsFalse;
var
  SessionId, Cwd: string;
begin
  Assert.IsFalse(ParseSessionStartPayload('{ not json', SessionId, Cwd));
  Assert.AreEqual('', SessionId);
  Assert.AreEqual('', Cwd);
end;

procedure THookEntryTests.ParseStart_NotAnObject_ReturnsFalse;
var
  SessionId, Cwd: string;
begin
  // A JSON array parses but isn't an object; should be rejected.
  Assert.IsFalse(ParseSessionStartPayload('["a","b"]', SessionId, Cwd));
  Assert.AreEqual('', SessionId);
  Assert.AreEqual('', Cwd);
end;

procedure THookEntryTests.ParseStart_EmptyString_ReturnsFalse;
var
  SessionId, Cwd: string;
begin
  Assert.IsFalse(ParseSessionStartPayload('', SessionId, Cwd));
  Assert.AreEqual('', SessionId);
  Assert.AreEqual('', Cwd);
end;

procedure THookEntryTests.ParseStart_HandlesEscapedBackslashes;
var
  SessionId, Cwd: string;
begin
  // Windows cwd paths arrive escaped per JSON rules.
  Assert.IsTrue(ParseSessionStartPayload(
    '{"session_id":"s","cwd":"C:\\Program Files (x86)\\Embarcadero"}',
    SessionId, Cwd));
  Assert.AreEqual('C:\Program Files (x86)\Embarcadero', Cwd);
end;

procedure THookEntryTests.ParseEnd_ValidJson_ExtractsBoth;
var
  SessionId, Reason: string;
begin
  Assert.IsTrue(ParseSessionEndPayload(
    '{"session_id":"sess","reason":"clear"}', SessionId, Reason));
  Assert.AreEqual('sess', SessionId);
  Assert.AreEqual('clear', Reason);
end;

procedure THookEntryTests.ParseEnd_OnlySessionId;
var
  SessionId, Reason: string;
begin
  Assert.IsTrue(ParseSessionEndPayload(
    '{"session_id":"sess"}', SessionId, Reason));
  Assert.AreEqual('sess', SessionId);
  Assert.AreEqual('', Reason);
end;

procedure THookEntryTests.ParseEnd_InvalidJson_ReturnsFalse;
var
  SessionId, Reason: string;
begin
  Assert.IsFalse(ParseSessionEndPayload('not json', SessionId, Reason));
  Assert.AreEqual('', SessionId);
  Assert.AreEqual('', Reason);
end;

procedure THookEntryTests.ParseEnd_AllReasonValues;
var
  SessionId, Reason: string;
  R: string;
begin
  // Documented reasons per the SessionEnd hook contract: clear, resume,
  // logout, prompt_input_exit, bypass_permissions_disabled, other.
  for R in TArray<string>.Create(
    'clear', 'resume', 'logout', 'prompt_input_exit',
    'bypass_permissions_disabled', 'other') do
  begin
    Assert.IsTrue(ParseSessionEndPayload(
      Format('{"session_id":"s","reason":"%s"}', [R]), SessionId, Reason));
    Assert.AreEqual(R, Reason);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(THookEntryTests);

end.
