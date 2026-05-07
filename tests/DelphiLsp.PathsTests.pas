unit DelphiLsp.PathsTests;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TPathsTests = class
  public
    // PathToFileUri / FileUriToPath
    [Test] procedure PathToFileUri_BasicWindows;
    [Test] procedure PathToFileUri_PercentEncodesSpaces;
    [Test] procedure PathToFileUri_PercentEncodesParens;
    [Test] procedure FileUriToPath_BasicWindows;
    [Test] procedure FileUriToPath_DecodesPercentEscapes;
    [Test] procedure FileUriToPath_RejectsWrongPrefix;
    [Test] procedure RoundTrip_Path_Uri_Path;

    // NormalizeCwd
    [Test] procedure NormalizeCwd_LowercasesAndStripsTrailingSlash;
    [Test] procedure NormalizeCwd_StripsTrailingBackslash;
    [Test] procedure NormalizeCwd_NoChangeWhenAlreadyCanonical;

    // CanonicalizeCwd (cross-platform form)
    [Test] procedure CanonicalizeCwd_WindowsForm;
    [Test] procedure CanonicalizeCwd_MinGWForm;
    [Test] procedure CanonicalizeCwd_BothFormsMatch;
    [Test] procedure CanonicalizeCwd_TrailingSlashIgnored;
  end;

implementation

uses
  DelphiLsp.Paths;

{ PathToFileUri / FileUriToPath }

procedure TPathsTests.PathToFileUri_BasicWindows;
begin
  Assert.AreEqual('file:///D:/Documents/TestDproj/Unit1.pas',
    PathToFileUri('D:\Documents\TestDproj\Unit1.pas'));
end;

procedure TPathsTests.PathToFileUri_PercentEncodesSpaces;
begin
  Assert.AreEqual('file:///C:/Foo%20Bar/Unit.pas',
    PathToFileUri('C:\Foo Bar\Unit.pas'));
end;

procedure TPathsTests.PathToFileUri_PercentEncodesParens;
begin
  Assert.AreEqual(
    'file:///C:/Program%20Files%20%28x86%29/Embarcadero/file.pas',
    PathToFileUri('C:\Program Files (x86)\Embarcadero\file.pas'));
end;

procedure TPathsTests.FileUriToPath_BasicWindows;
begin
  Assert.AreEqual('D:\Documents\TestDproj\Unit1.pas',
    FileUriToPath('file:///D:/Documents/TestDproj/Unit1.pas'));
end;

procedure TPathsTests.FileUriToPath_DecodesPercentEscapes;
begin
  Assert.AreEqual('C:\Program Files (x86)\Embarcadero\file.pas',
    FileUriToPath(
      'file:///C:/Program%20Files%20%28x86%29/Embarcadero/file.pas'));
end;

procedure TPathsTests.FileUriToPath_RejectsWrongPrefix;
begin
  Assert.AreEqual('', FileUriToPath('http://example.com/foo'));
  Assert.AreEqual('', FileUriToPath('not a uri'));
  Assert.AreEqual('', FileUriToPath(''));
end;

procedure TPathsTests.RoundTrip_Path_Uri_Path;
const
  Original = 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin\DelphiLSP.exe';
begin
  Assert.AreEqual(Original, FileUriToPath(PathToFileUri(Original)));
end;

{ NormalizeCwd }

procedure TPathsTests.NormalizeCwd_LowercasesAndStripsTrailingSlash;
begin
  Assert.AreEqual('d:\documents\testdproj',
    NormalizeCwd('D:\Documents\TestDproj\'));
end;

procedure TPathsTests.NormalizeCwd_StripsTrailingBackslash;
begin
  Assert.AreEqual('d:\documents\testdproj',
    NormalizeCwd('D:\Documents\TestDproj\'));
end;

procedure TPathsTests.NormalizeCwd_NoChangeWhenAlreadyCanonical;
begin
  Assert.AreEqual('d:\documents\testdproj',
    NormalizeCwd('d:\documents\testdproj'));
end;

{ CanonicalizeCwd }

procedure TPathsTests.CanonicalizeCwd_WindowsForm;
begin
  Assert.AreEqual('d/documents/testdproj',
    CanonicalizeCwd('D:\Documents\TestDproj'));
end;

procedure TPathsTests.CanonicalizeCwd_MinGWForm;
begin
  Assert.AreEqual('d/documents/testdproj',
    CanonicalizeCwd('/d/Documents/TestDproj'));
end;

procedure TPathsTests.CanonicalizeCwd_BothFormsMatch;
var
  WinForm, MingwForm: string;
begin
  WinForm := CanonicalizeCwd('D:\Documents\TestDproj');
  MingwForm := CanonicalizeCwd('/d/Documents/TestDproj');
  Assert.AreEqual(WinForm, MingwForm,
    'Windows and MinGW path forms must canonicalize to the same string');
end;

procedure TPathsTests.CanonicalizeCwd_TrailingSlashIgnored;
begin
  Assert.AreEqual('d/documents/testdproj',
    CanonicalizeCwd('D:\Documents\TestDproj\'));
  Assert.AreEqual('d/documents/testdproj',
    CanonicalizeCwd('/d/Documents/TestDproj/'));
end;

initialization
  TDUnitX.RegisterTestFixture(TPathsTests);

end.
