# ================================
# Azure Resource Tagging Audit & Remediation
# ================================

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

# ==========================================
# Interactive prompts
# ==========================================

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
    default {
        Write-Warning "Invalid choice. Defaulting to 'all'."
        $TargetEnvironment = "all"
    }
}
Write-Host "Running tag checker against: $TargetEnvironment" -ForegroundColor Cyan
Write-Host ""

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   Azure Tag Checker — Mode Select" -ForegroundColor Yellow
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "Choose how you want to run the checker:" -ForegroundColor White
Write-Host "   [1] Audit only (report, no changes)" -ForegroundColor DarkYellow
Write-Host "   [2] Audit + Remediate (apply missing tags)" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Cyan

$modeChoice = Read-Host "Enter your choice (1/2)"
switch ($modeChoice) {
    "1" { $Remediate = $false }
    "2" { $Remediate = $true }
    default {
        Write-Warning "Invalid choice. Defaulting to Audit only."
        $Remediate = $false
    }
}
Write-Host "Mode selected: $(if ($Remediate) { 'Audit + Remediate' } else { 'Audit only' })" -ForegroundColor Cyan
Write-Host ""

# ==========================================
# Connect and run
# ==========================================

Connect-AzAccount -Subscription $subscriptionId -Tenant $tenantId
$resources = Get-AzResource

# Log changes
$logLines = @()
$logLines += "===== TAGGING AUDIT ====="
$logLines += "Subscription: $subscriptionId"
$logLines += "Run Time: $(Get-Date -Format 'u')"
$logLines += "Target Environment: $TargetEnvironment"
$logLines += "Mode: $(if ($Remediate) { 'Audit + Remediate' } else { 'Audit only' })"
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
        if ($Remediate) {
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

Write-Host "Tagging audit complete. Log exported to $logFile" -ForegroundColor Green
