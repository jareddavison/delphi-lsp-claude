# Regression: /delphi-project resolves a project name to a .delphilsp.json.
#
# Verifies:
#   - Skill(delphi-lsp:delphi-project, args="TestLSPUse") is_error is false.
#   - The rendered body contains "Resolved: <path>" with the absolute path
#     to the fixture's TestLSPUse.delphilsp.json.
#   - No Bash follow-up.
#
# This guards the name-matching path in DelphiLsp.CliCommands.ResolveDelphilspJsonArg
# AND the $ARGUMENTS substitution inside `!`-preprocessing.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'project-resolve'

$prompt = @'
Invoke `Skill(skill="delphi-lsp:delphi-project", args="TestLSPUse")` exactly once.

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
    -Message "expected 0 Bash calls, got $($bashCalls.Count)"

foreach ($call in $skillCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Skill call returned is_error=True: $($call.Result)"
}

$echoed = $parsed.AssistantText
Test-Assert -Failures $failures -Condition ($echoed -match 'Resolved:') `
    -Message "body missing 'Resolved:' confirmation — name-match path may be broken"
Test-Assert -Failures $failures -Condition ($echoed -match 'TestLSPUse\.delphilsp\.json') `
    -Message "body did not name the resolved .delphilsp.json file"

$passed = Write-TestResult -Name 'project-resolve' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
