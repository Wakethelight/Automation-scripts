# ================================
# Azure NSG Rule Audit & Remediation
# ================================
# Purpose:
#   - Audit NSG inbound rules for overly permissive access or non-compliant ports
#   - Optionally remediate by replacing bad rules with safer defaults
#   - Environment-aware: dev vs prod have different allowed ports and safe sources
#
# Maintainer Notes:
#   - Adjust $envConfig to change allowed ports or safe source ranges
#   - Parameters at the top can be overridden at runtime (Automation Runbook or manual run)
#   - Audit vs Remediate mode lets you dry-run before applying changes
# ================================

param(
    # Which environment to target: dev, prod, or all
    [ValidateSet("dev","prod","all")]
    [string]$TargetEnvironment = "all",

    # Mode: Audit (report only) or Remediate (apply changes)
    [ValidateSet("Audit","Remediate")]
    [string]$Mode = "Audit",

    # Default safe source ranges (can override at runtime)
    [string]$SafeSourceDev = "10.0.0.0/24",
    [string]$SafeSourceProd = "10.1.0.0/24"
)

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
Connect-AzAccount

# ================================
# Initialize Audit Log
# ================================
$logLines = @()
$logLines += "===== NSG AUDIT ====="
$logLines += "Run Time: $(Get-Date -Format 'u')"
$logLines += "Target Environment: $TargetEnvironment"
$logLines += "Mode: $Mode"
$logLines += "====================="

# ================================
# Get All NSGs in Subscription
# ================================
$nsgs = Get-AzNetworkSecurityGroup

foreach ($nsg in $nsgs) {
    # Detect environment from RG naming convention
    $env = $null
    if ($nsg.ResourceGroupName -match "-dev") { $env = "dev" }
    elseif ($nsg.ResourceGroupName -match "-prod") { $env = "prod" }

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
                $logLines += "[$($nsg.Name)] Rule '$($rule.Name)' non‑compliant: Source=$($rule.SourceAddressPrefix), Port=$port"

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
                    $logLines += "[$($nsg.Name)] Rule '$($rule.Name)' replaced with safer default (Source=$safeSource, Port=$port)"
                } else {
                    $logLines += "[$($nsg.Name)] Audit only — no changes applied"
                }
            }
        }
    }
}

# ================================
# Export Audit Log
# ================================
# Maintainers: Adjust log path or send to Log Analytics for central tracking.
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = ".\nsg-audit-$timestamp.log"
$logLines | Out-File -FilePath $logFile -Encoding UTF8

Write-Output "NSG audit complete. Log exported to $logFile"
