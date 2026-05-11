# Regression: /delphi-shim-reload reports "no live shim" when nothing is running.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'shim-reload-cold'

$prompt = @'
Invoke `Skill(skill="delphi-lsp:delphi-shim-reload")` exactly once.

Then, in your response, copy back the EXACT text the skill rendered to you:
every line, every character, verbatim. Do not summarize, do not paraphrase.

Hard constraints:
  - Do not call any other tool.
  - Do not call Bash.
  - Stop after the Skill call.
'@

$run = Invoke-HaikuClaude -Workspace $ws.Workspace -Prompt $prompt `
                          -ShimLog $ws.ShimLog -StreamLog $ws.StreamLog -StderrLog $ws.StderrLog
$parsed = Read-StreamLog -StreamLog $ws.StreamLog

$failures = New-Object System.Collections.Generic.List[string]

Test-Assert -Failures $failures -Condition (-not $run.TimedOut) -Message 'claude.exe timed out'
Test-Assert -Failures $failures -Condition ($run.ExitCode -eq 0) -Message "claude.exe exit code $($run.ExitCode)"

$skillCalls = @($parsed.ToolUses | Where-Object Name -eq 'Skill')
$bashCalls  = @($parsed.ToolUses | Where-Object Name -eq 'Bash')

Test-Assert -Failures $failures -Condition ($skillCalls.Count -eq 1) `
    -Message "expected 1 Skill call, got $($skillCalls.Count)"
Test-Assert -Failures $failures -Condition ($bashCalls.Count -eq 0) `
    -Message "expected 0 Bash calls, got $($bashCalls.Count)"

foreach ($call in $skillCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Skill call returned is_error=True: $($call.Result)"
}

$echoed = $parsed.AssistantText
Test-Assert -Failures $failures -Condition ($echoed -match 'No live shim') `
    -Message "body missing 'No live shim' message"

$passed = Write-TestResult -Name 'shim-reload-cold' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
