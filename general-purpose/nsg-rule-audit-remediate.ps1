# ================================
# Azure NSG Rule Audit & Remediation
# ================================
# Purpose:
#   - Audit NSG inbound rules for overly permissive access or non-compliant ports
#   - Optionally remediate by replacing bad rules with safer defaults
#   - Environment-aware: dev vs prod have different allowed ports and safe sources
#   - Summary grouped by environment for clarity
#
# Maintainer Notes:
#   - Adjust $envConfig to change allowed ports or safe source ranges
#   - Parameters at the top can be overridden at runtime (Automation Runbook or manual run)
#   - Audit vs Remediate mode lets you dry-run before applying changes
#   - Grouped summary makes it easier to review changes per environment
# ================================

param(
    [ValidateSet("dev","prod","all")]
    [string]$TargetEnvironment = "",
    [ValidateSet("Audit","Remediate")]
    [string]$Mode = "",
    [string]$SafeSourceDev = "10.0.0.0/24",
    [string]$SafeSourceProd = "10.1.0.0/24"
)

# If running locally and no parameters provided, show interactive prompts
if ([string]::IsNullOrEmpty($TargetEnvironment)) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Azure NSG Checker — Environment Select" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Please choose which environment to run against:" -ForegroundColor White
    Write-Host "   [1] dev" -ForegroundColor Green
    Write-Host "   [2] prod" -ForegroundColor Red
    Write-Host "   [3] all environments" -ForegroundColor Magenta
    Write-Host "==========================================" -ForegroundColor Cyan

    $choice = Read-Host "Enter your choice (1/2/3)"
    switch ($choice) {
        "1" { $TargetEnvironment = "dev" }
        "2" { $TargetEnvironment = "prod" }
        "3" { $TargetEnvironment = "all" }
        default { $TargetEnvironment = "all" }
    }
}

if ([string]::IsNullOrEmpty($Mode)) {
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Azure NSG Checker — Mode Select" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Choose how you want to run the checker:" -ForegroundColor White
    Write-Host "   [1] Audit only (report, no changes)" -ForegroundColor DarkYellow
    Write-Host "   [2] Audit + Remediate (replace non‑compliant rules)" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Cyan

    $modeChoice = Read-Host "Enter your choice (1/2)"
    switch ($modeChoice) {
        "1" { $Mode = "Audit" }
        "2" { $Mode = "Remediate" }
        default { $Mode = "Audit" }
    }
}

Write-Host "Running NSG checker against: $TargetEnvironment in $Mode mode" -ForegroundColor Cyan

# Variables for Azure connection
$subscriptionId = "bb8f3354-1ce0-4efc-b2a7-8506304c5362"
$tenantId       = "a5dea08c-0cc9-40d8-acaa-cacf723e7b9b"

# ================================
# Environment Configs
# ================================
# Define allowed inbound ports and safe source ranges per environment.
# Maintainers: Update these values to reflect your organization's security policy.
$envConfig = @{
    dev = @{
        AllowedPorts = @(22, 3389)   # dev may allow SSH/RDP
        SafeSource   = $SafeSourceDev
    }
    prod = @{
        AllowedPorts = @(443, 1433)  # prod should only allow HTTPS/SQL
        SafeSource   = $SafeSourceProd
    }
}

# ================================
# Connect to Azure
# ================================
# Maintainers: In Automation Runbook, use -Identity for managed identity auth.
Connect-AzAccount -Subscription $subscriptionId -Tenant $tenantId

# ================================
# Initialize Audit Log
# ================================
# We’ll keep separate logs per environment so the summary is grouped clearly.
$envLogs = @{
    dev   = @()
    prod  = @()
    other = @()
}

# Header info
$header = @()
$header += "===== NSG AUDIT ====="
$header += "Run Time: $(Get-Date -Format 'u')"
$header += "Target Environment: $TargetEnvironment"
$header += "Mode: $Mode"
$header += "====================="

# ================================
# Get All NSGs in Subscription
# ================================
$nsgs = Get-AzNetworkSecurityGroup

foreach ($nsg in $nsgs) {
    # Detect environment from RG naming convention
    $env = $null
    if ($nsg.ResourceGroupName -match "-dev") { $env = "dev" }
    elseif ($nsg.ResourceGroupName -match "-prod") { $env = "prod" }
    else { $env = "other" }

    # Skip NSGs if they don't match the target environment
    if ($TargetEnvironment -ne "all" -and $env -ne $TargetEnvironment) {
        continue
    }

    # Load environment-specific config
    $allowedPorts = @()
    $safeSource   = "*"
    if ($env -and $envConfig.ContainsKey($env)) {
        $allowedPorts = $envConfig[$env].AllowedPorts
        $safeSource   = $envConfig[$env].SafeSource
    }

    # ================================
    # Evaluate Each Rule
    # ================================
    foreach ($rule in $nsg.SecurityRules) {
        $isInboundAllow = ($rule.Access -eq "Allow" -and $rule.Direction -eq "Inbound")
        if (-not $isInboundAllow) { continue }

        $ports = @($rule.DestinationPortRange)
        $isPermissiveSource = ($rule.SourceAddressPrefix -eq "*")

        foreach ($port in $ports) {
            $portInt = [int]$port
            $isAllowed = $allowedPorts -contains $portInt

            # Flag non-compliant rules
            if ($isPermissiveSource -or -not $isAllowed) {
                $entry = "[$($nsg.Name)] Rule '$($rule.Name)' non‑compliant: Source=$($rule.SourceAddressPrefix), Port=$port"

                if ($Mode -eq "Remediate") {
                    # ================================
                    # Remediation: Replace with safer default
                    # ================================
                    # Maintainers: Adjust replacement logic if you want different defaults
                    Remove-AzNetworkSecurityRuleConfig -Name $rule.Name -NetworkSecurityGroup $nsg

                    $safeRuleName = "$($rule.Name)-Safe"
                    Add-AzNetworkSecurityRuleConfig -Name $safeRuleName `
                        -NetworkSecurityGroup $nsg `
                        -Protocol $rule.Protocol `
                        -SourceAddressPrefix $safeSource `
                        -SourcePortRange "*" `
                        -DestinationAddressPrefix "*" `
                        -DestinationPortRange $port `
                        -Access "Allow" `
                        -Priority $rule.Priority `
                        -Direction "Inbound"

                    Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
                    $entry += " → replaced with safer default (Source=$safeSource, Port=$port)"
                } else {
                    $entry += " → Audit only — no changes applied"
                }

                # Add entry to environment-specific log
                $envLogs[$env] += $entry
            }
        }
    }
}

# ================================
# Export Grouped Audit Log
# ================================
# Maintainers: Adjust log path or send to Log Analytics for central tracking.
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = ".\nsg-audit-$timestamp.log"

$header | Out-File -FilePath $logFile -Encoding UTF8
foreach ($envKey in $envLogs.Keys) {
    if ($envLogs[$envKey].Count -gt 0) {
        Add-Content -Path $logFile -Value ""
        Add-Content -Path $logFile -Value "===== $envKey ENVIRONMENT ====="
        $envLogs[$envKey] | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

Write-Output "NSG audit complete. Log exported to $logFile"
