# Run the full Haiku-driven regression suite.
#
# Runs each test-*.ps1 in tests/e2e/ sequentially, captures pass/fail,
# prints a summary at the end. Exits 0 if all expected outcomes occur,
# 1 if any test fails unexpectedly or passes unexpectedly.
#
# Each individual test takes 10-30 seconds and costs a small Haiku call
# (~$0.01-0.05). Full suite is ~$0.15-0.20 total for one bitness pass.
#
# -Bitness controls which DelphiLSP binary the shim picks:
#   default — no override; the shim's default applies (currently 32-bit
#             after RSS-5400 — see DelphiLsp.DelphiInstall)
#   32      — DELPHI_LSP_BITS=32, forces bin\DelphiLSP.exe
#   64      — DELPHI_LSP_BITS=64, forces bin64\DelphiLSP.exe
#   both    — runs every test once with =32 and once with =64; cost ~2x.
#             Diagnostic tests under =64 are EXPECTED to fail per
#             RSS-5400 and are tagged XFAIL (red only if they pass —
#             which would be the signal that Embarcadero shipped a fix
#             and the 32-bit default could be reverted).

[CmdletBinding()]
param(
    [switch]$KeepTemp,
    # Run only tests whose name (without leading "test-" and trailing ".ps1")
    # contains the filter string. Useful for retrying one test after a fix.
    [string]$Filter,
    [ValidateSet('default','32','64','both')]
    [string]$Bitness = 'default'
)

$ErrorActionPreference = 'Stop'

# Tests whose failure is expected under a given bitness. When the test
# exits non-zero under that bitness, it counts as XFAIL (yellow, doesn't
# count toward the failure total). When it exits zero under that bitness,
# it counts as XPASS (yellow, DOES count toward the failure total since
# it's a signal that the world has changed under us).
$expectedFails = @{
    '64' = @(
        'test-diagnostics-cold',
        'test-diagnostics-warm',
        'test-diagnostics-syntactic'
    )
}

function Is-ExpectedFail([string]$testBaseName, [string]$bits) {
    return ($expectedFails.ContainsKey($bits)) -and
           ($expectedFails[$bits] -contains $testBaseName)
}

$tests = Get-ChildItem $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name
if ($Filter) {
    $tests = $tests | Where-Object { $_.BaseName -like "*$Filter*" }
    if ($tests.Count -eq 0) {
        Write-Host "No tests match filter '$Filter'" -ForegroundColor Red
        exit 2
    }
}

# Map -Bitness mode to the iteration list. 'default' means a single pass
# with no env override; '32'/'64' force one pass with that override;
# 'both' runs once with 32, once with 64.
$bitnessPasses = switch ($Bitness) {
    'default' { @('default') }
    '32'      { @('32') }
    '64'      { @('64') }
    'both'    { @('32', '64') }
}

Write-Host "Running $($tests.Count) regression test(s) across $($bitnessPasses.Count) bitness pass(es)..." -ForegroundColor Cyan
Write-Host ''

# Save and restore the inherited DELPHI_LSP_BITS so per-pass overrides
# don't leak back to whoever invoked run-all.ps1.
$priorBits = $env:DELPHI_LSP_BITS
$results = @()
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
try {
    foreach ($bits in $bitnessPasses) {
        if ($bits -eq 'default') {
            Remove-Item Env:DELPHI_LSP_BITS -ErrorAction SilentlyContinue
            $label = '(default bitness)'
        } else {
            $env:DELPHI_LSP_BITS = $bits
            $label = "(BITS=$bits)"
        }
        foreach ($t in $tests) {
            Write-Host ("--- $($t.BaseName) $label ---") -ForegroundColor Cyan
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            # Run the test directly (no pipe — piping to Out-Host clobbers
            # $LASTEXITCODE since Out-Host overwrites it with its own
            # success code).
            & $t.FullName -KeepTemp:$KeepTemp
            $exit = $LASTEXITCODE
            $sw.Stop()
            $expected = Is-ExpectedFail $t.BaseName $bits
            $passed = ($exit -eq 0)
            if ($passed -and $expected) {
                $outcome = 'XPASS'  # expected fail, actually passed — surprise
            } elseif ($passed) {
                $outcome = 'PASS'
            } elseif ($expected) {
                $outcome = 'XFAIL'  # expected fail, actually failed — fine
            } else {
                $outcome = 'FAIL'
            }
            $results += [PSCustomObject]@{
                Name     = $t.BaseName
                Bitness  = $bits
                Outcome  = $outcome
                ExitCode = $exit
                Seconds  = [int]$sw.Elapsed.TotalSeconds
            }
            Write-Host ''
        }
    }
} finally {
    if ($null -ne $priorBits) {
        $env:DELPHI_LSP_BITS = $priorBits
    } else {
        Remove-Item Env:DELPHI_LSP_BITS -ErrorAction SilentlyContinue
    }
}
$swTotal.Stop()

Write-Host '=== Summary ===' -ForegroundColor Cyan
foreach ($r in $results) {
    $color = switch ($r.Outcome) {
        'PASS'  { 'Green' }
        'XFAIL' { 'Yellow' }
        'XPASS' { 'Yellow' }
        'FAIL'  { 'Red' }
    }
    $bitsTag = if ($r.Bitness -eq 'default') { '' } else { " [BITS=$($r.Bitness)]" }
    Write-Host ("  [{0,-5}] {1}{2,-15} ({3}s)" -f $r.Outcome, $r.Name, $bitsTag, $r.Seconds) -ForegroundColor $color
}

$pass   = @($results | Where-Object Outcome -eq 'PASS').Count
$xfail  = @($results | Where-Object Outcome -eq 'XFAIL').Count
$xpass  = @($results | Where-Object Outcome -eq 'XPASS').Count
$fail   = @($results | Where-Object Outcome -eq 'FAIL').Count

Write-Host ''
$summary = "Total: $pass passed, $fail failed"
if ($xfail -gt 0) { $summary += ", $xfail xfail" }
if ($xpass -gt 0) { $summary += ", $xpass xpass (unexpected — see RSS-5400)" }
$summary += " in $([int]$swTotal.Elapsed.TotalSeconds)s"
$overall = ($fail -eq 0) -and ($xpass -eq 0)
Write-Host $summary -ForegroundColor ($overall ? 'Green' : 'Red')
exit ($overall ? 0 : 1)
