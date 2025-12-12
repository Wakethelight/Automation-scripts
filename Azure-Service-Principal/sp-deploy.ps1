# ================================
# Interactive Service Principal Creator (Azure-generated secret)
# ================================
# if you want to only update roles on an existing SP, run with -UpdateOnly
param(
    [switch]$UpdateOnly
)
# Track actions across rotation + role loop
$actionLog = @()

# ================================
# Module Dependency Check (Az umbrella)
# ================================
function Test-AzModule {
    param(
        [Parameter(Mandatory)]
        [string]$MinVersion
    )

    $installed = Get-InstalledModule -Name Az -ErrorAction SilentlyContinue

    if (-not $installed) {
        Write-Error "❌ Missing required module: Az. Install it with: Install-Module Az -Scope CurrentUser"
        return $false
    }
    elseif ([Version]$installed.Version -lt [Version]$MinVersion) {
        Write-Error "⚠️ Az module is outdated (found $($installed.Version), need $MinVersion+). Update with: Update-Module Az"
        return $false
    }
    else {
        Write-Host "✅ Az $($installed.Version) meets requirements." -ForegroundColor Green
        return $true
    }
}


if (-not (Test-AzModule -MinVersion "14.4.0")) {
    $actionLog += "$(Get-Date -Format 'u') - Dependency check failed"
    exit 1
}
$actionLog += "$(Get-Date -Format 'u') - Dependency check passed"



# Variables to track secret rotation
$lastReset = $null
$daysSince = $null
$choice = $null
$expiryDays = $null



# Variables for Azure connection
$subscriptionId = "bb8f3354-1ce0-4efc-b2a7-8506304c5362"
$tenantId       = "a5dea08c-0cc9-40d8-acaa-cacf723e7b9b"

# Environment config
$envConfig = @{
    dev = @{
        VaultName = "kv-wake-dev"
        VaultResourceGroup = "rg-dev-kv-wake-dev"
        AcrName = "acrwakedev01"
    }
    prod = @{
        VaultName = "kv-wake-prod"
        VaultResourceGroup = "rg-prod-kv-wake-prod"
        AcrName = "acrwakeprod01"
    }
}

# Prompt for environment
$Environment = Read-Host "Enter environment (dev/prod)"
if (-not $envConfig.ContainsKey($Environment)) {
    Write-Error "Invalid environment. Must be 'dev' or 'prod'."
    exit
}
$config = $envConfig[$Environment]

# Prompt for SP name prefix
$SpNameprefix = Read-Host "Enter Service Principal name prefix (e.g. sp-aci)"
$SpName = "$SpNameprefix-$Environment"

# Connect
Connect-AzAccount -Subscription $subscriptionId -Tenant $tenantId

# ================================
# Existing SP handling + rotation
# ================================
# Try to get existing SP
$existingSp = Get-AzADServicePrincipal -DisplayName $SpName -ErrorAction SilentlyContinue

if ($existingSp -and $existingSp.DisplayName -ne $SpName) {
    Write-Warning "Mismatch: requested $SpName but found $($existingSp.DisplayName)."
}


if ($null -eq $existingSp) {
    if ($UpdateOnly) {
        Write-Error "UpdateOnly specified, but Service Principal $SpName does not exist."
        exit
    }
    
    $creationExpiryDays = $expiryDays

    #creates new SP
    Write-Host "Service Principal $SpName does not exist. Creating..."
    $sp = New-AzADServicePrincipal -DisplayName $SpName
    $secretValue = $sp.PasswordCredentials.SecretText

    # Prompt for expiry when creating new secret
    $expiryChoice = Read-Host "Do you want to set an expiry on the client secret? (Y/N, default=N)"
    $creationExpiryDays = $null
    if ($expiryChoice.ToUpper() -eq "Y") {
        $creationExpiryDays = Read-Host "Enter number of days until expiry (e.g. 90)"
        if (-not [int]::TryParse($creationExpiryDays, [ref]0)) {
            Write-Warning "Invalid number entered. Skipping expiry."
            $creationExpiryDays = $null
        }
    }

    # Store credentials in Key Vault
    $clientIdSecret = Set-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-id" -SecretValue (ConvertTo-SecureString $sp.AppId -AsPlainText -Force)
    $tenantIdSecret = Set-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-tenant-id" -SecretValue (ConvertTo-SecureString $tenantId -AsPlainText -Force)

    if ($creationExpiryDays) {
        $clientSecret = Set-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-secret" -SecretValue (ConvertTo-SecureString $secretValue -AsPlainText -Force) -Expires (Get-Date).AddDays([int]$creationExpiryDays)
        Write-Host "Stored client secret with expiry of $creationExpiryDays days."
    } else {
        $clientSecret = Set-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-secret" -SecretValue (ConvertTo-SecureString $secretValue -AsPlainText -Force)
        Write-Host "Stored client secret without expiry."
    }

}
else {
    # service principal exists
    Write-Host "Service Principal $SpName already exists."
    $sp = $existingSp

    # ================================
    # Always check secrets rotation if SP exists
    # ================================
    $secret = Get-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-secret" -ErrorAction SilentlyContinue
    $lastReset = $secret.Attributes.Updated
    $rotationDays = 90
    $daysSince = $null
    $rotationExpiryDays = $expiryDays

    if ($lastReset) {
        $daysSince = (New-TimeSpan -Start $lastReset -End (Get-Date)).Days
    }

    # Prompt for rotation
    $promptMsg = "Do you want to force reset the secret"
    if ($lastReset) {
        $promptMsg += " (last reset: $lastReset, $daysSince days ago)"
        if ($daysSince -ge $rotationDays) {
            Write-Host "⚠ Secret is $daysSince days old — rotation recommended" -ForegroundColor Yellow
        }
    }
    $promptMsg += "? (Y/N, default=N): "

    $choice = (Read-Host $promptMsg).ToUpper()

    # Handle rotation choice
    if ($choice -eq "Y") {
        Write-Host "Force reset requested. Resetting secret..."
        $reset = az ad sp credential reset --id $sp.AppId | ConvertFrom-Json
        $clientSecret = $reset.password

        # Prompt for expiry when rotating secret
        $expiryChoice = Read-Host "Do you want to set an expiry on the rotated secret? (Y/N, default=N)"
        $rotationExpiryDays = $null
        if ($expiryChoice.ToUpper() -eq "Y") {
            $rotationExpiryDays = Read-Host "Enter number of days until expiry (e.g. 90)"
            if (-not [int]::TryParse($rotationExpiryDays, [ref]0)) {
                Write-Warning "Invalid number entered. Skipping expiry."
                $rotationExpiryDays = $null
            }
        }

        # Push new secret to Key Vault
        $clientSecretSecure = ConvertTo-SecureString $clientSecret -AsPlainText -Force

        if ($rotationExpiryDays) {
            $clientSecret = Set-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-secret" -SecretValue $clientSecretSecure -Expires (Get-Date).AddDays([int]$rotationExpiryDays)
            Write-Host "Updated secret with expiry of $rotationExpiryDays days."
            $actionLog += "$(Get-Date -Format 'u') - Rotated client secret with expiry $rotationExpiryDays days"
        } else {
            $clientSecret = Set-AzKeyVaultSecret -VaultName $config.VaultName -Name "$($SpName)-client-secret" -SecretValue $clientSecretSecure
            Write-Host "Updated secret without expiry."
            $actionLog += "$(Get-Date -Format 'u') - Rotated client secret without expiry"
        }
    }

    else {
        Write-Host "Keeping existing secret."
        $actionLog += "$(Get-Date -Format 'u') - Skipped secret rotation"
    }
}


# Show existing role assignments
Write-Host "`n===== EXISTING ROLE ASSIGNMENTS ====="
$roles = Get-AzRoleAssignment -ObjectId $sp.Id -Scope "/subscriptions/$subscriptionId"
if ($roles) {
    $roles | Select-Object RoleDefinitionName, Scope | Format-Table
} else {
    Write-Host "No roles currently assigned."
}
Write-Host "======================================"

# Role assignment loop
# Track changes
$addedRoles = @()
$removedRoles = @()


do {
    $action = Read-Host "Enter a role to assign, or type 'remove <RoleName>' to remove (leave blank to finish)"

    if (![string]::IsNullOrWhiteSpace($action)) {
        # Handle removal
        if ($action -like "remove *") {
            $roleToRemove = $action.Substring(7).Trim()
            # Confirm removal
            $confirm = Read-Host "Are you sure you want to remove role '$roleToRemove' from $SpName? (y/n)"
            if ($confirm -eq "y") {
                try {
                    $assignment = Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $roleToRemove -Scope "/subscriptions/$subscriptionId"
                    if ($assignment) {
                        Remove-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $roleToRemove -Scope "/subscriptions/$subscriptionId"
                        Write-Host "Removed role $roleToRemove from $SpName"
                        $removedRoles += $roleToRemove
                        $actionLog += "$(Get-Date -Format 'u') - Removed role $roleToRemove"
                    } else {
                        Write-Host "Role $roleToRemove not currently assigned to $SpName"
                        $actionLog += "$(Get-Date -Format 'u') - Attempted removal of $roleToRemove (not assigned)"
                    }
                } catch {
                    Write-Warning "Failed to remove role $roleToRemove. Check spelling or availability."
                    $actionLog += "$(Get-Date -Format 'u') - Failed removal of $roleToRemove"
                }
            } else {
                Write-Host "Skipped removal of $roleToRemove"
                $actionLog += "$(Get-Date -Format 'u') - Skipped removal of $roleToRemove"
            }
        }
        else {
            $role = $action
            try {
                # Assign role
                if (-not (Get-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $role -Scope "/subscriptions/$subscriptionId")) {
                    New-AzRoleAssignment -ApplicationId $sp.AppId -RoleDefinitionName $role -Scope "/subscriptions/$subscriptionId"
                    Write-Host "Assigned role $role to $SpName"
                    $addedRoles += $role
                    $actionLog += "$(Get-Date -Format 'u') - Assigned role $role"
                } else {
                    # Already assigned
                    Write-Host "Role $role already assigned to $SpName"
                    $actionLog += "$(Get-Date -Format 'u') - Attempted assignment of $role (already assigned)"
                }
            } catch {
                Write-Warning "Failed to assign role $role. Check spelling or availability."
                $actionLog += "$(Get-Date -Format 'u') - Failed assignment of $role"
            }
        }

        # Show current roles after every change
        Write-Host "`n===== CURRENT ROLE ASSIGNMENTS ====="
        $roles = Get-AzRoleAssignment -ObjectId $sp.Id -Scope "/subscriptions/$subscriptionId"
        if ($roles) {
            $roles | Select-Object RoleDefinitionName, Scope | Format-Table
        } else {
            Write-Host "No roles currently assigned."
        }
        Write-Host "====================================`n"
    }
} while (![string]::IsNullOrWhiteSpace($action))

# ================================
# Summary Report
# ================================
$summaryLines = @()
$summaryLines += "===== SUMMARY ====="
$summaryLines += "Requested SP Name: $SpName"
$summaryLines += "Resolved SP DisplayName: $($sp.DisplayName)"
$summaryLines += "Service Principal: $SpName"
$summaryLines += "AppId: $($sp.AppId)"
$summaryLines += "TenantId: $tenantId"
$summaryLines += "Key Vault: $($config.VaultName)"
$summaryLines += "Existing Roles (final state): $($roles.RoleDefinitionName -join ', ')"
$summaryLines += "New Roles Assigned: $($addedRoles -join ', ')"
$summaryLines += "Roles Removed: $($removedRoles -join ', ')"
$summaryLines += "Secret Rotation:"
if ($lastReset) {
    $summaryLines += " - Last reset (from KV metadata): $lastReset"
    if ($daysSince -ge 90) {
        $summaryLines += " - ⚠ Secret is $daysSince days old — rotation recommended"
        Write-Host "⚠ Secret is $daysSince days old — rotation recommended" -ForegroundColor Yellow
    }
}

# User choice on rotation
if ($choice -eq "Y") {
    $summaryLines += " - Secret rotated during this run at $(Get-Date -Format 'u')"
    Write-Host "Secret rotated during this run" -ForegroundColor Green
} elseif ($choice -eq "N") {
    $summaryLines += " - Secret not rotated this run"
    Write-Host "Secret not rotated this run" -ForegroundColor Cyan
} else {
    $summaryLines += " - No rotation prompt executed"
}

# Secret Exiration details
$summaryLines += "Secret Expiry:"
if ($creationExpiryDays) {
    $summaryLines += " - Creation expiry set to $creationExpiryDays days"
} else {
    $summaryLines += " - Creation secret stored without expiry"
}
if ($rotationExpiryDays) {
    $summaryLines += " - Rotation expiry set to $rotationExpiryDays days"
} else {
    $summaryLines += " - Rotation secret stored without expiry"
}

# Key Vault secret locations
if (-not $UpdateOnly) {
    $summaryLines += "Secrets stored at:"
    $summaryLines += " - ClientId: $($clientIdSecret.Id)"
    $summaryLines += " - TenantId: $($tenantIdSecret.Id)"
    $summaryLines += " - ClientSecret: $($clientSecret.Id)"
}

$summaryLines += "Action Log:"
$summaryLines += $actionLog
$summaryLines += "===================="
# Write summary to console
$summaryLines | ForEach-Object { Write-Host $_ }

# Export to file
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$summaryFile = ".\${SpName}-summary-$timestamp.log"
$summaryLines | Out-File -FilePath $summaryFile -Encoding UTF8

Write-Host "Summary exported to $summaryFile" -ForegroundColor Green
