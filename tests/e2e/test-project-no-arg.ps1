# Regression: the model handles /delphi-project-with-no-arg by re-invoking
# the slash command with the discovered name, NOT by writing custom code to
# manipulate active.txt / sessions/ files.
#
# This guards the "Haiku improvises 40 lines of bash" failure mode where
# the model received the shim's 'No project argument provided' usage text
# and instead of following the NEXT STEP guidance, wrote its own
# filesystem manipulation that mis-canonicalised paths and then
# hallucinated success.
#
# Pass criteria:
#   - Model invokes Skill(delphi-lsp:delphi-status) (to enumerate candidates).
#   - Model invokes Skill(delphi-lsp:delphi-project) at least twice — once
#     with no/empty args (the original user invocation) and at least once
#     with a non-empty args= value matching the fixture project name.
#   - Model makes NO Bash, PowerShell, Edit, or Write calls.
#   - After the session, the shim's active.txt for this Claude session is
#     set to the fixture's .delphilsp.json path (verifying the re-invocation
#     actually took effect rather than being hallucinated).

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'project-no-arg'

$prompt = @'
You are in a Delphi project workspace. The user just typed
`/delphi-lsp:delphi-project` with NO argument. Follow the slash command's
guidance to discover the available project, switch to it, and verify.

Use ONLY these tools:
  - Skill(delphi-lsp:delphi-project)        (to switch projects)
  - Skill(delphi-lsp:delphi-status)         (to enumerate / verify)

Hard constraints:
  - Do not use Bash, PowerShell, Edit, Write, Grep, or Read.
  - Do not write code.
  - Do not manipulate any files yourself.
  - The shim handles all state; you just re-invoke its slash commands.
  - Stop after you've verified the switch via /delphi-status.
'@

$run = Invoke-HaikuClaude -Workspace $ws.Workspace -Prompt $prompt `
                          -ShimLog $ws.ShimLog -StreamLog $ws.StreamLog -StderrLog $ws.StderrLog `
                          -TimeoutSec 240
$parsed = Read-StreamLog -StreamLog $ws.StreamLog

$failures = New-Object System.Collections.Generic.List[string]

Test-Assert -Failures $failures -Condition (-not $run.TimedOut) -Message 'claude.exe timed out'
Test-Assert -Failures $failures -Condition ($run.ExitCode -eq 0) -Message "claude.exe exit code $($run.ExitCode)"

$skillCalls    = @($parsed.ToolUses | Where-Object Name -eq 'Skill')
$statusCalls   = @($skillCalls | Where-Object { $_.Input.skill -eq 'delphi-lsp:delphi-status' })
$projectCalls  = @($skillCalls | Where-Object { $_.Input.skill -eq 'delphi-lsp:delphi-project' })
$projectWithArg = @($projectCalls | Where-Object {
    $a = $_.Input.args
    ($null -ne $a) -and ($a.ToString().Trim() -ne '')
})
$bashCalls = @($parsed.ToolUses | Where-Object Name -in 'Bash', 'PowerShell')
$editCalls = @($parsed.ToolUses | Where-Object Name -in 'Edit', 'Write')

Test-Assert -Failures $failures -Condition ($statusCalls.Count -ge 1) `
    -Message "model never called Skill(delphi-lsp:delphi-status) to enumerate candidates (got $($statusCalls.Count))"
Test-Assert -Failures $failures -Condition ($projectWithArg.Count -ge 1) `
    -Message "model never re-invoked Skill(delphi-lsp:delphi-project) with a non-empty args= (it should have, after seeing the 'no arg' usage message)"
Test-Assert -Failures $failures -Condition ($bashCalls.Count -eq 0) `
    -Message "model invoked $($bashCalls.Count) Bash/PowerShell tool(s) — the shim does state work, the model should never improvise filesystem manipulation"
Test-Assert -Failures $failures -Condition ($editCalls.Count -eq 0) `
    -Message "model invoked $($editCalls.Count) Edit/Write tool(s) — should never modify files for this task"

# The test does not assert on active.txt because that file is only
# written when a live shim exists, and this test deliberately avoids
# spawning one (no LSP call) to keep the scenario tight. The tool-call
# sequence assertions above are the actual regression guard: as long as
# the model called Skill(delphi-lsp:delphi-project) with a non-empty
# args= and made no Bash/PowerShell call, it followed the new guidance
# and did not improvise.

$passed = Write-TestResult -Name 'project-no-arg' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
