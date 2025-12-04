<#
.SYNOPSIS
    Automates DNS zone replication between a primary and secondary DNS server.

.DESCRIPTION
    Prompts for primary/secondary DNS servers and zone name, then:
      1. Configures zone transfer permissions on the primary.
      2. Creates a secondary zone on the secondary server.
      3. Logs all actions to a timestamped file for audit purposes.

.REQUIREMENTS
    - Run with administrative privileges.
    - PowerShell 5.1 or later.
    - DNS Server role installed on both servers.
    - DNS Server PowerShell module available (`Add-WindowsFeature DNS -IncludeManagementTools`).
    - Network connectivity between primary and secondary servers.

.HOW TO RUN
    - Save as `Setup-DnsReplication.ps1`.
    - Run from a management workstation or domain controller with rights to both servers:
        PS> .\Setup-DnsReplication.ps1
    - You will be prompted for server names and zone name.

.NOTES
    - If zones are AD-integrated, replication is automatic and this script is not required.
    - This script is intended for standalone DNS servers or non-AD integrated zones.
    - Each run configures one zone; extend with loops for multiple zones if needed.
    - Logs are written to `.\Logs\DnsReplication_<timestamp>.log`.

.VERSION
    1.1
    Author: Chris
    Date: December 2025
#>

# Create log directory if it doesn't exist
$LogDir = ".\Logs"
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

# Create timestamped log file
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile   = Join-Path $LogDir "DnsReplication_$Timestamp.log"

# Function to log messages
function Write-Log {
    param([string]$Message)
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $Entry = "$Time`t$Message"
    Add-Content -Path $LogFile -Value $Entry
    Write-Host $Message
}

# Prompt for server names
$PrimaryServer   = Read-Host "Enter the hostname or IP of the PRIMARY DNS server"
$SecondaryServer = Read-Host "Enter the hostname or IP of the SECONDARY DNS server"
$ZoneName        = Read-Host "Enter the DNS Zone name (e.g. contoso.com)"

Write-Log "Starting replication setup for zone $ZoneName between $PrimaryServer and $SecondaryServer"

# Step 1: Configure zone transfer on the primary
Invoke-Command -ComputerName $PrimaryServer -ScriptBlock {
    param($ZoneName, $SecondaryServer)
    Set-DnsServerPrimaryZone -Name $ZoneName -SecureSecondaries TransferToSpecificServer -SecondaryServers $SecondaryServer
} -ArgumentList $ZoneName, $SecondaryServer
Write-Log "Primary zone $ZoneName updated to allow transfers to $SecondaryServer"

# Step 2: Create secondary zone on the secondary
Invoke-Command -ComputerName $SecondaryServer -ScriptBlock {
    param($ZoneName, $PrimaryServer)
    Add-DnsServerSecondaryZone -Name $ZoneName -MasterServers $PrimaryServer -ZoneFile "$ZoneName.dns"
} -ArgumentList $ZoneName, $PrimaryServer
Write-Log "Secondary zone $ZoneName created, replicating from $PrimaryServer"

Write-Log "Replication setup complete!"
Write-Host "Replication setup complete! Log saved to $LogFile"
