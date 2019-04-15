param(
    [string]
    $OutputPath,

    [switch]
    $ConfigDebug
)

$applicationName = "Microsoft.IIS.Administration"
$applicationPath = Join-Path $OutputPath $applicationName
$outputPluginsFolder = Join-Path $applicationPath "plugins"

# Remove all unnecessary files
if (-not($ConfigDebug)) {
    Write-Host "Removing pdb files from output path..."
	Get-ChildItem $OutputPath *.pdb -Recurse | Remove-Item -Force
}

# Remove non-windows runtime dlls
$runtimeDirs = Get-ChildItem -Recurse $OutputPath runtimes
foreach ($runtimeDir in $runtimeDirs) {
    Get-ChildItem $runtimeDir.FullName | Where-Object { $_.name -ne "win" } | ForEach-Object { Remove-Item $_.FullName -Force -Recurse }
}

# Remove non dlls from plugins
Get-ChildItem $outputPluginsFolder -File | Where-Object {-not($_.Name -match ".dll$")} | Remove-Item -Force
Remove-Item (Join-Path $outputPluginsFolder Bundle.dll) -Force

$mainDlls = Get-ChildItem $applicationPath *.dll
$mainDlls += $(Get-ChildItem -Recurse $applicationPath/runtimes/*.dll)
$pluginDlls = Get-ChildItem -Recurse $outputPluginsFolder *.dll

# Ensure no intersection between plugin dlls and application dlls
Write-Host "Removing redundant dlls in plugin directory"
foreach ($pluginDll in $pluginDlls) {
	foreach ($mainDll in $mainDlls) {
		if ($mainDll.Name -eq $pluginDll.Name) {
			Remove-Item $pluginDll.FullName -Force
			break
		}
	}
}
