<#
.SYNOPSIS
Regression test for Start.bat's positional argument contract.

.DESCRIPTION
Exercises the real Start.bat (unmodified) against every case in the documented
argument contract, and asserts exactly what it forwards to ClientVaultAccessMSIBuilder.ps1.

Start.bat always aborts on this dev box at the same pre-flight step (MFServer not
installed) regardless of which -Profile/-Lang it forwarded, so that alone can't prove
the forwarding logic is correct. Instead, this test temporarily swaps the real .ps1
for a stub that records whatever parameters it was invoked with, runs Start.bat for
real, reads back what the stub saw, and restores the real script afterward - so every
case here is verified against Start.bat's actual behavior, not a hand-maintained copy
of its logic.

Run from anywhere:
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-StartBatArgs.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kitRoot = Split-Path -Parent $PSScriptRoot
$realPs1 = Join-Path $kitRoot 'ClientVaultAccessMSIBuilder.ps1'
$backupPs1 = Join-Path $kitRoot 'ClientVaultAccessMSIBuilder.ps1.testbackup'
$startBat = Join-Path $kitRoot 'Start.bat'
$resultFile = Join-Path $kitRoot 'tests\.stub_result.json'

$stubContent = @'
[CmdletBinding()]
param(
    [string[]]$Profile,
    [string]$Lang,
    [string]$ServerAddress,
    [switch]$KeepXml
)
$result = [ordered]@{
    Profile = $Profile
    Lang = $Lang
    ServerAddress = $ServerAddress
    KeepXml = [bool]$KeepXml
}
$result | ConvertTo-Json | Set-Content -Path (Join-Path $PSScriptRoot 'tests\.stub_result.json') -Encoding utf8
exit 0
'@

$cases = @(
    @{ Name = 'bare (no args)';               Args = @();                        ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = $null }
    @{ Name = '1 arg: fra';                    Args = @('fra');                   ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = 'fra' }
    @{ Name = '1 arg: eng';                    Args = @('eng');                   ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = 'eng' }
    @{ Name = '1 arg: fr (shorthand)';         Args = @('fr');                    ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = 'fra' }
    @{ Name = '1 arg: en (shorthand)';         Args = @('en');                    ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = 'eng' }
    @{ Name = '1 arg: FRA (case-insensitive)'; Args = @('FRA');                   ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = 'fra' }
    @{ Name = '1 arg: En (case-insensitive)';  Args = @('En');                    ExpectInvoked = $true;  ExpectProfile = $null;          ExpectLang = 'eng' }
    @{ Name = '1 arg: approbation (profile only, silent fra default)'; Args = @('approbation'); ExpectInvoked = $true; ExpectProfile = @('approbation'); ExpectLang = 'fra' }
    @{ Name = '1 arg: conformity (profile only, silent fra default)';  Args = @('conformity');  ExpectInvoked = $true; ExpectProfile = @('conformity');  ExpectLang = 'fra' }
    @{ Name = '1 arg: both (profile only, silent fra default)';       Args = @('both');        ExpectInvoked = $true; ExpectProfile = @('both');        ExpectLang = 'fra' }
    @{ Name = '2 args: approbation fra';       Args = @('approbation', 'fra');    ExpectInvoked = $true;  ExpectProfile = @('approbation'); ExpectLang = 'fra' }
    @{ Name = '2 args: conformity eng';        Args = @('conformity', 'eng');     ExpectInvoked = $true;  ExpectProfile = @('conformity');  ExpectLang = 'eng' }
    @{ Name = '2 args: both eng';              Args = @('both', 'eng');           ExpectInvoked = $true;  ExpectProfile = @('both');        ExpectLang = 'eng' }
    @{ Name = '2 args: approbation en (shorthand lang)'; Args = @('approbation', 'en'); ExpectInvoked = $true; ExpectProfile = @('approbation'); ExpectLang = 'eng' }
    @{ Name = '3 args: rejected before invocation'; Args = @('approbation', 'fra', 'extra'); ExpectInvoked = $false }
)

function Invoke-StartBatCase {
    param([string[]]$BatArgs)
    Remove-Item -Path $resultFile -Force -ErrorAction SilentlyContinue
    $argString = ($BatArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $cmdLine = "`"$startBat`" $argString"
    $stdout = & cmd.exe /c $cmdLine 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    return @{ ExitCode = $exitCode; StdOut = $stdout }
}

function ConvertTo-NormalizedValue {
    param($Value)
    if ($null -eq $Value) { return '' }
    return (@($Value) -join ',')
}

if (-not (Test-Path $realPs1)) {
    Write-Host "[ERROR] $realPs1 not found. Run from the kit's tests\ folder." -ForegroundColor Red
    exit 1
}

Copy-Item -Path $realPs1 -Destination $backupPs1 -Force
$stubContent | Set-Content -Path $realPs1 -Encoding utf8

$failCount = 0

try {
    foreach ($case in $cases) {
        $r = Invoke-StartBatCase -BatArgs $case.Args
        $label = $case.Name

        if (-not $case.ExpectInvoked) {
            if ((Test-Path $resultFile) -or $r.ExitCode -eq 0) {
                Write-Host "[FAIL] $label - expected rejection before invocation, but stub ran or exit code was 0 (exit=$($r.ExitCode))" -ForegroundColor Red
                $failCount++
            }
            else {
                Write-Host "[PASS] $label - rejected without invoking the script (exit=$($r.ExitCode))" -ForegroundColor Green
            }
            continue
        }

        if (-not (Test-Path $resultFile)) {
            Write-Host "[FAIL] $label - stub was never invoked (batch args: $($case.Args -join ' '))" -ForegroundColor Red
            $failCount++
            continue
        }

        $seen = Get-Content -Path $resultFile -Raw | ConvertFrom-Json
        $seenProfileStr = ConvertTo-NormalizedValue $seen.Profile
        $expectProfileStr = ConvertTo-NormalizedValue $case.ExpectProfile
        $seenLangStr = ConvertTo-NormalizedValue $seen.Lang
        $expectLangStr = ConvertTo-NormalizedValue $case.ExpectLang
        $profileOk = $seenProfileStr -eq $expectProfileStr
        $langOk = $seenLangStr -eq $expectLangStr

        if ($profileOk -and $langOk) {
            Write-Host "[PASS] $label - Profile=$seenProfileStr; Lang=$seenLangStr" -ForegroundColor Green
        }
        else {
            Write-Host "[FAIL] $label - expected Profile=$expectProfileStr, Lang=$expectLangStr; got Profile=$seenProfileStr, Lang=$seenLangStr" -ForegroundColor Red
            $failCount++
        }
    }
}
finally {
    Remove-Item -Path $realPs1 -Force -ErrorAction SilentlyContinue
    Move-Item -Path $backupPs1 -Destination $realPs1 -Force
    Remove-Item -Path $resultFile -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failCount -gt 0) {
    Write-Host "===== $failCount case(s) FAILED =====" -ForegroundColor Red
    exit 1
}
Write-Host '===== All cases PASSED =====' -ForegroundColor Green
exit 0
