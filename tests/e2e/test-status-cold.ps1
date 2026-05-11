# Regression: /delphi-status renders correctly with no shim running.
#
# Verifies:
#   - Skill(delphi-lsp:delphi-status) is_error is false.
#   - The rendered body contains the shim's actual --status output
#     (workspace path, available .delphilsp.json file, no-live-shim hint).
#   - Model makes NO follow-up Bash call (the slash command's `!` block
#     should produce the data inline; if the model has to Bash the shim
#     manually, the migration to `!`-preprocessing is broken).

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'status-cold'

$prompt = @'
Invoke `Skill(skill="delphi-lsp:delphi-status")` exactly once.

Then, in your response, copy back the EXACT text the skill rendered to you:
every line, every character, verbatim. Do not summarize, do not paraphrase,
do not interpret. Just reproduce the skill's output text in your response.

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
    -Message "expected 0 Bash calls (slash command should render inline), got $($bashCalls.Count)"

foreach ($call in $skillCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Skill call returned is_error=True: $($call.Result)"
}

# The shim's actual output should appear in what Haiku echoed back.
$echoed = $parsed.AssistantText
Test-Assert -Failures $failures -Condition ($echoed -match 'Workspace:') `
    -Message "echoed body missing 'Workspace:' line — shim --status output didn't render"
Test-Assert -Failures $failures -Condition ($echoed -match 'TestLSPUse\.delphilsp\.json') `
    -Message "echoed body did not list the fixture .delphilsp.json file"
Test-Assert -Failures $failures -Condition ($echoed -match '(?i)no live shim|no shim running|none registered') `
    -Message "echoed body missing the cold-state 'no live shim' indication"

$passed = Write-TestResult -Name 'status-cold' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
