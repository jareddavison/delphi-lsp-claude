# Regression: /delphi-runtime accepts a version and 'clear' arg in two
# successive invocations.
#
# Verifies:
#   - Skill(delphi-lsp:delphi-runtime, args="37.0") doesn't error and reports
#     either "Runtime override = 37.0" or "No live shim" with deferred-apply text.
#   - Skill(delphi-lsp:delphi-runtime, args="clear") routes to the clear path.

[CmdletBinding()]
param([switch]$KeepTemp)

. "$PSScriptRoot\_lib.ps1"

$ws = New-TestWorkspace -Tag 'runtime-set-clear'

$prompt = @'
Step 1: Invoke `Skill(skill="delphi-lsp:delphi-runtime", args="37.0")`. Echo verbatim
what the skill rendered to you between STEP1_BEGIN and STEP1_END.

Step 2: Invoke `Skill(skill="delphi-lsp:delphi-runtime", args="clear")`. Echo verbatim
what the skill rendered to you between STEP2_BEGIN and STEP2_END.

Hard constraints:
  - Use ONLY the Skill tool.
  - Do not call Bash, Read, Edit, or any other tool.
  - Run exactly the two Skill calls above and stop.
'@

$run = Invoke-HaikuClaude -Workspace $ws.Workspace -Prompt $prompt `
                          -ShimLog $ws.ShimLog -StreamLog $ws.StreamLog -StderrLog $ws.StderrLog
$parsed = Read-StreamLog -StreamLog $ws.StreamLog

$failures = New-Object System.Collections.Generic.List[string]

Test-Assert -Failures $failures -Condition (-not $run.TimedOut) -Message 'claude.exe timed out'
Test-Assert -Failures $failures -Condition ($run.ExitCode -eq 0) -Message "claude.exe exit code $($run.ExitCode)"

$skillCalls = @($parsed.ToolUses | Where-Object Name -eq 'Skill')
$bashCalls  = @($parsed.ToolUses | Where-Object Name -eq 'Bash')

Test-Assert -Failures $failures -Condition ($skillCalls.Count -eq 2) `
    -Message "expected 2 Skill calls, got $($skillCalls.Count)"
Test-Assert -Failures $failures -Condition ($bashCalls.Count -eq 0) `
    -Message "expected 0 Bash calls, got $($bashCalls.Count)"

foreach ($call in $skillCalls) {
    Test-Assert -Failures $failures -Condition (-not $call.IsError) `
        -Message "Skill call returned is_error=True: $($call.Result)"
}

# Verify the prompt told the model to invoke runtime with arg "37.0" first, then "clear".
# We don't enforce the order against the model strictly — just that both inputs
# appear in the call sequence.
$argsSeen = @($skillCalls | ForEach-Object { ($_.Input.args | Out-String).Trim() })
Test-Assert -Failures $failures -Condition ($argsSeen -contains '37.0') `
    -Message "no Skill call had args='37.0' (saw: $($argsSeen -join ', '))"
Test-Assert -Failures $failures -Condition ($argsSeen -contains 'clear') `
    -Message "no Skill call had args='clear' (saw: $($argsSeen -join ', '))"

# In cold state both paths should render the "no live shim" deferred message.
$echoed = $parsed.AssistantText
Test-Assert -Failures $failures -Condition ($echoed -match '(?i)no live shim|deferred|no runtime override to clear') `
    -Message "neither runtime path rendered an expected cold-state message"

$passed = Write-TestResult -Name 'runtime-set-clear' -Run $run -Parsed $parsed -Ws $ws -Failures $failures -KeepTemp:$KeepTemp
exit ($passed ? 0 : 1)
