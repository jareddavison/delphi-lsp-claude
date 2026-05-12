# Regression: a hard syntactic error should always reach the model.
#
# Companion to test-diagnostics-cold.ps1 (semantic, edit-then-LSP) and
# test-diagnostics-warm.ps1 (semantic, LSP-then-edit). This one uses the
# warm flow but injects a parser-level (not semantic) error: an extra
# closing parenthesis. Even DelphiLSP in syntactic-only mode — before the
# project finishes loading — should catch this and emit a non-empty
# diagnostics array.
#
# Result interpretation:
#   - Warm/cold fail with empty array, syntactic ALSO fails with empty:
#     DelphiLSP is publishing diagnostics but never with content for this
#     fixture. Something deeper is wrong — possibly the compiler DLL
#     (dcc32370.dll, per .delphilsp.json) can't be resolved, or the agent
#     workers aren't starting, or the .delphilsp.json projectFiles=[] is
#     leaving the file out of scope.
#   - Warm/cold fail with empty array, syntactic PASSES with non-empty:
#     Syntactic-only mode is reachable, semantic mode is not. The
#     project isn't fully loading. Fix is on the shim or project-config
#     side: wait for a load-complete signal, or repopulate projectFiles.
#   - Syntactic passes AND model surfaces the error: full pipeline works
#     for this error class — useful baseline.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'diagnostics-syntactic'

# Extra closing paren — parses as an attempt to begin a statement with `)`,
# which no Pascal parser accepts. Caught at the syntactic level, no
# semantic resolution required.
$badLine = '    Writeln(Sqr(2)));'

$prompt = @"
Execute this sequence verbatim, one tool call per step. Stop after step 5.

Step 1: Call LSP(operation: documentSymbol, file: TestLSPUse.dpr).
Spawns the shim, auto-picks the workspace's single .delphilsp.json,
sends didOpen for the clean source.

Step 2: Call LSP(operation: hover, symbol: Writeln, in: TestLSPUse.dpr).
Adds latency so any background project-load on the server side has more
wall-clock time.

Step 3: Use the Edit tool on TestLSPUse.dpr. Replace the line:
    { TODO -oUser -cConsole Main : Insert code here }
with this exact line (keep the leading 4 spaces of indent):
$badLine
This introduces a clear syntactic error — an extra closing parenthesis.
DelphiLSP should reject this at parse time and publish a diagnostic.

Step 4: Call LSP(operation: documentSymbol, file: TestLSPUse.dpr).
Forces a round-trip; the publishDiagnostics for the bad parse should
have arrived by the time this returns.

Step 5: In your reply text, between REPORT_BEGIN and REPORT_END,
describe any LSP diagnostics, compiler errors, or parse errors you see
in your context window concerning the extra parenthesis. If you see
absolutely nothing, write the exact token NO_DIAGNOSTICS_SEEN inside
the markers.

Hard constraints:
  - Use only the Edit and LSP tools. No Bash, no Write, no msbuild.
  - Do not run the compiler.
  - Do not paraphrase step 3 — the new line must read exactly: $badLine
"@

$run = Invoke-HaikuClaude -Workspace $ws.Workspace -Prompt $prompt `
                          -ShimLog $ws.ShimLog -StreamLog $ws.StreamLog -StderrLog $ws.StderrLog
$parsed = Read-StreamLog -StreamLog $ws.StreamLog

$failures = New-Object System.Collections.Generic.List[string]

Test-Assert -Failures $failures -Condition (-not $run.TimedOut) -Message 'claude.exe timed out'
Test-Assert -Failures $failures -Condition ($run.ExitCode -eq 0) -Message "claude.exe exit code $($run.ExitCode)"

$editCalls = @($parsed.ToolUses | Where-Object Name -eq 'Edit')
$lspCalls  = @($parsed.ToolUses | Where-Object Name -eq 'LSP')
$bashCalls = @($parsed.ToolUses | Where-Object Name -eq 'Bash')

Test-Assert -Failures $failures -Condition ($editCalls.Count -ge 1) `
    -Message "expected at least 1 Edit call, got $($editCalls.Count)"
Test-Assert -Failures $failures -Condition ($lspCalls.Count -ge 2) `
    -Message "expected at least 2 LSP calls, got $($lspCalls.Count)"
Test-Assert -Failures $failures -Condition ($bashCalls.Count -eq 0) `
    -Message "expected 0 Bash calls, got $($bashCalls.Count)"

foreach ($call in $editCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Edit call errored: $($call.Result)"
}
foreach ($call in $lspCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "LSP call errored: $($call.Result)"
}

$shimText = if (Test-Path $ws.ShimLog) { Get-Content $ws.ShimLog -Raw } else { '' }

Test-Assert -Failures $failures `
    -Condition ($shimText -match 'method=textDocument/publishDiagnostics') `
    -Message 'shim log shows no publishDiagnostics notification at all'

Test-Assert -Failures $failures `
    -Condition ($shimText -match '"diagnostics":\s*\[\s*\{') `
    -Message ('shim log shows publishDiagnostics but every emission carried an empty array, even for a hard syntactic error (extra closing paren). ' +
              'This rules out the project-load-timing theory: DelphiLSP cannot be doing only syntactic-mode diagnostics — it would still flag this. ' +
              'Likely deeper: compiler DLL (dcc32370.dll) not resolving, agent workers not starting, or projectFiles=[] excluding the file from analysis. ' +
              'Try running DelphiLSP.exe on this fixture directly to compare baseline behaviour.')

# Model surfacing.
$report = ''
$reportMatch = [regex]::Match($parsed.AssistantText, 'REPORT_BEGIN(.*?)REPORT_END', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if ($reportMatch.Success) { $report = $reportMatch.Groups[1].Value }

Test-Assert -Failures $failures -Condition ($report -ne '') `
    -Message 'model reply did not contain a REPORT_BEGIN/REPORT_END block'

$mentionsError = $report -match '(?i)parenthesis|paren|syntax|parse|unexpected|E1029|E2029|compile error'
$admitsSilence = $report -match 'NO_DIAGNOSTICS_SEEN'

$silenceNote = $admitsSilence `
    ? 'Model explicitly reported NO_DIAGNOSTICS_SEEN — even hard syntactic errors are not reaching the model.' `
    : 'Model neither described the error nor admitted silence — prompt may have failed earlier.'
Test-Assert -Failures $failures -Condition $mentionsError `
    -Message ("model did not surface the syntactic error. Report block: '" + $report.Trim() + "'. " + $silenceNote)

$passed = Write-TestResult -Name 'diagnostics-syntactic' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
