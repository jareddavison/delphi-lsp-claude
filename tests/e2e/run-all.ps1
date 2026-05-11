# Run the full Haiku-driven regression suite.
#
# Runs each test-*.ps1 in tests/e2e/ sequentially, captures pass/fail,
# prints a summary at the end. Exits 0 if all pass, 1 if any fail.
#
# Each individual test takes 10-30 seconds and costs a small Haiku call
# (~$0.01-0.05). Full suite is ~$0.15-0.20 total.

[CmdletBinding()]
param(
    [switch]$KeepTemp,
    # Run only tests whose name (without leading "test-" and trailing ".ps1")
    # contains the filter string. Useful for retrying one test after a fix.
    [string]$Filter
)

$ErrorActionPreference = 'Stop'

$tests = Get-ChildItem $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name
if ($Filter) {
    $tests = $tests | Where-Object { $_.BaseName -like "*$Filter*" }
    if ($tests.Count -eq 0) {
        Write-Host "No tests match filter '$Filter'" -ForegroundColor Red
        exit 2
    }
}

Write-Host "Running $($tests.Count) regression test(s)..." -ForegroundColor Cyan
Write-Host ''

$results = @()
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
foreach ($t in $tests) {
    Write-Host ("--- $($t.BaseName) ---") -ForegroundColor Cyan
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    # Run the test directly (no pipe — piping to Out-Host clobbers $LASTEXITCODE
    # since Out-Host overwrites it with its own success code).
    & $t.FullName -KeepTemp:$KeepTemp
    $exit = $LASTEXITCODE
    $sw.Stop()
    $results += [PSCustomObject]@{
        Name     = $t.BaseName
        Passed   = ($exit -eq 0)
        ExitCode = $exit
        Seconds  = [int]$sw.Elapsed.TotalSeconds
    }
    Write-Host ''
}
$swTotal.Stop()

Write-Host '=== Summary ===' -ForegroundColor Cyan
foreach ($r in $results) {
    $tag = $r.Passed ? 'PASS' : 'FAIL'
    $color = $r.Passed ? 'Green' : 'Red'
    Write-Host ("  [{0}] {1,-25} ({2}s)" -f $tag, $r.Name, $r.Seconds) -ForegroundColor $color
}
$passed = @($results | Where-Object Passed).Count
$failed = @($results | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host ("Total: {0} passed, {1} failed in {2}s" -f $passed, $failed, [int]$swTotal.Elapsed.TotalSeconds) -ForegroundColor (($failed -eq 0) ? 'Green' : 'Red')
exit (($failed -eq 0) ? 0 : 1)
