# ================================
# Service Principal Deletion Script
# ================================

# Variables for Azure connection
$subscriptionId = "bb8f3354-1ce0-4efc-b2a7-8506304c5362"
$tenantId       = "a5dea08c-0cc9-40d8-acaa-cacf723e7b9b"

# Environment config
$envConfig = @{
    dev = @{
        VaultName = "kv-wake-dev"
        VaultResourceGroup = "rg-dev-kv-wake-dev"
    }
    prod = @{
        VaultName = "kv-wake-prod"
        VaultResourceGroup = "rg-prod-kv-wake-prod"
    }
}

# Prompt for environment
$Environment = Read-Host "Enter environment (dev/prod)"
if (-not $envConfig.ContainsKey($Environment)) {
    Write-Error "Invalid environment. Must be 'dev' or 'prod'."
    exit
}
$config = $envConfig[$Environment]

# Prompt for full SP name
$SpName = Read-Host "Enter the full Service Principal name (e.g. sp-aci-dev)"

# Connect
Connect-AzAccount -Subscription $subscriptionId -Tenant $tenantId

# Get SP
$sp = Get-AzADServicePrincipal -DisplayName $SpName -ErrorAction SilentlyContinue
if (-not $sp) {
    Write-Host "Service Principal $SpName does not exist. Exiting cleanly."
    exit
}

# Confirm deletion
$confirm = Read-Host "Are you sure you want to delete Service Principal '$SpName' and its Key Vault secrets? (y/n)"
if ($confirm -ne "y") {
    Write-Host "Deletion cancelled."
    exit
}

# ================================
# Delete Service Principal / Enterprise App
# ================================

# ================================
# Delete Service Principal / Enterprise App
# ================================

try {
    # First check if there is a tenant-owned application object
    $app = Get-AzADApplication -ApplicationId $sp.AppId -ErrorAction SilentlyContinue

    if ($app) {
        # Tenant-owned app registration exists → delete the app (cascades SP)
        Remove-AzADApplication -ObjectId $app.Id -Force
        Write-Host "✅ Deleted Application registration and Service Principal '$SpName'" -ForegroundColor Green
        $deletionType = "Application + SP"
    }
    else {
        try {
            # No app registration → this is likely an external/multi-tenant enterprise app
            Remove-AzADServicePrincipal -ObjectId $sp.Id -Force
            Write-Host "✅ Deleted Enterprise Application (Service Principal) '$SpName'" -ForegroundColor Yellow
            $deletionType = "Enterprise App only"
        } catch {
            Write-Warning "⚠ Deletion of '$SpName' requires manual action in Entra portal (Enterprise Applications → Properties → Delete)."
            $deletionType = "Manual portal deletion required"
        }
    }
}
catch {
    Write-Warning "❌ Unexpected failure while attempting to delete '$SpName'."
    $deletionType = "Failed"
}

# Delete Key Vault secrets
try {
    Remove-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-id" -Force -ErrorAction SilentlyContinue
    Remove-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-tenant-id" -Force -ErrorAction SilentlyContinue
    Remove-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-secret" -Force -ErrorAction SilentlyContinue
    Write-Host "Deleted associated Key Vault secrets from $($config.VaultName)"
} catch {
    Write-Warning "Failed to delete one or more Key Vault secrets"
}


# ================================
# Logging (extended)
# ================================
$logLines = @()
$logLines += "===== DELETION SUMMARY ====="
$logLines += "Requested SP Name: $SpName"
$logLines += "Resolved SP DisplayName: $($sp.DisplayName)"
$logLines += "AppId: $($sp.AppId)"
$logLines += "TenantId: $tenantId"
$logLines += "Environment: $Environment"
$logLines += "Deletion Outcome: $deletionType"
$logLines += "Deletion Time: $(Get-Date -Format 'u')"
$logLines += "============================="

# Write to console
$logLines | ForEach-Object { Write-Host $_ }

# Export to file
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = ".\${SpName}-deletion-$timestamp.log"
$logLines | Out-File -FilePath $logFile -Encoding UTF8

Write-Host "Deletion summary exported to $logFile" -ForegroundColor Green

