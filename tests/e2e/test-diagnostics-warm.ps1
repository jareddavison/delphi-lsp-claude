# Regression: push diagnostics must arrive when the LSP is warm and the
# project is loaded. Counterpart to test-diagnostics-cold.ps1.
#
# Differs from the cold test in one structural respect: an LSP query is
# made BEFORE the edit. That spawns the shim, lets it auto-pick the
# workspace's single .delphilsp.json, send the natural didOpen for the
# clean source, and gives DelphiLSP a few seconds (covered by model
# latency between tool calls) to finish loading the project. Only then
# does the Edit happen — which generates a didChange, which the now-fully-
# loaded DelphiLSP can process with full semantic context, so undeclared-
# identifier diagnostics actually get published.
#
# If both cold AND warm fail with empty diagnostic arrays, the regression
# is deeper than project-load timing (something fundamentally wrong with
# the shim ↔ DelphiLSP wiring). If warm passes while cold fails, the
# specific shape of the regression is "shim forwards didOpen before
# project finishes loading" — fixable by waiting for a project-loaded
# signal before forwarding didOpen, or by replaying it after.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'diagnostics-warm'

$badLine = '    Writeln(Sqrr(2));'

$prompt = @"
Execute this sequence verbatim, one tool call per step. Stop after step 5.

Step 1: Call LSP(operation: documentSymbol, file: TestLSPUse.dpr).
This spawns the LSP shim, which auto-picks the workspace's single
.delphilsp.json and sends a natural didOpen for the file with its
current (clean) content. DelphiLSP starts loading the project
asynchronously after this call.

Step 2: Call LSP(operation: hover, symbol: Writeln, in: TestLSPUse.dpr).
This gives the project load a few more milliseconds via model latency
between tool calls. The hover result itself is not asserted.

Step 3: Use the Edit tool on TestLSPUse.dpr. Replace the line:
    { TODO -oUser -cConsole Main : Insert code here }
with this exact line (keep the leading 4 spaces of indent):
$badLine
This generates a didChange notification. With the project loaded,
DelphiLSP should re-parse with full semantic context and publish
diagnostics including the undeclared-identifier error for Sqrr.

Step 4: Call LSP(operation: documentSymbol, file: TestLSPUse.dpr).
Forces a round-trip — DelphiLSP must have processed the didChange
by the time this returns, so any publishDiagnostics should be
captured in the shim log by now.

Step 5: In your reply text, between REPORT_BEGIN and REPORT_END,
describe any LSP diagnostics, compiler errors, or unresolved-identifier
warnings you can see in your context window concerning the "Sqrr"
identifier you introduced. If you see absolutely nothing about Sqrr
being undeclared, write the exact token NO_DIAGNOSTICS_SEEN inside
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
    -Message "expected at least 2 LSP calls (one before edit to warm up, one after to sync), got $($lspCalls.Count)"
Test-Assert -Failures $failures -Condition ($bashCalls.Count -eq 0) `
    -Message "expected 0 Bash calls (no compiler fallback), got $($bashCalls.Count)"

foreach ($call in $editCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Edit call errored: $($call.Result)"
}
foreach ($call in $lspCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "LSP call errored: $($call.Result)"
}

$shimText = if (Test-Path $ws.ShimLog) { Get-Content $ws.ShimLog -Raw } else { '' }

# The warm-start path should produce at least one publishDiagnostics
# notification. With ca82cea's verbose body dump, we can also confirm the
# array is populated.
Test-Assert -Failures $failures `
    -Condition ($shimText -match 'method=textDocument/publishDiagnostics') `
    -Message 'shim log shows no publishDiagnostics notification at all — DelphiLSP did not emit any, or the shim never forwarded one'

# Non-empty array assertion. With the warm start the project should have
# loaded before the edit, so DelphiLSP should be in full semantic mode and
# the diagnostics array should contain at least one entry for Sqrr.
Test-Assert -Failures $failures `
    -Condition ($shimText -match '"diagnostics":\s*\[\s*\{') `
    -Message ('shim log shows publishDiagnostics but every emission carried an empty diagnostics array. ' +
              'With the warm-start path this is more serious than the cold case: even a fully-loaded project + natural didChange-after-didOpen did not produce semantic diagnostics. ' +
              'Either DelphiLSP genuinely has nothing to report for this source (unlikely — Sqrr is undeclared) or the shim is somehow filtering / corrupting the notification body before it reaches the writer.')

# Model surfacing assertion. Same logic as the cold test: if shim received
# the diagnostics but the model never saw them, push surfacing is the gap.
$report = ''
$reportMatch = [regex]::Match($parsed.AssistantText, 'REPORT_BEGIN(.*?)REPORT_END', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if ($reportMatch.Success) { $report = $reportMatch.Groups[1].Value }

Test-Assert -Failures $failures -Condition ($report -ne '') `
    -Message 'model reply did not contain a REPORT_BEGIN/REPORT_END block'

$mentionsError = $report -match '(?i)Sqrr|undeclared|undefined|E2003|compile error|unresolved'
$admitsSilence = $report -match 'NO_DIAGNOSTICS_SEEN'

$silenceNote = $admitsSilence `
    ? 'Model explicitly reported NO_DIAGNOSTICS_SEEN — diagnostics are flowing through the shim but not reaching the model.' `
    : 'Model neither described the error nor admitted silence — prompt may have failed earlier.'
Test-Assert -Failures $failures -Condition $mentionsError `
    -Message ("model did not surface the introduced error. Report block: '" + $report.Trim() + "'. " + $silenceNote)

$passed = Write-TestResult -Name 'diagnostics-warm' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
