<#
.SYNOPSIS
Builds customized M-Files client MSIs from live vault metadata.

.DESCRIPTION
Runs pre-flight validation, resolves live vault GUIDs via M-Files COM, generates
customization XML, executes CustomizeInstaller2.3.vbs, and emits MSI + manifest
outputs per requested profile/language.

.NOTES
Author: Harry Joseph
Updated: 2026-07-19
#>
[CmdletBinding()]
param(
    [ValidateSet('conformity', 'approbation', 'both')]
    [Alias('Profile')]
    [string[]]$Profiles,

    [ValidateSet('fra', 'eng', 'all')]
    [string]$Lang,

    [string]$ServerAddress,

    [switch]$KeepXml
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Script-level constants ----

$scriptRoot = $PSScriptRoot
$copyMarkers = @('cp', 'copy', 'test', 'backup')
$outputDir = Join-Path $scriptRoot 'output'
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
$logFile = Join-Path $outputDir ("build_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$customizerVbsPath = Join-Path $scriptRoot 'CustomizeInstaller2.3.vbs'

# Log retention: this kit gets rerun often during troubleshooting/testing, and every invocation
# (even one that fails in the first second at pre-flight) leaves a new timestamped log behind.
# Prune anything older than 30 days so output\ doesn't grow unbounded; never let a cleanup
# failure block the actual build.
try {
    Get-ChildItem -Path $outputDir -Filter 'build_*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
catch { }

# ---- Cross-cutting utilities ----

function Write-Stage {
    param(
        [ValidateSet('PROGRESS', 'SUCCESS', 'WARN', 'ERROR')][string]$Tag,
        [string]$Message
    )

    $line = "[$Tag] $Message"
    Write-Host $line

    # Keep a physical build log for enterprise traceability and post-mortem review.
    # Uses .NET AppendAllText with an explicit no-BOM UTF8Encoding rather than
    # Add-Content -Encoding UTF8, which writes a BOM on every call under Windows
    # PowerShell 5.1 (there is no utf8NoBOM literal on 5.1's -Encoding parameter).
    try {
        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        [System.IO.File]::AppendAllText($logFile, "[$stamp] $line" + [Environment]::NewLine, $script:utf8NoBom)
    }
    catch {
        # Logging failures should never replace the primary operation failure path.
        Write-Host "[WARN] Could not append to build log '$logFile': $($_.Exception.Message)"
    }
}

function Invoke-Abort {
    param([string]$Message)
    Write-Stage -Tag ERROR -Message $Message
    exit 1
}

function Get-JsonValue {
    # Safe property read on a ConvertFrom-Json result: returns $null for a missing key, a null
    # value, or a key on an empty {} node - all three throw under Set-StrictMode via direct dot
    # access or via .PSObject.Properties.Name (confirmed empirically: an empty {} node's own
    # .PSObject.Properties collection doesn't expose .Name/.Count under strict mode either), so
    # this must go through try/catch rather than a pre-check.
    param($Object, [string]$Name)
    try { return $Object.$Name } catch { return $null }
}

function Get-JsonPropertyNames {
    param(
        $Object,
        [string]$NodeNameForError = 'json node'
    )

    if ($null -eq $Object) { return @() }

    try {
        $names = New-Object System.Collections.Generic.List[string]
        foreach ($p in $Object.PSObject.Properties) {
            if ($null -ne $p -and -not [string]::IsNullOrWhiteSpace([string]$p.Name)) {
                [void]$names.Add([string]$p.Name)
            }
        }
        return @($names)
    }
    catch {
        Invoke-Abort "Could not enumerate properties under '$NodeNameForError': $($_.Exception.Message)"
    }
}

function Close-ComObjectSafe {
    param([object]$ComObject)

    if ($null -eq $ComObject) { return }
    if ([System.Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
        [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
    }
}

function Invoke-ComGarbageCollection {
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
}

function Invoke-WithRetry {
    param(
        [scriptblock]$Action,
        [string]$Operation,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $Action
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts) { throw }
            Write-Stage -Tag WARN -Message "$Operation failed on attempt $attempt/$MaxAttempts ($($_.Exception.Message)). Retrying in $DelaySeconds second(s)..."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function New-TempFilePath {
    param([string]$Extension)
    return Join-Path $env:TEMP ("{0}.{1}" -f ([guid]::NewGuid()), $Extension)
}

# ---- Config loading ----

function Get-KitConfig {
    $profilesPath = Join-Path $scriptRoot 'profiles.json'
    if (-not (Test-Path $profilesPath)) {
        Invoke-Abort "Required kit file missing: profiles.json. The kit folder must be copied complete, then rerun."
    }
    if (-not (Test-Path $customizerVbsPath)) {
        Invoke-Abort "Required kit file missing: CustomizeInstaller2.3.vbs. The kit folder must be copied complete, then rerun."
    }

    $config = Get-Content -Path $profilesPath -Raw | ConvertFrom-Json

    foreach ($node in @('packageShare', 'server', 'vaultPatterns', 'profiles', 'defaultProfiles')) {
        if ($null -eq (Get-JsonValue -Object $config -Name $node)) {
            Invoke-Abort "profiles.json is missing required node '$node'."
        }
    }

    $serverConfig = Get-JsonValue -Object $config -Name 'server'
    foreach ($serverNode in @('endpoint', 'protocolSequence', 'authType', 'autoLogin', 'minimumAuthenticationLevel')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-JsonValue -Object $serverConfig -Name $serverNode))) {
            Invoke-Abort "profiles.json server config is missing required node 'server.$serverNode'."
        }
    }

    $profilesConfig = Get-JsonValue -Object $config -Name 'profiles'
    foreach ($profileName in $config.defaultProfiles) {
        if ($null -eq (Get-JsonValue -Object $profilesConfig -Name $profileName)) {
            Invoke-Abort "profiles.json defaultProfiles contains '$profileName' but no matching profiles.$profileName definition exists."
        }
    }

    if (-not [System.IO.Path]::IsPathRooted($config.packageShare)) {
        $config.packageShare = Join-Path $scriptRoot $config.packageShare
    }

    return $config
}

# ---- Pre-flight ----

function Test-PreflightEnvironment {
    param($Config)

    Write-Stage -Tag PROGRESS -Message 'Checking environment readiness...'

    # An exact-name lookup ('MFServer') misses real installations: M-Files versions the Windows
    # service's actual Name, not just its DisplayName (confirmed on a live install: internal Name
    # is "MFServer 26.6.16115.9", not "MFServer"). Matched name must start with "MFServer" followed
    # by a space and a digit, to find the versioned name while still excluding the separate
    # "MFServerAux ..." (M-Files Server Auxiliary Services) service, which also starts with "MFServer".
    $svc = Get-Service -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'MFServer' -or $_.Name -like 'MFServer [0-9]*' } |
        Select-Object -First 1
    if (-not $svc) {
        Invoke-Abort 'M-Files Server service (MFServer) is not installed on this machine. This tool must run on the M-Files server. Install M-Files Server, then rerun the script.'
    }
    if ($svc.Status -ne 'Running') {
        Invoke-Abort 'M-Files Server service (MFServer) is not running. Start the service, then rerun the script.'
    }

    if (-not (Test-Path $Config.packageShare)) {
        Invoke-Abort "Package share unreachable: '$($Config.packageShare)'. Check network/credentials/DNS from this server, then rerun."
    }

    $versionsPath = Join-Path $Config.packageShare 'versions.json'
    if (-not (Test-Path $versionsPath)) {
        Invoke-Abort "versions.json not found on package share '$($Config.packageShare)'. Confirm the share contains the pinned package manifest."
    }

    if (-not (Get-Command 'cscript.exe' -ErrorAction SilentlyContinue)) {
        Invoke-Abort 'cscript.exe not found on this host. Expected under %WINDIR%\System32. Repair the Windows Script Host installation.'
    }

    Write-Stage -Tag SUCCESS -Message 'Environment checks passed.'
    return $versionsPath
}

# ---- Vault resolution ----

function Connect-MFilesServer {
    # Connect's real signature is (AuthType, UserName, Password, Domain, ProtocolSequence,
    # NetworkAddress, Endpoint, LocalComputerName, AllowAnonymousConnection) - 9 parameters,
    # confirmed against a live MFilesAPI installation via Get-Member. AuthType enum values
    # confirmed by loading the real Interop.MFilesApi.dll: 0 = MFAuthTypeUnknown,
    # 1 = MFAuthTypeLoggedOnWindowsUser (Windows SSO, no credentials), 2 = SpecificWindowsUser,
    # 3 = MFAuthTypeSpecificMFilesUser (explicit username/password).
    param($ServerApp, [int]$AuthType, [string]$UserName, [string]$Password, [string]$ProtocolSequence, [string]$Endpoint, [string]$LocalComputerName)
    $ServerApp.Connect($AuthType, $UserName, $Password, '', $ProtocolSequence, 'localhost', $Endpoint, $LocalComputerName, $false) | Out-Null
}

function Get-OnlineVaults {
    param($Config)

    Write-Stage -Tag PROGRESS -Message 'Connecting to M-Files server (localhost) via COM...'

    $protocolSequence = $Config.server.protocolSequence
    $endpoint = $Config.server.endpoint
    $localComputerName = [System.Net.Dns]::GetHostName()
    $requestedAuthType = [string]$Config.server.authType

    $serverApp = $null
    $onlineVaultCom = $null
    try {
        if ($requestedAuthType -eq 'auto') {
            $serverApp = New-Object -ComObject 'MFilesAPI.MFilesServerApplication'
            try {
                # 2 total attempts, 10s apart - guards against a slow COM response being misread
                # as SSO being unavailable and prompting for credentials unnecessarily.
                Invoke-WithRetry -Operation 'Windows SSO connection' -MaxAttempts 2 -DelaySeconds 10 -Action {
                    Connect-MFilesServer -ServerApp $serverApp -AuthType 1 -UserName '' -Password '' -ProtocolSequence $protocolSequence -Endpoint $endpoint -LocalComputerName $localComputerName
                }
                $detectedAuthType = '1'
            }
            catch {
                Write-Stage -Tag WARN -Message "Windows SSO connection failed after retries ($($_.Exception.Message)). Falling back to M-Files Authentication."
                if ($null -ne $serverApp) {
                    try { $serverApp.Disconnect() } catch { }
                    Close-ComObjectSafe -ComObject $serverApp
                }
                $serverApp = New-Object -ComObject 'MFilesAPI.MFilesServerApplication'

                $credential = Get-Credential -Message 'Windows SSO failed. Enter M-Files Authentication credentials.'
                if ($null -eq $credential) {
                    Invoke-Abort 'M-Files authentication cancelled by operator. No credentials provided.'
                }

                $plainPassword = $credential.GetNetworkCredential().Password
                try {
                    Connect-MFilesServer -ServerApp $serverApp -AuthType 3 -UserName $credential.UserName -Password $plainPassword -ProtocolSequence $protocolSequence -Endpoint $endpoint -LocalComputerName $localComputerName
                }
                catch {
                    Invoke-Abort "COM connection to M-Files server failed with both Windows SSO and M-Files Authentication: $($_.Exception.Message). Confirm MFilesAPI is installed/registered and the supplied credentials are correct."
                }
                finally {
                    $plainPassword = $null
                }
                $detectedAuthType = '3'
            }
        }
        else {
            $serverApp = New-Object -ComObject 'MFilesAPI.MFilesServerApplication'
            Connect-MFilesServer -ServerApp $serverApp -AuthType ([int]$requestedAuthType) -UserName '' -Password '' -ProtocolSequence $protocolSequence -Endpoint $endpoint -LocalComputerName $localComputerName
            $detectedAuthType = $requestedAuthType
        }

        $authTypeLabel = if ($detectedAuthType -eq '1') { 'Windows SSO' } else { 'M-Files Authentication' }
        Write-Stage -Tag SUCCESS -Message "Connection successful using $authTypeLabel (AuthType=$detectedAuthType)."

        $vaults = New-Object System.Collections.Generic.List[object]
        $onlineVaultCom = $serverApp.GetOnlineVaults()
        for ($i = 1; $i -le $onlineVaultCom.Count; $i++) {
            $v = $onlineVaultCom.Item($i)
            try {
                $vaults.Add([pscustomobject]@{ Name = $v.Name; GUID = $v.GUID.ToString() })
            }
            finally {
                Close-ComObjectSafe -ComObject $v
            }
        }

        Write-Stage -Tag SUCCESS -Message "Enumerated $($vaults.Count) online vault(s)."
        return @{ Vaults = $vaults; DetectedAuthType = $detectedAuthType }
    }
    catch {
        Invoke-Abort "COM connection to M-Files server failed: $($_.Exception.Message). Confirm MFilesAPI is installed/registered and this account can log in to the server."
    }
    finally {
        Close-ComObjectSafe -ComObject $onlineVaultCom
        if ($null -ne $serverApp) {
            try { $serverApp.Disconnect() } catch { }
            Close-ComObjectSafe -ComObject $serverApp
        }
        Invoke-ComGarbageCollection
    }
}

function Resolve-Vaults {
    param($OnlineVaults, $Config, [string[]]$RequiredKeys)

    Write-Stage -Tag PROGRESS -Message 'Resolving vaults by pattern...'

    $resolved = @{}
    $vaultPatterns = Get-JsonValue -Object $Config -Name 'vaultPatterns'
    $vaultPatternKeys = Get-JsonPropertyNames -Object $vaultPatterns -NodeNameForError 'vaultPatterns'
    if ($vaultPatternKeys.Count -eq 0) {
        Invoke-Abort "profiles.json 'vaultPatterns' is empty. Define at least one vault pattern before running builds."
    }

    foreach ($key in $vaultPatternKeys) {
        $pattern = [string](Get-JsonValue -Object $vaultPatterns -Name $key)
        if ([string]::IsNullOrWhiteSpace($pattern)) {
            Invoke-Abort "profiles.json 'vaultPatterns.$key' is missing or empty."
        }
        $inScope = $RequiredKeys -contains $key
        $found = @($OnlineVaults | Where-Object { $_.Name -match [regex]::Escape($pattern) })

        if ($found.Count -eq 1) {
            if ($inScope) {
                $resolved[$key] = $found[0]
                Write-Stage -Tag SUCCESS -Message "Resolved '$key' -> '$($found[0].Name)' ($($found[0].GUID))"
            }
            continue
        }

        if (-not $inScope) {
            # Out-of-scope anomaly: this run doesn't need '$key', so a zero-match or duplicate here
            # is only ever a heads-up for a later full-set run, never a reason to abort this one.
            Write-Stage -Tag WARN -Message "note: $($found.Count) vault(s) match '$pattern' - resolve before running the full set"
            continue
        }

        if ($found.Count -eq 0) {
            $names = ($OnlineVaults | ForEach-Object { $_.Name }) -join ', '
            Invoke-Abort "No vault matching '$pattern' found among online vaults. Online vaults: $names. If the $key vault was just imported, verify it is attached and online in M-Files Admin, then rerun."
        }
        else {
            $listed = $found | ForEach-Object {
                $flag = ''
                foreach ($marker in $copyMarkers) {
                    if ($_.Name -match [regex]::Escape($marker)) { $flag = ' [possible copy]'; break }
                }
                '"' + $_.Name + '"' + $flag
            }
            Invoke-Abort "Only one $key vault can exist. Found $($found.Count) online: $($listed -join ', '). Detach or remove the extra vault in M-Files Admin, then rerun the script."
        }
    }

    return $resolved
}

# ---- Package integrity ----

function Get-MsiProductLanguage {
    param([string]$MsiPath)

    $installer = $null
    $db = $null
    $view = $null
    $record = $null

    try {
        $installer = New-Object -ComObject 'WindowsInstaller.Installer'
        $db = $installer.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $installer, @($MsiPath, 0))
        $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property``='ProductLanguage'"))
        $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
        if ($null -eq $record) { return $null }
        return $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, 1)
    }
    catch {
        Invoke-Abort "Failed to read ProductLanguage from MSI '$MsiPath': $($_.Exception.Message)."
    }
    finally {
        Close-ComObjectSafe -ComObject $record
        if ($null -ne $view) {
            try { [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) } catch { }
            Close-ComObjectSafe -ComObject $view
        }
        Close-ComObjectSafe -ComObject $db
        Close-ComObjectSafe -ComObject $installer
        Invoke-ComGarbageCollection
    }
}

function Get-BaseMsiFileName {
    param([string]$Lang, [string]$Pinned)
    return "M-Files_Online_x64_${Lang}_client_${Pinned}_EV.msi"
}

function Test-PackageIntegrity {
    param([string[]]$Languages, $Config, [string]$VersionsPath)

    Write-Stage -Tag PROGRESS -Message 'Verifying package integrity...'

    $versions = Get-Content -Path $VersionsPath -Raw | ConvertFrom-Json

    $pinned = Get-JsonValue -Object $versions -Name 'pinned'
    if ([string]::IsNullOrWhiteSpace([string]$pinned)) {
        Invoke-Abort "versions.json is missing a non-empty 'pinned' value."
    }

    $packagesNode = Get-JsonValue -Object $versions -Name 'packages'
    if ($null -eq $packagesNode) {
        Invoke-Abort "versions.json is missing a 'packages' node."
    }
    $versionNode = Get-JsonValue -Object $packagesNode -Name $pinned
    if ($null -eq $versionNode) {
        Invoke-Abort "versions.json has no packages entry for pinned version '$pinned'."
    }

    $vbsIdentity = Get-JsonValue -Object $versions -Name 'vbs'
    if ($vbsIdentity -and $vbsIdentity -ne 'CustomizeInstaller2.3.vbs') {
        Invoke-Abort "versions.json VBS identity mismatch. Expected 'CustomizeInstaller2.3.vbs', found '$vbsIdentity'."
    }

    $result = @{}

    foreach ($lang in $Languages) {
        $fileName = Get-BaseMsiFileName -Lang $lang -Pinned $pinned
        $path = Join-Path $Config.packageShare $fileName

        if (-not (Test-Path $path)) {
            Invoke-Abort "Pinned base MSI missing for language '$lang'. Expected: $fileName in $($Config.packageShare)."
        }

        $sig = Get-AuthenticodeSignature -FilePath $path
        if ($sig.Status -ne 'Valid') {
            Invoke-Abort "Authenticode signature invalid for '$fileName' (status: $($sig.Status)). Refusing to build."
        }

        $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash

        $langNode = Get-JsonValue -Object $versionNode -Name $lang
        if ($null -eq $langNode) {
            Invoke-Abort "versions.json has no language entry for pinned version '$pinned' / '$lang'."
        }

        $expectedHash = Get-JsonValue -Object $langNode -Name 'sha256'
        if ([string]::IsNullOrWhiteSpace([string]$expectedHash)) {
            Invoke-Abort "No SHA-256 recorded in versions.json for pinned version '$pinned' / language '$lang'. Run Get-FileHash on the base MSI and record it before building."
        }
        if ($expectedHash -notmatch '^[0-9A-Fa-f]{64}$') {
            Invoke-Abort "versions.json has a placeholder or malformed SHA-256 for pinned version '$pinned' / language '$lang' (value: '$expectedHash'). This has never been recorded from a real file. Run: Get-FileHash -Path '$path' -Algorithm SHA256, then paste the resulting hash into versions.json and rerun."
        }
        if ($hash.ToUpperInvariant() -ne $expectedHash.ToUpperInvariant()) {
            Invoke-Abort "SHA-256 mismatch for '$fileName'. Expected $expectedHash, computed $hash. Possible tampering or a bad copy on the share."
        }

        $productLang = Get-MsiProductLanguage -MsiPath $path
        if ($null -eq $productLang -or [string]::IsNullOrWhiteSpace([string]$productLang)) {
            Invoke-Abort "ProductLanguage property missing in '$fileName'. Check MSI integrity/source package."
        }
        # Not compared against a fra/eng expected value: M-Files MSIs report ProductLanguage 1033
        # regardless of client-language variant (confirmed on real fra/eng packages), so it can't
        # distinguish them. Recorded in the manifest for observability only - the SHA-256 pin above
        # is the actual language guarantee, established once by a human at intake (see versions.json
        # refresh procedure in the PRD).

        $result[$lang] = [pscustomobject]@{ Path = $path; FileName = $fileName; Sha256 = $hash; ProductLanguage = $productLang }
        Write-Stage -Tag SUCCESS -Message "Package verified: $fileName"
    }

    return @{ Packages = $result; Pinned = $pinned; Vbs = $vbsIdentity }
}

# ---- XML generation ----

function Get-NetworkAddress {
    param([string]$Override)
    if ($Override) { return $Override }

    try {
        $hostEntry = [System.Net.Dns]::GetHostEntry('')
        if ($null -ne $hostEntry -and -not [string]::IsNullOrWhiteSpace([string]$hostEntry.HostName)) {
            return $hostEntry.HostName
        }
    }
    catch {
        Write-Stage -Tag WARN -Message "Auto-detect FQDN via DNS host entry failed: $($_.Exception.Message). Falling back to local host name."
    }

    try {
        $hostName = [System.Net.Dns]::GetHostName()
        if (-not [string]::IsNullOrWhiteSpace([string]$hostName)) {
            return $hostName
        }
    }
    catch {
        Write-Stage -Tag WARN -Message "Fallback host name lookup failed: $($_.Exception.Message)."
    }

    Invoke-Abort 'Could not auto-detect a network-reachable server name. Use -ServerAddress to provide a hostname/FQDN explicitly.'
}

function Add-XmlChildText {
    param($Doc, $Parent, [string]$Name, [string]$Text)
    $el = $Doc.CreateElement($Name)
    $el.InnerText = $Text
    $Parent.AppendChild($el) | Out-Null
}

function New-CustomizationXml {
    param($ProfileVaults, $Config, [string]$NetworkAddress, [bool]$AutoUpdate, [string]$OutPath)

    $doc = New-Object System.Xml.XmlDocument
    $root = $doc.CreateElement('root')
    $doc.AppendChild($root) | Out-Null

    Add-XmlChildText -Doc $doc -Parent $root -Name 'VaultConnections' -Text 'True'

    if (-not $AutoUpdate) {
        $common = $doc.CreateElement('Common')
        $au = $doc.CreateElement('AutomaticUpdates')
        Add-XmlChildText -Doc $doc -Parent $au -Name 'CheckForUpdates' -Text '0'
        $common.AppendChild($au) | Out-Null
        $root.AppendChild($common) | Out-Null
    }

    $client = $doc.CreateElement('Client')
    $vaultsEl = $doc.CreateElement('Vaults')

    foreach ($pv in $ProfileVaults) {
        $vaultEl = $doc.CreateElement('Vault')
        $vaultEl.SetAttribute('name', $pv.Name)

        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'ServerVaultName' -Text $pv.Name
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'ServerVaultGUID' -Text $pv.GUID
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'ProtocolSequence' -Text $Config.server.protocolSequence
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'NetworkAddress' -Text $NetworkAddress
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'Endpoint' -Text $Config.server.endpoint
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'AuthType' -Text ('#' + $Config.server.authType)
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'AutoLogin' -Text ('#' + $Config.server.autoLogin)
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'SPN' -Text ''
        Add-XmlChildText -Doc $doc -Parent $vaultEl -Name 'MinimumAuthenticationLevel' -Text ('#' + $Config.server.minimumAuthenticationLevel)

        $vaultsEl.AppendChild($vaultEl) | Out-Null
    }

    $client.AppendChild($vaultsEl) | Out-Null
    $root.AppendChild($client) | Out-Null

    $doc.Save($OutPath)
}

# ---- Customizer invocation (cscript build step) ----

function Get-ProfileDisplayLabel {
    param([string]$ProfileName)

    switch ($ProfileName.ToLowerInvariant()) {
        'conformity' { return 'Conformity' }
        'approbation' { return 'Approbation' }
        'both' { return 'Conformity and Approbation' }
        default { return $ProfileName }
    }
}

function Get-ProfileFileLabel {
    param([string]$ProfileName)

    switch ($ProfileName.ToLowerInvariant()) {
        'conformity' { return 'Conformity' }
        'approbation' { return 'Approbation' }
        'both' { return 'ConformityAndApprobation' }
        default { return (Get-Culture).TextInfo.ToTitleCase($ProfileName) }
    }
}

function Get-OutputMsiFileName {
    param([string]$Lang, [string]$Pinned, [string]$ProfileName)
    return "M-Files_Online_x64_${Lang}_client_${Pinned}_EV_$(Get-ProfileFileLabel $ProfileName).msi"
}

function Invoke-CustomizerBuild {
    # Runs CustomizeInstaller2.3.vbs via cscript with a 300s timeout (kill + fail on timeout,
    # rather than the pipeline hanging forever on a stuck process). Returns a result object;
    # never writes to $buildResults or Write-Stage itself, so the caller keeps full control of
    # the "Profile '$profileName' [$lang] failed: ..." message context.
    #
    # Uses System.Diagnostics.Process directly rather than Start-Process -PassThru: confirmed
    # empirically that under Windows Powershell 5.1 (this project's target runtime - hard rule 4),
    # Start-Process -PassThru combined with -RedirectStandardOutput/-RedirectStandardError makes
    # $proc.ExitCode read back as $null after WaitForExit(timeout) - every single time, across
    # multiple independent runs - which would have made `$proc.ExitCode -ne 0` always true and
    # every successful build silently misreported as failed. Confirmed the same code path returns
    # the correct exit code under pwsh 7, so this is version-specific and would never have surfaced
    # outside a real Windows PowerShell 5.1 run. Output/error streams are read via the standard
    # async event-handler pattern (BeginOutputReadLine/BeginErrorReadLine) rather than sequential
    # ReadToEnd(), to avoid the classic redirected-process deadlock if a future build produces
    # enough output on one stream to fill the OS pipe buffer before the other stream is read.
    param([string]$BaseMsiPath, [string]$XmlPath, [string]$OutputPath)

    $cscriptArgs = @('//nologo', $customizerVbsPath, 'xml', $BaseMsiPath, $XmlPath, $OutputPath, 'True', 'False')

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cscript.exe'
    $psi.Arguments = ($cscriptArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi

    $stderrBuilder = New-Object System.Text.StringBuilder
    $appendAction = { if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.AppendLine($EventArgs.Data) } }
    $stdoutBuilder = New-Object System.Text.StringBuilder
    $stdoutEvent = Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action $appendAction -MessageData $stdoutBuilder
    $stderrEvent = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $appendAction -MessageData $stderrBuilder

    try {
        try {
            [void]$proc.Start()
        }
        catch {
            return @{ Success = $false; Reason = "could not start cscript ($($_.Exception.Message))" }
        }

        $proc.BeginOutputReadLine()
        $proc.BeginErrorReadLine()

        $completed = $proc.WaitForExit(300000)
        if (-not $completed) {
            try { $proc.Kill() } catch { }
            return @{ Success = $false; Reason = 'cscript timed out after 300 seconds' }
        }

        # Flush asynchronous stdout/stderr buffers
        $proc.WaitForExit()

        if ($proc.ExitCode -ne 0) {
            return @{ Success = $false; Reason = "cscript exit code $($proc.ExitCode). $($stderrBuilder.ToString())" }
        }

        return @{ Success = $true; Reason = $null }
    }
    finally {
        Unregister-Event -SourceIdentifier $stdoutEvent.Name -ErrorAction SilentlyContinue
        Unregister-Event -SourceIdentifier $stderrEvent.Name -ErrorAction SilentlyContinue
        Remove-Job -Name $stdoutEvent.Name -Force -ErrorAction SilentlyContinue
        Remove-Job -Name $stderrEvent.Name -Force -ErrorAction SilentlyContinue
        $proc.Dispose()
    }
}

# ---- Manifest + build-result helpers ----

function New-BuildManifest {
    param(
        [string]$ProfileName,
        [string]$Lang,
        $LangSelection,
        $BaseInfo,
        $PackageInfo,
        $ProfileDef,
        $ResolvedVaults,
        [string]$NetworkAddress,
        $Config,
        [string]$ServerAddressOverride,
        [string]$OutputHash
    )

    return [ordered]@{
        builtUtc               = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        profile                = $ProfileName
        lang                   = $Lang
        langResolvedBy         = $LangSelection.ResolvedBy
        baseMsi                = $BaseInfo.FileName
        baseMsiSha256          = $BaseInfo.Sha256
        baseMsiProductLanguage = $BaseInfo.ProductLanguage
        vbs                    = $PackageInfo.Vbs
        autoUpdate             = [bool]$ProfileDef.autoUpdate
        vaults                 = @($ProfileDef.vaultKeys | ForEach-Object {
                $key = $_
                [ordered]@{ key = $key; resolvedName = $ResolvedVaults[$key].Name; guid = $ResolvedVaults[$key].GUID; resolvedBy = 'auto-pattern' }
            })
        server                 = [ordered]@{
            networkAddress    = $NetworkAddress
            endpoint          = $Config.server.endpoint
            addressResolvedBy = if ($ServerAddressOverride) { '-ServerAddress' } else { 'auto-detect' }
            clientAuthType    = $Config.server.clientAuthType
            builderAuthType   = $Config.server.builderAuthType
        }
        outputSha256           = $OutputHash
        builtBy                = $env:USERNAME
        builtOn                = $env:COMPUTERNAME
    }
}

function New-BuildResult {
    param([string]$ProfileName, [string]$Lang, [string]$Status, [string]$Reason, [string]$Path)
    return [pscustomobject]@{ Profile = $ProfileName; Lang = $Lang; Status = $Status; Reason = $Reason; Path = $Path }
}

# ---- Language menu ----

function Select-Language {
    param([string]$ExplicitLang)

    if ($ExplicitLang) {
        return @{ Value = $ExplicitLang; ResolvedBy = 'explicit' }
    }

    $menuIsFrench = $false
    while ($true) {
        Clear-Host
        Write-Host '========================================='
        Write-Host '          CLIENT VAULT CREATION'
        Write-Host '========================================='
        Write-Host ''
        if (-not $menuIsFrench) {
            Write-Host ' Select client MSI language:'
            Write-Host ''
            Write-Host '   [1] French   (default)'
            Write-Host '   [2] English'
            Write-Host ''
            Write-Host '   [F] Afficher le menu en francais'
            Write-Host '   [X] Exit'
            Write-Host ''
            $choice = Read-Host ' Selection (Enter = 1)'
        }
        else {
            Write-Host ' Choisir la langue du client MSI :'
            Write-Host ''
            Write-Host '   [1] Francais   (defaut)'
            Write-Host '   [2] English'
            Write-Host ''
            Write-Host '   [E] Show menu in English'
            Write-Host '   [X] Quitter'
            Write-Host ''
            $choice = Read-Host ' Selection (Entree = 1)'
        }

        switch ($choice.Trim().ToUpperInvariant()) {
            '' { return @{ Value = 'fra'; ResolvedBy = 'menu-default' } }
            '1' { return @{ Value = 'fra'; ResolvedBy = 'menu-selection' } }
            '2' { return @{ Value = 'eng'; ResolvedBy = 'menu-selection' } }
            'F' {
                if ($menuIsFrench) {
                    Write-Host ''
                    Write-Host 'Invalid selection.'
                    Start-Sleep -Seconds 1
                }
                else {
                    $menuIsFrench = $true
                }
            }
            'E' {
                if (-not $menuIsFrench) {
                    Write-Host ''
                    Write-Host 'Invalid selection.'
                    Start-Sleep -Seconds 1
                }
                else {
                    $menuIsFrench = $false
                }
            }
            'X' {
                Write-Stage -Tag WARN -Message 'User cancelled from language menu.'
                exit 1
            }
            default { Write-Host ''; Write-Host 'Invalid selection.'; Start-Sleep -Seconds 1 }
        }
    }
}

# ---- Main ----

# Top-level guard: any exception not already routed through Invoke-Abort (i.e. one we didn't
# anticipate) would otherwise terminate via PowerShell's default error rendering - console-only,
# never reaching Write-Stage/the log file, and lost once the launching window closes. This does
# not change any existing exit code or control flow: Invoke-Abort's own `exit 1` calls, and the
# `exit 0`/`exit 1` at the end of this block, terminate the process directly and are never
# intercepted by this catch.
try {

$config = Get-KitConfig

$profilesToBuild = if ($Profiles) { $Profiles } else { $config.defaultProfiles }
$langSelection = Select-Language -ExplicitLang $Lang
$languagesToBuild = if ($langSelection.Value -eq 'all') { @('fra', 'eng') } else { @($langSelection.Value) }
$profilesConfig = Get-JsonValue -Object $config -Name 'profiles'
$requiredVaultKeyBuffer = New-Object System.Collections.Generic.List[string]
foreach ($profileName in $profilesToBuild) {
    $profileConfig = Get-JsonValue -Object $profilesConfig -Name $profileName
    if ($null -eq $profileConfig) {
        Invoke-Abort "profiles.json has no 'profiles.$profileName' definition."
    }

    $vaultKeys = @(Get-JsonValue -Object $profileConfig -Name 'vaultKeys')
    if ($vaultKeys.Count -eq 0) {
        Invoke-Abort "profiles.json 'profiles.$profileName.vaultKeys' is missing or empty."
    }

    foreach ($vaultKey in $vaultKeys) {
        if (-not [string]::IsNullOrWhiteSpace([string]$vaultKey)) {
            [void]$requiredVaultKeyBuffer.Add([string]$vaultKey)
        }
    }
}
$requiredVaultKeys = @($requiredVaultKeyBuffer | Select-Object -Unique)

$versionsPath = Test-PreflightEnvironment -Config $config
$vaultConnectionResult = Get-OnlineVaults -Config $config
$onlineVaults = $vaultConnectionResult.Vaults

# Wrapped so a failure here (e.g. an unexpected value on $config.server) is written to the
# build log via Invoke-Abort instead of terminating silently with nothing after "Enumerated N
# online vault(s)." - StrictMode/ErrorActionPreference='Stop' errors in this block otherwise
# never reach Write-Stage and the console error is lost once the launching window closes.
try {
    # Decouple builder COM auth from client MSI auth:
    # Preserve configured clientAuthType if defined, or explicit authType if not 'auto'.
    # Only fall back to builder-detected authType if clientAuthType is omitted and authType was 'auto'.
    # 'clientAuthType'/'builderAuthType' are not in profiles.json's schema, so this PSCustomObject
    # (from ConvertFrom-Json) has no such property yet - plain dot-assignment throws under
    # StrictMode ("The property '...' cannot be found on this object"); Add-Member -Force is
    # required to create (or overwrite) these note properties.
    $builderAuthType = $vaultConnectionResult.DetectedAuthType
    $configuredClientAuthType = Get-JsonValue -Object $config.server -Name 'clientAuthType'
    if (-not [string]::IsNullOrWhiteSpace([string]$configuredClientAuthType)) {
        $clientAuthType = [string]$configuredClientAuthType
    }
    elseif ($config.server.authType -ne 'auto') {
        $clientAuthType = [string]$config.server.authType
    }
    else {
        $clientAuthType = $builderAuthType
    }
    $config.server | Add-Member -NotePropertyName 'clientAuthType' -NotePropertyValue $clientAuthType -Force
    $config.server | Add-Member -NotePropertyName 'builderAuthType' -NotePropertyValue $builderAuthType -Force
    $config.server.authType = $clientAuthType
}
catch {
    Invoke-Abort "Failed reconciling client/builder AuthType from profiles.json 'server' config: $($_.Exception.Message)."
}
$resolvedVaults = Resolve-Vaults -OnlineVaults $onlineVaults -Config $config -RequiredKeys $requiredVaultKeys
$packageInfo = Test-PackageIntegrity -Languages $languagesToBuild -Config $config -VersionsPath $versionsPath
$networkAddress = Get-NetworkAddress -Override $ServerAddress

Write-Stage -Tag SUCCESS -Message "Pre-flight passed. NetworkAddress for generated clients: $networkAddress"

$buildResults = New-Object System.Collections.Generic.List[object]
# @() forces array context - $profilesToBuild can collapse to a scalar (e.g. a single -Profile
# value or a single-element profiles.json list), and a scalar has no .Count under StrictMode.
$totalBuildSteps = @($profilesToBuild).Count * @($languagesToBuild).Count
$buildStepIndex = 0

foreach ($profileName in $profilesToBuild) {
    $profileDef = Get-JsonValue -Object $profilesConfig -Name $profileName
    if ($null -eq $profileDef) {
        Invoke-Abort "profiles.json has no 'profiles.$profileName' definition."
    }
    $profileLabel = Get-ProfileDisplayLabel -ProfileName $profileName
    $profileVaults = $profileDef.vaultKeys | ForEach-Object { $resolvedVaults[$_] }

    $tempXml = New-TempFilePath -Extension 'xml'
    New-CustomizationXml -ProfileVaults $profileVaults -Config $config -NetworkAddress $networkAddress -AutoUpdate ([bool]$profileDef.autoUpdate) -OutPath $tempXml

    foreach ($lang in $languagesToBuild) {
        $baseInfo = $packageInfo.Packages[$lang]
        $outputName = Get-OutputMsiFileName -Lang $lang -Pinned $packageInfo.Pinned -ProfileName $profileName
        $tempOut = New-TempFilePath -Extension 'msi'

        $buildStepIndex++
        Write-Progress -Activity 'Building M-Files client MSIs' -Status "$profileLabel [$lang] ($buildStepIndex of $totalBuildSteps)" -PercentComplete ([int](($buildStepIndex / $totalBuildSteps) * 100))
        Write-Stage -Tag PROGRESS -Message "Building '$profileLabel' [$lang] -> $outputName"

        $buildOutcome = Invoke-CustomizerBuild -BaseMsiPath $baseInfo.Path -XmlPath $tempXml -OutputPath $tempOut
        if (-not $buildOutcome.Success) {
            Write-Stage -Tag WARN -Message "Profile '$profileLabel' [$lang] failed: $($buildOutcome.Reason)."
            $buildResults.Add((New-BuildResult -ProfileName $profileLabel -Lang $lang -Status 'Failed' -Reason $buildOutcome.Reason))
            Remove-Item -Path $tempOut -Force -ErrorAction SilentlyContinue
            continue
        }

        $finalPath = Join-Path $outputDir $outputName
        try {
            Invoke-WithRetry -Operation "Move output MSI to '$finalPath'" -MaxAttempts 5 -DelaySeconds 2 -Action {
                Move-Item -Path $tempOut -Destination $finalPath -Force
            }
        }
        catch {
            Write-Stage -Tag WARN -Message "Profile '$profileLabel' [$lang] failed: could not move output MSI ($($_.Exception.Message))."
            $buildResults.Add((New-BuildResult -ProfileName $profileLabel -Lang $lang -Status 'Failed' -Reason 'Output move failed'))
            Remove-Item -Path $tempOut -Force -ErrorAction SilentlyContinue
            continue
        }

        $outputHash = (Get-FileHash -Path $finalPath -Algorithm SHA256).Hash
        $manifest = New-BuildManifest -ProfileName $profileName -Lang $lang -LangSelection $langSelection -BaseInfo $baseInfo -PackageInfo $packageInfo -ProfileDef $profileDef -ResolvedVaults $resolvedVaults -NetworkAddress $networkAddress -Config $config -ServerAddressOverride $ServerAddress -OutputHash $outputHash

        $manifestPath = "$finalPath.manifest.json"
        try {
            Invoke-WithRetry -Operation "Write manifest '$manifestPath'" -MaxAttempts 5 -DelaySeconds 2 -Action {
                $manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding utf8
            }
        }
        catch {
            Write-Stage -Tag WARN -Message "Profile '$profileLabel' [$lang] failed: manifest write failed ($($_.Exception.Message))."
            Remove-Item -Path $finalPath -Force -ErrorAction SilentlyContinue
            $buildResults.Add((New-BuildResult -ProfileName $profileLabel -Lang $lang -Status 'Failed' -Reason 'Manifest write failed'))
            continue
        }

        Write-Stage -Tag SUCCESS -Message "Built $outputName"
        $buildResults.Add((New-BuildResult -ProfileName $profileLabel -Lang $lang -Status 'Built' -Path $finalPath))
    }

    if (-not $KeepXml) {
        Remove-Item -Path $tempXml -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Stage -Tag WARN -Message "Kept generated XML for '$profileLabel': $tempXml"
    }
}

Write-Progress -Activity 'Building M-Files client MSIs' -Completed

Write-Host ''
Write-Host '===== RUN SUMMARY ====='
foreach ($r in $buildResults) {
    if ($r.Status -eq 'Built') {
        Write-Stage -Tag SUCCESS -Message "$($r.Profile) [$($r.Lang)] -> $($r.Path)"
    }
    else {
        Write-Stage -Tag ERROR -Message "$($r.Profile) [$($r.Lang)] FAILED: $($r.Reason)"
    }
}

if (@($buildResults | Where-Object { $_.Status -ne 'Built' }).Count -gt 0) {
    exit 1
}
exit 0

}
catch {
    Invoke-Abort "Unexpected error during build: $($_.Exception.Message)."
}
