#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]
    $devSetup,

    [ValidateSet('AppOnly', 'AppAndDependencies')]
    [string]
    $install,

    [switch]
    $test,

    [string]
    $publishPath = (Join-Path $PSScriptRoot "dist"),

    [string]
    $installPath = (Join-Path $env:ProgramFiles "IIS Administration"),

    [int]
    $testPort = 44326,

    [version]
    $dotnetMinVersion = "2.1.0",

    [version]
    $aspnetMinVersion = $dotnetMinVersion,

    [string]
    $dotnetDownloadPath = "https://download.visualstudio.microsoft.com/download/pr/b9cefae4-7f05-4dea-9fb0-3328aaddb2ee/545e5c4e0eeff6366523209935376002/dotnet-runtime-2.1.9-win-x64.exe",

    [string]
    $aspnetDownloadPath = "https://download.visualstudio.microsoft.com/download/pr/ece6ec5c-4bdb-494b-994b-3ece386e404a/436e42bf7c68b8455953d2d3285c27ed/aspnetcore-runtime-2.1.9-win-x64.exe"
)

$ErrorActionPreference = "Stop"

function BuildHeader {
    "[Build] $(Get-Date -Format yyyyMMddTHHmmssffff):"
}

function ForceResolvePath($path) {
    $path = Resolve-Path $path -ErrorAction SilentlyContinue -ErrorVariable err
    if (-not($path)) {
        $path = $err[0].TargetObject
    }
    return $path
}

function DevEnvSetup() {
    & ([System.IO.Path]::Combine($scriptDir, "Configure-DevEnvironment.ps1")) -ConfigureTestEnvironment
}

function Publish() {
    & ([System.IO.Path]::Combine($scriptDir, "publish", "publish.ps1")) -OutputPath $publishPath -SkipPrompt
    if ($test) {
        Write-Host "$(BuildHeader) Overwriting published config file with test configurations..."
        $testConfig = [System.IO.Path]::Combine($projectRoot, "test", "appsettings.test.json")
        $publishConfig = [System.IO.Path]::Combine($publishPath, "Microsoft.IIS.Administration", "config", "appsettings.json")
        Copy-Item -Path $testconfig -Destination $publishConfig -Force
    }
}

function EnsureIISFeatures() {
    Get-WindowsOptionalFeature -Online `
        | Where-Object {$_.FeatureName -match "IIS-" -and $_.State -eq [Microsoft.Dism.Commands.FeatureState]::Disabled} `
        | ForEach-Object {Enable-WindowsOptionalFeature -Online -FeatureName $_.FeatureName}
}

function InstallTestService() {
    & ([System.IO.Path]::Combine($scriptDir, "setup", "setup.ps1")) Install -DistributablePath $publishPath -Path $installPath -Verbose -Port $testPort
}

function UninistallTestService() {
    & ([System.IO.Path]::Combine($scriptDir, "setup", "setup.ps1")) Uninstall -Path $installPath -ErrorAction SilentlyContinue | Out-Null
}

function CleanUp() {
    try {
        Stop-Service $serviceName
    } catch {
        if ($_.exception -and
            $_.exception -is [Microsoft.PowerShell.Commands.ServiceCommandException]) {
            Write-Host "$serviceName was not installed"
        } else {
            throw
        }
    }
    try {
        UninistallTestService
    } catch {
        Write-Warning $_
        Write-Warning "Failed to uninistall $serviceName"
    }
}

function StartTestService($hold) {
    $group = GetGlobalVariable IIS_ADMIN_API_OWNERS
    $member = & ([System.IO.Path]::Combine($scriptDir, "setup", "security.ps1")) CurrentAdUser

    Write-Host "$(BuildHeader) Sanity tests..."
    $pingEndpoint = "https://localhost:$testPort"
    try {
        Invoke-WebRequest -UseDefaultCredentials -UseBasicParsing $pingEndpoint | Out-Null
    } catch {
        Write-Error "Failed to ping test server $pingEndpoint, did you forget to start it manually?"
        Exit 1
    }

    if ($hold) {
        Read-Host "Press enter to continue..."
    }
}

function StartTest() {
    Write-Host "$(BuildHeader) Functional tests..."
    dotnet test ([System.IO.Path]::Combine($projectRoot, "test", "Microsoft.IIS.Administration.Tests", "Microsoft.IIS.Administration.Tests.csproj"))
}

function VerifyPath($path) {
    if (!(Test-Path $path)) {
        Write-Path "$path does not exist"
        return $false
    }
    return $true
}

function VerifyPrecondition() {
    if (!(VerifyPath [System.IO.Path]::Combine($projectRoot, "test", "appsettings.test.json")) `
        -or !(VerifyPath [System.IO.Path]::Combine($projectRoot, "test", "Microsoft.IIS.Administration.Tests", "test.config.json.template"))) {
        throw "Test configurations do no exist, run .\scripts\Configure-DevEnvironment.ps1 -ConfigureTestEnvironment"
    }
}

function GetGlobalVariable($name) {
    & ([System.IO.Path]::Combine($scriptDir, "setup", "globals.ps1")) $name
}

function InstallFromWeb($product, $url) {
    Write-Warning "Installing missing dependency $product, the dependency will NOT be removed during build cleanup"
    $installer = Join-Path $env:TMP "${product}-installer.exe"
    Invoke-WebRequest $url -OutFile $installer
    & $installer /s
}

########################################################### Main Script ##################################################################
$debug = $PSBoundParameters['debug']
$user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

try {
    $projectRoot = git rev-parse --show-toplevel
} catch {
    Write-Warning "Error looking for project root $_, using script location instead"
    $projectRoot = $PSScriptRoot
}
$scriptDir = Join-Path $projectRoot "scripts"
# publish script only takes full path
$publishPath = ForceResolvePath "$publishPath"
$installPath = ForceResolvePath "$installPath"
$serviceName = GetGlobalVariable DEFAULT_SERVICE_NAME

Write-Host "$(BuildHeader) Starting clean up..."
CleanUp

try {
    if ($devSetup) {
        Write-Host "$(BuildHeader) Dev setup..."
        DevEnvSetup
        Write-Host "$(BuildHeader) Ensure IIS Features..."
        EnsureIISFeatures
    }
    
    Write-Host "$(BuildHeader) Publishing..."
    Publish
    
    if ($install) {
        if ($install -eq "AppAndDependencies") {
            $installDotnet = $true
            $platform = ("x86", "x64")[[Environment]::Is64BitProcess]
            $dotnet = Get-Item -Path "HKLM:SOFTWARE\dotnet\Setup\InstalledVersions\$platform\sharedhost" -ErrorAction SilentlyContinue
            if ($dotnetMinVersion -le $dotnet.GetValue("Version")) {
                $installDotnet = $false
            }
            if ($installDotnet) {
                InstallFromWeb ".NET Core Runtime" $dotnetDownloadPath
            }

            $aspNet = Get-Item -Path "HKLM:SOFTWARE\Microsoft\ASP.NET Core\Shared Framework\v$($aspnetMinVersion.Major).$($aspnetMinVersion.Minor)" -ErrorAction SilentlyContinue
            if (!$aspNet) {
                InstallFromWeb "ASP.NET Shared Framework" $aspnetDownloadPath
            }
        }
        Write-Host "$(BuildHeader) Installing service..."
        InstallTestService
    }
    
    if ($test) {
        Write-Host "$(BuildHeader) Starting service..."
        StartTestService (!$test)

        if ($debug) {
            $proceed = Read-Host "$(BuildHeader) Pausing for debug, continue? (Y/n)..."
            if ($proceed -NotLike "y*") {
                Write-Host "$(BuildHeader) Aborting..."
                Exit 1
            }
        }

        Write-Host "$(BuildHeader) Starting test..."
        StartTest
    }
} catch {
    throw
} finally {
    Write-Host "$(BuildHeader) Final clean up..."
    CleanUp
}

Write-Host "$(BuildHeader) done..."
