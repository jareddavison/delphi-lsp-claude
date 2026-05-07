program DelphiLspTests;

{$APPTYPE CONSOLE}
{$STRONGLINKTYPES ON}

// Copyright (c) 2026 Jared Davison. Released under the MIT License (see LICENSE).
//
// AI-generated (Claude Code). Review before trusting in production.
//
// DUnitX runner for the extracted DelphiLsp.* units. Build via
// tests/build-and-run.bat.

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  DelphiLsp.XmlDecode in '..\src\units\DelphiLsp.XmlDecode.pas',
  DelphiLsp.Paths in '..\src\units\DelphiLsp.Paths.pas',
  DelphiLsp.Walkers in '..\src\units\DelphiLsp.Walkers.pas',
  DelphiLsp.Logging in '..\src\units\DelphiLsp.Logging.pas',
  DelphiLsp.LspMessage in '..\src\units\DelphiLsp.LspMessage.pas',
  DelphiLsp.XmlDecodeTests in 'DelphiLsp.XmlDecodeTests.pas',
  DelphiLsp.PathsTests in 'DelphiLsp.PathsTests.pas',
  DelphiLsp.WalkersTests in 'DelphiLsp.WalkersTests.pas',
  DelphiLsp.LspMessageTests in 'DelphiLsp.LspMessageTests.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;
begin
  try
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Runner.FailsOnNoAsserts := False;
    if TDUnitX.Options.ConsoleMode <> TDunitXConsoleMode.Off then
    begin
      Logger := TDUnitXConsoleLogger.Create(
        TDUnitX.Options.ConsoleMode = TDunitXConsoleMode.Quiet);
      Runner.AddLogger(Logger);
    end;
    NUnitLogger := TDUnitXXMLNUnitFileLogger.Create(TDUnitX.Options.XMLOutputFile);
    Runner.AddLogger(NUnitLogger);
    Results := Runner.Execute;
    if not Results.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do
    begin
      System.Writeln(E.ClassName, ': ', E.Message);
      System.ExitCode := 1;
    end;
  end;
end.
