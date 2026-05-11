# Shared helpers for Haiku-driven end-to-end regression tests.
#
# Each individual test script dot-sources this lib, calls New-TestWorkspace
# to copy the fixture to a fresh temp dir with a patched .delphilsp.json,
# calls Invoke-HaikuClaude to run claude.exe -p with a tightly-constrained
# prompt, then calls Read-StreamLog to parse the stream-json transcript.
#
# All tests scrub CLAUDE_* env vars from the child so it starts a fresh
# session (psi.Environment is pre-populated with parent env, so we must
# Remove() instead of just skipping during copy). All tests set
# DELPHI_LSP_SHIM_LOG so the shim's diagnostic log is captured for
# post-mortem.

# Note: deliberately NOT using Set-StrictMode here. Stream-json messages
# from claude.exe omit fields like `is_error` when not relevant, and we
# want missing-property access to return $null rather than throw.

# Project root = parent of tests/e2e/, i.e. tests/'s parent. Compute once
# and stash on a script-scope variable so each test can use it without
# walking the path itself.
$script:RegressionRepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:RegressionFixtureDir = Join-Path $script:RegressionRepoRoot 'tests\fixtures\MinimalDelphiProject'

function Get-RegressionRepoRoot { $script:RegressionRepoRoot }

function New-TestWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tag
    )
    if (-not (Test-Path $script:RegressionFixtureDir)) {
        throw "Fixture missing: $script:RegressionFixtureDir"
    }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ([Guid]::NewGuid().ToString().Substring(0,8))
    $workRoot = Join-Path $env:TEMP "delphi-lsp-regression-$Tag-$stamp"
    $workspace = Join-Path $workRoot 'project'
    New-Item -ItemType Directory -Path $workspace -Force | Out-Null

    Copy-Item -Path (Join-Path $script:RegressionFixtureDir '*') `
              -Destination $workspace -Recurse -Force `
              -Exclude 'README.md'

    # Substitute the .delphilsp.json's project URL placeholder with the
    # actual temp-dir .dpr path in RAD-Studio's URL format (forward
    # slashes, %3A for the drive colon).
    $dprPath = Join-Path $workspace 'TestLSPUse.dpr'
    $dprUrl  = 'file:///' + (($dprPath -replace '\\', '/') -replace ':', '%3A')
    $jsonPath = Join-Path $workspace 'TestLSPUse.delphilsp.json'
    $json = Get-Content $jsonPath -Raw
    $patched = $json.Replace('__PROJECT_DPR_URL__', $dprUrl)
    if ($patched -eq $json) {
        throw 'Failed to substitute __PROJECT_DPR_URL__ in delphilsp.json'
    }
    Set-Content -Path $jsonPath -Value $patched -NoNewline

    [PSCustomObject]@{
        Tag       = $Tag
        WorkRoot  = $workRoot
        Workspace = $workspace
        ShimLog   = Join-Path $workRoot 'shim.log'
        StreamLog = Join-Path $workRoot 'stream.jsonl'
        StderrLog = Join-Path $workRoot 'stderr.txt'
    }
}

function Invoke-HaikuClaude {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Workspace,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)]$ShimLog,
        [Parameter(Mandatory)]$StreamLog,
        [Parameter(Mandatory)]$StderrLog,
        [string]$Model = 'claude-haiku-4-5-20251001',
        [int]$TimeoutSec = 240
    )
    $claudeExe = (Get-Command claude.exe -ErrorAction SilentlyContinue).Source
    if (-not $claudeExe) { throw 'claude.exe not on PATH' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName         = $claudeExe
    $psi.WorkingDirectory = $Workspace
    $psi.UseShellExecute  = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.ArgumentList.Add('--plugin-dir');      $psi.ArgumentList.Add($script:RegressionRepoRoot)
    $psi.ArgumentList.Add('-p');                $psi.ArgumentList.Add($Prompt)
    $psi.ArgumentList.Add('--model');           $psi.ArgumentList.Add($Model)
    $psi.ArgumentList.Add('--permission-mode'); $psi.ArgumentList.Add('bypassPermissions')
    $psi.ArgumentList.Add('--output-format');   $psi.ArgumentList.Add('stream-json')
    $psi.ArgumentList.Add('--verbose')

    $keysToRemove = @($psi.Environment.Keys) | Where-Object { $_ -like 'CLAUDE_*' -or $_ -like 'CLAUDECODE*' }
    foreach ($k in $keysToRemove) { [void]$psi.Environment.Remove($k) }
    $psi.Environment['DELPHI_LSP_SHIM_LOG'] = $ShimLog

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p  = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $timedOut = $false
    if (-not $p.WaitForExit($TimeoutSec * 1000)) {
        $timedOut = $true
        try { $p.Kill($true) } catch { }
    }
    $sw.Stop()
    $outTask.Wait(); $errTask.Wait()
    Set-Content -Path $StreamLog -Value $outTask.Result -Encoding UTF8
    Set-Content -Path $StderrLog -Value $errTask.Result -Encoding UTF8

    [PSCustomObject]@{
        TimedOut   = $timedOut
        ExitCode   = $p.ExitCode
        ElapsedSec = [int]$sw.Elapsed.TotalSeconds
    }
}

function Read-StreamLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StreamLog
    )
    $toolUses = New-Object System.Collections.Generic.List[object]
    $toolResults = @{}
    $assistantText = New-Object System.Text.StringBuilder

    Get-Content $StreamLog | ForEach-Object {
        try { $obj = $_ | ConvertFrom-Json -Depth 32 } catch { return }
        if ($obj.type -eq 'assistant' -and $obj.message.content) {
            foreach ($c in $obj.message.content) {
                if ($c.type -eq 'tool_use') {
                    $toolUses.Add([PSCustomObject]@{
                        Id   = $c.id
                        Name = $c.name
                        Input = $c.input
                        Result = $null
                        IsError = $null
                    })
                } elseif ($c.type -eq 'text' -and $c.text) {
                    [void]$assistantText.AppendLine($c.text)
                }
            }
        } elseif ($obj.type -eq 'user' -and $obj.message.content) {
            foreach ($c in $obj.message.content) {
                if ($c.type -eq 'tool_result') {
                    $text = ''
                    if ($c.content -is [string]) {
                        $text = $c.content
                    } elseif ($c.content -is [array]) {
                        $text = ($c.content | ForEach-Object { $_.text }) -join "`n"
                    }
                    $toolResults[$c.tool_use_id] = [PSCustomObject]@{
                        Text = $text
                        IsError = [bool]$c.is_error
                    }
                }
            }
        }
    }

    # Glue tool results onto their corresponding tool_use rows.
    foreach ($u in $toolUses) {
        if ($toolResults.ContainsKey($u.Id)) {
            $u.Result  = $toolResults[$u.Id].Text
            $u.IsError = $toolResults[$u.Id].IsError
        }
    }

    [PSCustomObject]@{
        ToolUses      = $toolUses
        AssistantText = $assistantText.ToString()
    }
}

function Test-Assert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IList]$Failures,
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        [void]$Failures.Add($Message)
    }
}

function Write-TestResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Run,
        [Parameter(Mandatory)]$Parsed,
        [Parameter(Mandatory)]$Ws,
        [Parameter(Mandatory)][System.Collections.IList]$Failures,
        [switch]$KeepTemp
    )
    $totalCalls = $Parsed.ToolUses.Count
    $byName = $Parsed.ToolUses | Group-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" }
    Write-Host ""
    Write-Host ("[{0}] exit={1} elapsed={2}s tools={3} ({4})" -f $Name, $Run.ExitCode, $Run.ElapsedSec, $totalCalls, ($byName -join ' '))
    if ($Failures.Count -eq 0) {
        Write-Host "  PASS" -ForegroundColor Green
        if (-not $KeepTemp) {
            Start-Sleep -Milliseconds 500
            Remove-Item -Recurse -Force $Ws.WorkRoot -ErrorAction SilentlyContinue
        }
        return $true
    } else {
        Write-Host "  FAIL" -ForegroundColor Red
        foreach ($f in $Failures) { Write-Host "    - $f" -ForegroundColor Red }
        Write-Host "  Diagnostics preserved at: $($Ws.WorkRoot)" -ForegroundColor Yellow
        # Dump last 20 lines of shim log inline for quick triage
        if (Test-Path $Ws.ShimLog) {
            Write-Host "  Shim log tail:" -ForegroundColor Yellow
            # IMPORTANT: pipe through Write-Host so the strings go to the host
            # stream, not the function's pipeline. Otherwise these 15 strings
            # get appended to the function's return value, turning $false into
            # a non-empty array (which is truthy in PowerShell).
            Get-Content $Ws.ShimLog | Select-Object -Last 15 | ForEach-Object {
                Write-Host "    $_"
            }
        }
        return $false
    }
}
