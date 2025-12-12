# ================================
# Azure Resource Tagging Audit & Remediation
# ================================
# Purpose:
#   - Audit Azure resources for missing or inconsistent tags
#   - Auto-detect Environment and App tags from naming conventions
#   - Apply Team tags from regex-based lookup table
#   - Optionally remediate by applying missing tags
#   - Summary grouped by environment for clarity
#
# Maintainer Notes:
#   - Adjust $envConfig to define baseline tags per environment
#   - Update $teamLookup with regex patterns for team ownership
#   - Parameters at the top can be overridden at runtime (Automation Runbook or manual run)
#   - Audit vs Remediate mode lets you dry-run before applying changes
# ================================

param(
    [ValidateSet("dev","prod","all")]
    [string]$TargetEnvironment = "",
    [ValidateSet("Audit","Remediate")]
    [string]$Mode = ""
)

# Variables for Azure connection
$subscriptionId = "bb8f3354-1ce0-4efc-b2a7-8506304c5362"
$tenantId       = "a5dea08c-0cc9-40d8-acaa-cacf723e7b9b"



# If running locally and no parameters provided, show interactive prompts
if ([string]::IsNullOrEmpty($TargetEnvironment)) {
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "   Azure Tag Checker — Environment Select" -ForegroundColor Yellow
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
    Write-Host "   Azure Tag Checker — Mode Select" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Cyan
    Write-Host "Choose how you want to run the checker:" -ForegroundColor White
    Write-Host "   [1] Audit only (report, no changes)" -ForegroundColor DarkYellow
    Write-Host "   [2] Audit + Remediate (apply missing tags)" -ForegroundColor Green
    Write-Host "==========================================" -ForegroundColor Cyan

    $modeChoice = Read-Host "Enter your choice (1/2)"
    switch ($modeChoice) {
        "1" { $Mode = "Audit" }
        "2" { $Mode = "Remediate" }
        default { $Mode = "Audit" }
    }
}

Write-Host "Running tag checker against: $TargetEnvironment in $Mode mode" -ForegroundColor Cyan


# ================================
# Environment Configs
# ================================
# Define baseline tags per environment.
# Maintainers: Update these values to reflect your organization's tagging standards.

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

# ================================
# Team Lookup Table (Regex Patterns)
# ================================
# Maintainers: Add or adjust regex patterns to map RGs to teams.
$teamLookup = @(
    @{ Pattern = "^rg-aci";     Team = "ContainerTeam" }
    @{ Pattern = "^rg-dns";     Team = "NetworkTeam" }
    @{ Pattern = "^rg-storage"; Team = "StorageTeam" }
    @{ Pattern = "^rg-app\d+";  Team = "AppTeam" }   # matches rg-app1, rg-app2, rg-app99, etc.
    @{ Pattern = "^rg-.*-data"; Team = "DataTeam" }  # matches rg-anything-data
)

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
$header += "===== TAGGING AUDIT ====="
$header += "Run Time: $(Get-Date -Format 'u')"
$header += "Target Environment: $TargetEnvironment"
$header += "Mode: $Mode"
$header += "========================="

# ================================
# Get All Resources in Subscription
# ================================
$resources = Get-AzResource

foreach ($res in $resources) {
    $tags = $res.Tags
    if (-not $tags) { $tags = @{} }
    $changed = $false

    # Detect environment from RG or resource name
    $env = $null
    if ($res.ResourceGroupName -match "-dev") { $env = "dev" }
    elseif ($res.ResourceGroupName -match "-prod") { $env = "prod" }
    elseif ($res.Name -match "-dev") { $env = "dev" }
    elseif ($res.Name -match "-prod") { $env = "prod" }
    else { $env = "other" }

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
                $entry = "[$($res.Name)] Would add $($kvp.Key)=$($kvp.Value)"
                if ($Mode -eq "Remediate") {
                    Set-AzResource -ResourceId $res.ResourceId -Tag $tags -Force
                    $entry += " → applied"
                } else {
                    $entry += " → Audit only"
                }
                $envLogs[$env] += $entry
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
        $entry = "[$($res.Name)] Would add App=$app"
        if ($Mode -eq "Remediate") {
            Set-AzResource -ResourceId $res.ResourceId -Tag $tags -Force
            $entry += " → applied"
        } else {
            $entry += " → Audit only"
        }
        $envLogs[$env] += $entry
    }

    # Apply Team tag from regex lookup
    if (-not $tags.ContainsKey("Team")) {
        foreach ($entryPattern in $teamLookup) {
            if ($res.ResourceGroupName -match $entryPattern.Pattern) {
                $tags["Team"] = $entryPattern.Team
                $changed = $true
                $entry = "[$($res.Name)] Would add Team=$($entryPattern.Team)"
                if ($Mode -eq "Remediate") {
                    Set-AzResource -ResourceId $res.ResourceId -Tag $tags -Force
                    $entry += " → applied"
                } else {
                    $entry += " → Audit only"
                }
                $envLogs[$env] += $entry
                break
            }
        }
    }
}

# ================================
# Export Grouped Audit Log
# ================================
# Maintainers: Adjust log path or send to Log Analytics for central tracking.
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$logFile = ".\tagging-audit-$timestamp.log"

$header | Out-File -FilePath $logFile -Encoding UTF8
foreach ($envKey in $envLogs.Keys) {
    if ($envLogs[$envKey].Count -gt 0) {
        Add-Content -Path $logFile -Value ""
        Add-Content -Path $logFile -Value "===== $envKey ENVIRONMENT ====="
        $envLogs[$envKey] | Out-File -FilePath $logFile -Append -Encoding UTF8
    }
}

Write-Output "Tagging audit complete. Log exported to $logFile"
