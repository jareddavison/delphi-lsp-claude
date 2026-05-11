# Regression: end-to-end "hot path" — LSP first, then /delphi-status shows
# the live shim with [MINE], then /delphi-reload signals it.
#
# This is the most behaviorally interesting test:
#   1. The first LSP call lazily spawns the shim.
#   2. The shim registers itself with the current Claude session id.
#   3. /delphi-status's per-session disambiguation should then identify
#      the running shim as ours and mark it [MINE].
#   4. /delphi-reload should find that shim and signal it.
#
# If step 3 fails (shim runs but [MINE] never appears), the session-id
# resolution path or the claude-session.txt write is broken — exactly the
# failure mode that misled the original Haiku transcript into thinking
# "no shim is running" and falling back to the compiler.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'hot-path'

$prompt = @'
Execute this sequence verbatim, one tool call per step:

Step 1: LSP(operation: documentSymbol, file: TestLSPUse.dpr)
Step 2: Skill(skill="delphi-lsp:delphi-status")
Step 3: Skill(skill="delphi-lsp:delphi-reload")

For each step, echo back what you received between the markers:
  STEP1_BEGIN ... STEP1_END
  STEP2_BEGIN ... STEP2_END
  STEP3_BEGIN ... STEP3_END

Hard constraints:
  - Do not call any tool other than LSP and Skill.
  - Do not call Bash.
  - Do not write code or edit files.
  - Do not invoke the compiler.
  - Stop after step 3.
'@

$run = Invoke-HaikuClaude -Workspace $ws.Workspace -Prompt $prompt `
                          -ShimLog $ws.ShimLog -StreamLog $ws.StreamLog -StderrLog $ws.StderrLog
$parsed = Read-StreamLog -StreamLog $ws.StreamLog

$failures = New-Object System.Collections.Generic.List[string]

Test-Assert -Failures $failures -Condition (-not $run.TimedOut) -Message 'claude.exe timed out'
Test-Assert -Failures $failures -Condition ($run.ExitCode -eq 0) -Message "claude.exe exit code $($run.ExitCode)"

$lspCalls   = @($parsed.ToolUses | Where-Object Name -eq 'LSP')
$skillCalls = @($parsed.ToolUses | Where-Object Name -eq 'Skill')
$bashCalls  = @($parsed.ToolUses | Where-Object Name -eq 'Bash')

Test-Assert -Failures $failures -Condition ($lspCalls.Count -ge 1) `
    -Message "expected at least 1 LSP call, got $($lspCalls.Count)"
Test-Assert -Failures $failures -Condition ($skillCalls.Count -ge 2) `
    -Message "expected at least 2 Skill calls (status + reload), got $($skillCalls.Count)"
Test-Assert -Failures $failures -Condition ($bashCalls.Count -eq 0) `
    -Message "expected 0 Bash calls (no compiler fallback), got $($bashCalls.Count)"

foreach ($call in $lspCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "LSP call errored: $($call.Result)"
    Test-Assert -Failures $failures -Condition ($call.Result -notmatch 'Server not initialized|No LSP server available') `
        -Message "LSP returned stale-server error: $($call.Result)"
}
foreach ($call in $skillCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Skill call errored: $($call.Result)"
}

$echoed = $parsed.AssistantText

# /delphi-status output should mark the shim as [MINE] in this same session.
Test-Assert -Failures $failures -Condition ($echoed -match '\[MINE\]') `
    -Message "/delphi-status output did not contain [MINE] — per-session disambiguation broken (shim spawned but not identified as ours)"
Test-Assert -Failures $failures -Condition ($echoed -match '(?i)alive') `
    -Message "/delphi-status output did not show an [alive] shim"

# /delphi-reload should signal the live shim.
Test-Assert -Failures $failures -Condition ($echoed -match '(?i)Signaled \d+ shim\(s\)') `
    -Message "/delphi-reload did not report signaling at least one shim"

# Shim log should show the full handshake.
$shimText = if (Test-Path $ws.ShimLog) { Get-Content $ws.ShimLog -Raw } else { '' }
Test-Assert -Failures $failures -Condition ($shimText -match 'initialize\.processId=') `
    -Message 'shim log does not show initialize handshake'
Test-Assert -Failures $failures -Condition ($shimText -match 'didOpen tracked') `
    -Message 'shim log does not show didOpen for the test file'

$passed = Write-TestResult -Name 'hot-path' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
