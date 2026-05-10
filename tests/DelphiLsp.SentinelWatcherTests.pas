// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.

unit DelphiLsp.SentinelWatcherTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSentinelWatcherTests = class
  private
    FRoot: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure EmptyDir_ExitsImmediately;
    [Test] procedure NonexistentDir_ExitsImmediately;
    [Test] procedure ConstructAndShutdown_DoesNotBlock;
    [Test] procedure ChangeNotification_FiresCallback;
    [Test] procedure NilCallback_DoesNotCrashOnChange;
    [Test] procedure ExceptionInCallback_DoesNotKillThread;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  System.SyncObjs,
  DelphiLsp.SentinelWatcher;

procedure TSentinelWatcherTests.Setup;
begin
  FRoot := TPath.Combine(TPath.GetTempPath, 'sentinelwatcher-' +
    TGUID.NewGuid.ToString.Replace('{', '').Replace('}', ''));
  TDirectory.CreateDirectory(FRoot);
end;

procedure TSentinelWatcherTests.TearDown;
begin
  try
    if TDirectory.Exists(FRoot) then TDirectory.Delete(FRoot, True);
  except
    // Best-effort.
  end;
end;

procedure TSentinelWatcherTests.EmptyDir_ExitsImmediately;
var
  W: TSentinelWatcherThread;
  Started: Cardinal;
begin
  Started := GetTickCount;
  W := TSentinelWatcherThread.Create('', nil);
  try
    W.WaitFor;
  finally
    W.Free;
  end;
  Assert.IsTrue(GetTickCount - Started < 500,
    'empty dir should make Execute exit immediately');
end;

procedure TSentinelWatcherTests.NonexistentDir_ExitsImmediately;
var
  W: TSentinelWatcherThread;
  Started: Cardinal;
begin
  Started := GetTickCount;
  W := TSentinelWatcherThread.Create(
    TPath.Combine(FRoot, 'does-not-exist'), nil);
  try
    W.WaitFor;
  finally
    W.Free;
  end;
  Assert.IsTrue(GetTickCount - Started < 500,
    'FindFirstChangeNotification on missing dir returns INVALID — Execute should exit');
end;

procedure TSentinelWatcherTests.ConstructAndShutdown_DoesNotBlock;
var
  W: TSentinelWatcherThread;
  Started: Cardinal;
begin
  W := TSentinelWatcherThread.Create(FRoot, nil);
  try
    Started := GetTickCount;
    W.SignalShutdown;
    W.WaitFor;
    Assert.IsTrue(GetTickCount - Started < 1000,
      'shutdown event should release WaitForMultipleObjects within 1s');
  finally
    W.Free;
  end;
end;

procedure TSentinelWatcherTests.ChangeNotification_FiresCallback;
var
  W: TSentinelWatcherThread;
  HitCount: Integer;
  Deadline: Cardinal;
begin
  HitCount := 0;
  W := TSentinelWatcherThread.Create(FRoot,
    procedure
    begin
      TInterlocked.Increment(HitCount);
    end);
  try
    // Force a directory change. Sleep briefly first so the watcher's
    // first WaitForMultipleObjects has been entered.
    Sleep(100);
    TFile.WriteAllText(IncludeTrailingPathDelimiter(FRoot) + 'flag.txt',
      'hello');
    // Poll for the callback firing — directory change notifications
    // are asynchronous, so allow up to 3s before failing.
    Deadline := GetTickCount + 3000;
    while (HitCount = 0) and (GetTickCount < Deadline) do
      Sleep(50);
    Assert.IsTrue(HitCount >= 1,
      Format('expected callback to fire; HitCount=%d',
        [HitCount]));
  finally
    W.SignalShutdown;
    W.WaitFor;
    W.Free;
  end;
end;

procedure TSentinelWatcherTests.NilCallback_DoesNotCrashOnChange;
var
  W: TSentinelWatcherThread;
begin
  // The Execute loop guards against an unassigned callback so the
  // dpr can keep its watcher running with a nil hook during
  // teardown sequences if it wants to.
  W := TSentinelWatcherThread.Create(FRoot, nil);
  try
    Sleep(100);
    TFile.WriteAllText(IncludeTrailingPathDelimiter(FRoot) + 'x.txt', 'y');
    Sleep(200);
    // No assertion — pass means we didn't crash.
  finally
    W.SignalShutdown;
    W.WaitFor;
    W.Free;
  end;
  Assert.Pass('survived a change with nil callback');
end;

procedure TSentinelWatcherTests.ExceptionInCallback_DoesNotKillThread;
var
  W: TSentinelWatcherThread;
  HitCount: Integer;
  Deadline: Cardinal;
begin
  // The Execute loop wraps the callback in try/except so one badly-
  // behaved invocation doesn't take the watcher down. After the
  // exception the watcher must keep responding to subsequent changes.
  HitCount := 0;
  W := TSentinelWatcherThread.Create(FRoot,
    procedure
    begin
      TInterlocked.Increment(HitCount);
      raise Exception.Create('intentional test failure');
    end);
  try
    Sleep(100);
    TFile.WriteAllText(IncludeTrailingPathDelimiter(FRoot) + 'one.txt', '1');
    Deadline := GetTickCount + 3000;
    while (HitCount < 1) and (GetTickCount < Deadline) do
      Sleep(50);
    Assert.IsTrue(HitCount >= 1,
      'first change should fire callback');
    // Second change after the exception must still fire — proves the
    // thread didn't die.
    Sleep(100);
    TFile.WriteAllText(IncludeTrailingPathDelimiter(FRoot) + 'two.txt', '2');
    Deadline := GetTickCount + 3000;
    while (HitCount < 2) and (GetTickCount < Deadline) do
      Sleep(50);
    Assert.IsTrue(HitCount >= 2,
      Format('second change should fire after a previous exception; HitCount=%d',
        [HitCount]));
  finally
    W.SignalShutdown;
    W.WaitFor;
    W.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSentinelWatcherTests);

end.
