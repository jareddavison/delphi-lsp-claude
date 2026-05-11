# Regression: a Haiku-class model can drive the LSP from a cold start.
#
# Verifies:
#   - Plugin loads and registers .pas/.dpr with the LSP system.
#   - First LSP query lazily spawns the shim and DelphiLSP without
#     "Server not initialized" or "No LSP server available".
#   - Model uses ONLY the LSP tool — no compiler fallback (dcc32/dcc64/build.bat).
#   - Shim log shows initialize handshake and didOpen.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'lsp-cold'

$prompt = @'
You are inside a Delphi project workspace. Make exactly ONE LSP tool call now:

  LSP(operation: documentSymbol, file: TestLSPUse.dpr)

Report verbatim:
  1) The raw tool result or error string.
  2) A single final line: "OK" if the call returned symbols, "FAIL: <reason>" otherwise.

Hard constraints:
  - Do not write any code.
  - Do not invoke the compiler (no dcc32, dcc64, build.bat, etc.).
  - Do not retry on failure.
  - Do not call any other tool except LSP.
  - Stop after one LSP call regardless of outcome.
'@

$run = Invoke-HaikuClaude -Workspace $ws.Workspace -Prompt $prompt `
                          -ShimLog $ws.ShimLog -StreamLog $ws.StreamLog -StderrLog $ws.StderrLog
$parsed = Read-StreamLog -StreamLog $ws.StreamLog

$failures = New-Object System.Collections.Generic.List[string]

Test-Assert -Failures $failures -Condition (-not $run.TimedOut) -Message 'claude.exe timed out'
Test-Assert -Failures $failures -Condition ($run.ExitCode -eq 0) -Message "claude.exe exit code $($run.ExitCode)"

$lspCalls = @($parsed.ToolUses | Where-Object Name -eq 'LSP')
$otherCalls = @($parsed.ToolUses | Where-Object Name -ne 'LSP')

Test-Assert -Failures $failures -Condition ($lspCalls.Count -eq 1) `
    -Message "expected exactly 1 LSP call, got $($lspCalls.Count)"
Test-Assert -Failures $failures -Condition ($otherCalls.Count -eq 0) `
    -Message "expected 0 non-LSP tools, got $($otherCalls.Count) ($(($otherCalls | ForEach-Object Name) -join ', '))"

foreach ($call in $lspCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "LSP call returned is_error=True: $($call.Result)"
    Test-Assert -Failures $failures -Condition ($null -ne $call.Result -and $call.Result.Length -ge 20) `
        -Message "LSP result suspiciously short: '$($call.Result)'"
    Test-Assert -Failures $failures -Condition ($call.Result -notmatch 'Server not initialized|No LSP server available') `
        -Message "LSP returned stale-server error: $($call.Result)"
    Test-Assert -Failures $failures -Condition ($call.Result -match 'Document symbols|System\.SysUtils|begin') `
        -Message "LSP result missing expected symbol content"
}

$shimText = if (Test-Path $ws.ShimLog) { Get-Content $ws.ShimLog -Raw } else { '' }
Test-Assert -Failures $failures -Condition ($shimText -match 'initialize\.processId=') `
    -Message 'shim log does not show initialize handshake'
Test-Assert -Failures $failures -Condition ($shimText -match 'didOpen tracked') `
    -Message 'shim log does not show didOpen for the test file'

$passed = Write-TestResult -Name 'lsp-cold' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
