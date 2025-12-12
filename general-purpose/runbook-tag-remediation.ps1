# ================================
# Azure Resource Tagging Audit & Remediation (Runbook Version)
# ================================

param(
    [ValidateSet("dev","prod","all")]
    [string]$TargetEnvironment = "all",

    [ValidateSet("Audit","Remediate")]
    [string]$Mode = "Audit"
)

# Variables for Azure connection
$subscriptionId = "bb8f3354-1ce0-4efc-b2a7-8506304c5362"
$tenantId       = "a5dea08c-0cc9-40d8-acaa-cacf723e7b9b"

# Environment configs (baseline tags per environment)
$envConfig = @{
    dev = @{
        RequiredTags = @{
            Environment = "dev"
            CostCenter  = "R&D"
            Owner       = "DevOpsTeam"
        }
    }
    prod = @{
        RequiredTags = @{
            Environment = "prod"
            CostCenter  = "Operations"
            Owner       = "ProdOpsTeam"
        }
    }
}

# Team lookup table (regex patterns → Team names)
$teamLookup = @(
    @{ Pattern = "^rg-aci";     Team = "ContainerTeam" }
    @{ Pattern = "^rg-dns";     Team = "NetworkTeam" }
    @{ Pattern = "^rg-storage"; Team = "StorageTeam" }
    @{ Pattern = "^rg-app\d+";  Team = "AppTeam" }   # matches rg-app1, rg-app2, rg-app99, etc.
    @{ Pattern = "^rg-.*-data"; Team = "DataTeam" }  # matches rg-anything-data
)

# Connect using Automation Account's managed identity
Connect-AzAccount -Identity -Subscription $subscriptionId -Tenant $tenantId

# Get all resources
$resources = Get-AzResource

# Log changes
$logLines = @()
$logLines += "===== TAGGING AUDIT ====="
$logLines += "Subscription: $subscriptionId"
$logLines += "Run Time: $(Get-Date -Format 'u')"
$logLines += "Target Environment: $TargetEnvironment"
$logLines += "Mode: $Mode"
$logLines += "========================="

foreach ($res in $resources) {
    $tags = $res.Tags
    if (-not $tags) { $tags = @{} }
    $changed = $false

    # Detect environment from RG or name
    $env = $null
    if ($res.ResourceGroupName -match "-dev") { $env = "dev" }
    elseif ($res.ResourceGroupName -match "-prod") { $env = "prod" }
    elseif ($res.Name -match "-dev") { $env = "dev" }
    elseif ($res.Name -match "-prod") { $env = "prod" }

    # Skip if environment doesn't match TargetEnvironment
    if ($TargetEnvironment -ne "all" -and $env -ne $TargetEnvironment) {
        continue
    }

    # Apply environment-specific required tags
    if ($env -and $envConfig.ContainsKey($env)) {
        foreach ($kvp in $envConfig[$env].RequiredTags.GetEnumerator()) {
            if (-not $tags.ContainsKey($kvp.Key)) {
                $tags[$kvp.Key] = $kvp.Value
                $changed = $true
                $logLines += "[$($res.Name)] Would add $($kvp.Key)=$($kvp.Value)"
            }
        }
    }

    # Detect App from RG naming convention (rg-appname-dev)
    $app = $null
    if ($res.ResourceGroupName -match "^rg-([^-]+)-") {
        $app = $matches[1]
    }
    if (-not $tags.ContainsKey("App") -and $app) {
        $tags["App"] = $app
        $changed = $true
        $logLines += "[$($res.Name)] Would add App=$app"
    }

    # Apply Team tag from regex lookup
    if (-not $tags.ContainsKey("Team")) {
        foreach ($entry in $teamLookup) {
            if ($res.ResourceGroupName -match $entry.Pattern) {
                $tags["Team"] = $entry.Team
                $changed = $true
                $logLines += "[$($res.Name)] Would add Team=$($entry.Team)"
                break
            }
        }
    }

    # Apply updated tags
    if ($changed) {
        if ($Mode -eq "Remediate") {
            Set-AzResource -ResourceId $res.ResourceId -Tag $tags -Force
            $logLines += "[$($res.Name)] Changes applied"
        } else {
            $logLines += "[$($res.Name)] Audit only — no changes applied"
        }
    }
}

# Export log
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = ".\tagging-audit-$timestamp.log"
$logLines | Out-File -FilePath $logFile -Encoding UTF8

Write-Output "Tagging audit complete. Log exported to $logFile"
