// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// Background thread that watches a directory non-recursively and fires
// a caller-supplied callback whenever any LAST_WRITE or FILE_NAME change
// is reported by the OS. Used by the shim to react to slash-command
// drop files (`active.txt`, `reload.flag`, `shim-reload.flag`) under the
// per-session sentinel directory.
//
// Design choice: the callback is opaque to this unit. The shim's
// dpr installs a closure that calls into ReadAndApplySentinel /
// ReadAndApplyReloadFlag / ReadAndApplyShimReloadFlag — these touch
// dpr-owned globals (GSession, GActiveProject, GSessionDir) so they
// can't move into a unit, but the watching skeleton can.

unit DelphiLsp.SentinelWatcher;

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs;

type
  TSentinelWatcherThread = class(TThread)
  private
    FDir: string;
    FOnChanged: TProc;
    FShutdownEvent: TEvent;
  protected
    procedure Execute; override;
  public
    // ADir — directory to watch (non-recursive). Empty string makes
    //   Execute exit immediately without starting any watch.
    // AOnChanged — called on each notification. Wrapped in try/except
    //   inside Execute so a misbehaving callback never crashes the
    //   thread; exceptions are logged via Diag.
    constructor Create(const ADir: string; const AOnChanged: TProc);
    destructor Destroy; override;

    // Signal a clean shutdown. Execute returns from its
    // WaitForMultipleObjects on the next OS dispatch and exits the
    // loop. Caller still needs WaitFor before Free.
    procedure SignalShutdown;
  end;

implementation

uses
  Winapi.Windows,
  DelphiLsp.Logging;

constructor TSentinelWatcherThread.Create(const ADir: string;
  const AOnChanged: TProc);
begin
  FDir := ADir;
  FOnChanged := AOnChanged;
  FShutdownEvent := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TSentinelWatcherThread.Destroy;
begin
  FShutdownEvent.Free;
  inherited;
end;

procedure TSentinelWatcherThread.SignalShutdown;
begin
  FShutdownEvent.SetEvent;
end;

procedure TSentinelWatcherThread.Execute;
var
  ChangeHandle: THandle;
  Handles: array[0..1] of THandle;
  WaitResult: DWORD;
begin
  if FDir = '' then Exit;
  ChangeHandle := FindFirstChangeNotification(PChar(FDir), False,
    FILE_NOTIFY_CHANGE_LAST_WRITE or FILE_NOTIFY_CHANGE_FILE_NAME);
  if ChangeHandle = INVALID_HANDLE_VALUE then
  begin
    Diag('Sentinel watcher: FindFirstChangeNotification failed for ' + FDir);
    Exit;
  end;
  try
    Handles[0] := ChangeHandle;
    Handles[1] := FShutdownEvent.Handle;
    while not Terminated do
    begin
      WaitResult := WaitForMultipleObjects(2, @Handles[0], False, INFINITE);
      if WaitResult = WAIT_OBJECT_0 then
      begin
        if Assigned(FOnChanged) then
        begin
          try
            FOnChanged();
          except
            on E: Exception do
              Diag('Sentinel callback error: ' + E.Message);
          end;
        end;
        FindNextChangeNotification(ChangeHandle);
      end
      else if WaitResult = WAIT_OBJECT_0 + 1 then
        Break;
    end;
  finally
    FindCloseChangeNotification(ChangeHandle);
  end;
  Diag('Sentinel watcher exiting');
end;

end.
