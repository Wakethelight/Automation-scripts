function Test-ModuleDependencies {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Requirements
    )

    foreach ($module in $Requirements.Keys) {
        $minVersion = [Version]$Requirements[$module]
        $installed  = Get-InstalledModule -Name $module -ErrorAction SilentlyContinue

        if (-not $installed) {
            Write-Error "Missing required module: $module. Install it with: Install-Module $module -Scope CurrentUser"
            return $false
        }
        elseif ([Version]$installed.Version -lt $minVersion) {
            Write-Error "Module $module is outdated (found $($installed.Version), need $minVersion+). Update with: Update-Module $module"
            return $false
        }
        else {
            Write-Host "✅ $module $($installed.Version) meets requirements."
        }
    }
    return $true
}

# Example usage at script start:
$Requirements = @{
    "Az.Accounts"   = "2.15.0"
    "Az.Resources"  = "6.0.0"
    "Az.KeyVault"   = "4.9.0"
    "Az.RoleAssignment" = "2.11.0"
}

if (-not (Test-ModuleDependencies -Requirements $Requirements)) {
    exit 1
}
