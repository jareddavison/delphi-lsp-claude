# Regression: compiler errors must reach the model via LSP push diagnostics.
#
# The DelphiLSP plugin exists in part so the model sees errors as the user
# would in an IDE — squiggles right after an edit, no need to shell out
# to the compiler. The mechanism: model Edit → Claude Code forwards
# didChange to the shim → shim relays to DelphiLSP child → DelphiLSP
# parses → child emits textDocument/publishDiagnostics → shim relays to
# Claude Code's LSP client → Claude Code surfaces the diagnostics so the
# model can see them next turn.
#
# Per ca82cea (v0.7.0), this was made to work by the shim synthesizing
# a didOpen when an untracked URI first sees a didChange — DelphiLSP
# returns empty diagnostics for unopened files. The 8 unit tests added
# in that commit only verify the synthetic-didOpen JSON builder. Nothing
# in tree exercises the full round-trip, which is how a later regression
# could (and apparently did) slip past CI.
#
# This test introduces a deliberate undeclared identifier via Edit, then
# asks the model to summarise any diagnostics it can see. Pass = both
# the shim log shows publishDiagnostics carrying a non-empty diagnostics
# array AND the model's reply mentions the error. Fail with the verbose
# shim log preserved at the workspace temp dir for triage.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'diagnostics-cold'

# The intentional typo. "Sqrr" is not a standard System unit identifier;
# DelphiLSP should emit an undeclared-identifier (E2003-style) diagnostic.
# Picking a token that's recognisably close to a real function ("Sqr")
# helps make the diagnostic content unambiguous in the assertion below.
$badLine = '    Writeln(Sqrr(2));'

$prompt = @"
Execute this sequence verbatim, one tool call per step. Stop after step 3.

Step 1: Use the Edit tool to modify TestLSPUse.dpr. Replace the line:
    { TODO -oUser -cConsole Main : Insert code here }
with this exact line (keep the leading 4 spaces of indent):
$badLine

Step 2: Call LSP(operation: documentSymbol, file: TestLSPUse.dpr) — this
ensures the LSP shim is spawned and the server has parsed the edited file.

Step 3: In your reply text, between the markers REPORT_BEGIN and
REPORT_END, describe any LSP diagnostics, compiler errors, or unresolved
identifier warnings you can see in your context window concerning the
"Sqrr" identifier you just introduced. If you see absolutely nothing
about Sqrr being undeclared or any related compile error, write the
exact token NO_DIAGNOSTICS_SEEN inside the markers.

Hard constraints:
  - Use only the Edit and LSP tools. No Bash, no Write, no msbuild.
  - Do not run the compiler.
  - Do not paraphrase step 1 — the new line must read exactly: $badLine
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
    -Message "expected at least 1 Edit call (to introduce the typo), got $($editCalls.Count)"
Test-Assert -Failures $failures -Condition ($lspCalls.Count -ge 1) `
    -Message "expected at least 1 LSP call (to wake the shim post-edit), got $($lspCalls.Count)"
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

# Shim-side assertion: with DELPHI_LSP_VERBOSE=1 (wired in _lib.ps1), the
# log captures the full publishDiagnostics body. An empty diagnostics array
# `"diagnostics":[]` indicates DelphiLSP saw the file but found no errors —
# which would itself be a bug since the source we edited in is invalid.
$shimText = if (Test-Path $ws.ShimLog) { Get-Content $ws.ShimLog -Raw } else { '' }
Test-Assert -Failures $failures `
    -Condition ($shimText -match 'method=textDocument/publishDiagnostics') `
    -Message 'shim log shows no publishDiagnostics notification — DelphiLSP did not produce any, or the shim dropped them upstream of the writer'

# A populated diagnostics array looks like `"diagnostics":[{...`. An empty
# one looks like `"diagnostics":[]`. The regex below matches only the
# populated case (open brace immediately after the bracket).
Test-Assert -Failures $failures `
    -Condition ($shimText -match '"diagnostics":\s*\[\s*\{') `
    -Message ('shim log shows publishDiagnostics but with an empty diagnostics array — DelphiLSP parsed the source without producing semantic diagnostics. ' +
              'Most likely the project did not finish loading before the didOpen was processed; in that state DelphiLSP runs syntactic-only and undeclared-identifier checks (which are semantic) silently no-op. ' +
              'Fixing this requires the shim to either (a) wait for a project-loaded signal from DelphiLSP before forwarding the first didOpen, or (b) replay didOpen/didChange after the project load completes so a second publishDiagnostics is emitted with full semantic results.')

# Model-side assertion: the whole point of push diagnostics is that the
# model sees them without explicit querying. Extract the REPORT block and
# check whether the model surfaced the error or admitted it didn't.
$report = ''
$reportMatch = [regex]::Match($parsed.AssistantText, 'REPORT_BEGIN(.*?)REPORT_END', [System.Text.RegularExpressions.RegexOptions]::Singleline)
if ($reportMatch.Success) { $report = $reportMatch.Groups[1].Value }

Test-Assert -Failures $failures -Condition ($report -ne '') `
    -Message 'model reply did not contain a REPORT_BEGIN/REPORT_END block'

# Either the model mentions the error (good), or it explicitly admits it
# saw nothing (bad — this is the regression we want to catch).
$mentionsError = $report -match '(?i)Sqrr|undeclared|undefined|E2003|compile error|unresolved'
$admitsSilence = $report -match 'NO_DIAGNOSTICS_SEEN'

$silenceNote = $admitsSilence `
    ? 'Model explicitly reported NO_DIAGNOSTICS_SEEN — push diagnostics are not reaching the model.' `
    : 'Model neither described the error nor admitted silence — prompt may have failed earlier.'
Test-Assert -Failures $failures -Condition $mentionsError `
    -Message ("model did not surface the introduced error. Report block: '" + $report.Trim() + "'. " + $silenceNote)

$passed = Write-TestResult -Name 'diagnostics-cold' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
