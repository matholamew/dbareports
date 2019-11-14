<#
.SYNOPSIS  
     This Script will check all of the instances in the InstanceList and gather SQL Configuration Info and save to the Info.SQLInfo table

.DESCRIPTION 
     This Script will check all of the instances in the InstanceList and gather SQL Configuration Info and save to the Info.SQLInfo table

.NOTES 
dbareports PowerShell module (https://dbareports.io, SQLDBAWithABeard.com)
Copyright (C) 2016 Rob Sewell

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.

#>
[CmdletBinding()]
Param (
	[Alias("ServerInstance", "SqlInstance")]
	[object]$SqlServer = "--installserver--",
	[object]$SqlCredential,
	[string]$InstallDatabase = "--installdb--",
	[string]$LogFileFolder = "--logdir--"
)

BEGIN
{
	# Add date created?
	
	# Load up shared functions
	$currentdir = Split-Path -Parent $MyInvocation.MyCommand.Definition
	. "$currentdir\shared.ps1"
	. "$currentdir\Write-Log.ps1"
	# Create Log File 
	$Date = Get-Date -Format yyyyMMdd_HHmmss
	$LogFilePath = $LogFileFolder + '\' + 'dbareports_SQLInfo_' + $Date + '.txt'
	try
	{
		Write-Log -path $LogFilePath -message "SQLInfo Job started" -level info
	}
	catch
	{
		Write-error "Failed to create Log File at $LogFilePath"
	}

	# Specify table name that we'll be inserting into
	$table = "info.SQLInfo"
	$schema = $table.Split(".")[0]
	$tablename = $table.Split(".")[1]
	
	# Connect to dbareports server
	try
	{
		Write-Log -path $LogFilePath -message "Connecting to $sqlserver" -level info
		$sourceserver = Connect-SqlServer -SqlServer $sqlserver -SqlCredential $SqlCredential -ErrorAction Stop 
	}
	catch
	{
		Write-Log -path $LogFilePath -message "Failed to connect to $sqlserver - $_" -level Error
	}

	# Get columns automatically from the table on the SQL Server
	# and creates the necessary $script:datatable with it
	try
	{
		Write-Log -path $LogFilePath -message "Intitialising Datatable" -level info
		Initialize-DataTable -ErrorAction Stop 
	}
	catch
	{
		Write-Log -path $LogFilePath -message "Failed to initialise Data Table - $_" -level Error
	}
}

PROCESS
{
	$DateChecked = Get-Date
	try
	{
		Write-Log -path $LogFilePath -message "Getting Instances from $sqlserver" -level info
		$sqlservers = Get-Instances
	}
	catch
	{
		Write-Log -path $LogFilePath -message " Failed to get instances - $_" -level Error
		break
	}
	
	# Get list of all servers already in the database
	try
	{
		Write-Log -path $LogFilePath -message "Getting a list of servers from the dbareports database" -level info
		$sql = "SELECT ServerName, SQLInfoID, InstanceID, DateAdded FROM $table"
		$table = $sourceserver.Databases[$InstallDatabase].ExecuteWithResults($sql).Tables[0]
		Write-Log -path $LogFilePath -message "Got the list of servers from the dbareports database" -level info
	}
	catch
	{
		Write-Log -path $LogFilePath -message "Can't get server list from $InstallDatabase on $($sourceserver.name). - $_" -level Error
	}
	
	foreach ($sqlserver in $sqlservers)
	{
		$sqlservername = $sqlserver.ServerName
		$InstanceName = $sqlserver.InstanceName
		$InstanceId = $sqlserver.InstanceId
		if ($InstanceName -eq 'MSSQLServer')
		{
			$Connection = $sqlservername
		}
		else
		{
			$Connection = "$sqlservername\$InstanceName"
		}
		
		# Connect to Instance
		try
		{
			$server = Connect-SqlServer -SqlServer $Connection
			Write-Log -path $LogFilePath -message "Connecting to $Connection" -level info
		}
		catch
		{
			Write-Log -path $LogFilePath -message "Failed to connect to $Connection - $_" -level Warn
			continue
		}

		$row = $table | Where-Object { $_.Servername -eq $sqlservername -and $_.InstanceId -eq $InstanceID }
		$key = $row.SQLInfoID
		
		if ($key.count -gt 0)
		{
			$update = $true
			$DateAdded = $row.DateAdded
		}
		else
		{
			$update = $false
			$DateAdded = Get-Date
		}
		
		# Pre-process
		$VersionMajor = $server.VersionMajor
		$VersionMinor = $server.VersionMinor
		if ($VersionMajor -eq 8)
		{ $Version = 'SQL 2000' }
		if ($VersionMajor -eq 9)
		{ $Version = 'SQL 2005' }
		if ($VersionMajor -eq 10 -and $VersionMinor -eq 0)
		{ $Version = 'SQL 2008' }
		if ($VersionMajor -eq 10 -and $VersionMinor -eq 50)
		{ $Version = 'SQL 2008 R2' }
		if ($VersionMajor -eq 11)
		{ $Version = 'SQL 2012' }
		if ($VersionMajor -eq 12)
		{ $Version = 'SQL 2014' }
		if ($VersionMajor -eq 13)
		{ $Version = 'SQL 2016' }
		if ($VersionMajor -eq 14)
		{ $Version = 'SQL 2017' }
		if ($VersionMajor -eq 15)
		{ $Version = 'SQL 2019' }
		
		if ($server.IsHadrEnabled -eq $True)
		{
			$IsHADREnabled = $True
			$AGs = $server.AvailabilityGroups | Select-Object Name -ExpandProperty Name | Out-String
			$Expression = @{ Name = 'ListenerPort'; Expression = { $_.Name + ',' + $_.PortNumber } }
			$AGListener = $server.AvailabilityGroups.AvailabilityGroupListeners | Select-Object $Expression | Select-Object ListenerPort -ExpandProperty ListenerPort
		}
		else
		{
			$IsHADREnabled = $false
			$AGs = 'None'
			$AGListener = 'None'
		}
		
		if ($server.version.Major -eq 8) # Check for SQL 2000 boxes
		{
			$HADREndpointPort = '0'
		}
		else
		{
			$HADREndpointPort = ($server.Endpoints | Where-Object{ $_.EndpointType -eq 'DatabaseMirroring' }).Protocol.Tcp.ListenerPort
		}
		if (!$HADREndpointPort)
		{
			$HADREndpointPort = '0'
		}
		
		try
		{
			$null = $datatable.rows.Add(
			$key,
			$(Get-Date),
			$DateAdded,
			$sqlServerName,
			$InstanceName,
			$server.VersionString,
			$Version,
			$server.ProductLevel,
			$server.Edition,
			$server.ServerType,
			$server.Collation,
			$IsHADREnabled,
			$server.ServiceAccount,
			$server.ServiceName,
			$server.ServiceStartMode,
			$server.BackupDirectory,
			$server.BrowserServiceAccount,
			$server.BrowserStartMode,
			$server.IsClustered,
			$server.ClusterName,
			$server.ClusterQuorumState,
			$server.ClusterQuorumType,
			$server.Configuration.C2AuditMode.RunValue,
			$server.Configuration.CostThresholdForParallelism.RunValue,
			$server.Configuration.MaxDegreeOfParallelism.RunValue,
			$server.Configuration.DatabaseMailEnabled.RunValue,
			$server.Configuration.DefaultBackupCompression.RunValue,
			$server.Configuration.FillFactor.RunValue,
			$server.Configuration.MaxServerMemory.RunValue,
			$server.Configuration.MinServerMemory.RunValue,
			$server.Configuration.RemoteDacConnectionsEnabled.RunValue,
			$server.Configuration.XPCmdShellEnabled.RunValue,
			$server.Configuration.CommonCriteriaComplianceEnabled.RunValue,
			$server.DefaultFile,
			$server.DefaultLog,
			$server.HADREndpointPort,
			$server.ErrorLogPath,
			$server.InstallDataDirectory,
			$server.InstallSharedDirectory,
			$server.IsCaseSensitive,
			$server.IsFullTextInstalled,
			$server.LinkedServers,
			$server.LoginMode,
			$server.MasterDBLogPath,
			$server.MasterDBPath,
			$server.NamedPipesEnabled,
			$server.Configuration.OptimizeAdhocWorkloads.RunValue,
			$InstanceID,
			$AGListener,
			$AGs,
			$AGListenerPort,
			$AGListenerIPs,
            $Server.JobServer.ServiceAccount,
            $Server.JobServer.ServiceStartMode,
			$Update)
		}
		catch
		{
			Write-Log -path $LogFilePath -message "Failed to add Job to datatable - $_" -level Error
			Write-Log -path $LogFilePath -message "Data = $Key,
			$(Get-Date),
			$DateAdded,
			$sqlServerName,
			$InstanceName,
			$server.VersionString,
			$Version,
			$server.ProductLevel,
			$server.Edition,
			$server.ServerType,
			$server.Collation,
			$IsHADREnabled,
			$server.ServiceAccount,
			$server.ServiceName,
			$server.ServiceStartMode,
			$server.BackupDirectory,
			$server.BrowserServiceAccount,
			$server.BrowserStartMode,
			$server.IsClustered,
			$server.ClusterName,
			$server.ClusterQuorumState,
			$server.ClusterQuorumType,
			$server.Configuration.C2AuditMode.RunValue,
			$server.Configuration.CostThresholdForParallelism.RunValue,
			$server.Configuration.MaxDegreeOfParallelism.RunValue,
			$server.Configuration.DatabaseMailEnabled.RunValue,
			$server.Configuration.DefaultBackupCompression.RunValue,
			$server.Configuration.FillFactor.RunValue,
			$server.Configuration.MaxServerMemory.RunValue,
			$server.Configuration.MinServerMemory.RunValue,
			$server.Configuration.RemoteDacConnectionsEnabled.RunValue,
			$server.Configuration.XPCmdShellEnabled.RunValue,
			$server.Configuration.CommonCriteriaComplianceEnabled.RunValue,
			$server.DefaultFile,
			$server.DefaultLog,
			$server.HADREndpointPort,
			$server.ErrorLogPath,
			$server.InstallDataDirectory,
			$server.InstallSharedDirectory,
			$server.IsCaseSensitive,
			$server.IsFullTextInstalled,
			$server.LinkedServers,
			$server.LoginMode,
			$server.MasterDBLogPath,
			$server.MasterDBPath,
			$server.NamedPipesEnabled,
			$server.Configuration.OptimizeAdhocWorkloads.RunValue,
			$InstanceID,
			$AGListener,
			$AGs,
			$AGListenerPort,
			$AGListenerIPs,
            $Server.JobServer.ServiceAccount,
            $Server.JobServer.ServiceStartMode,
			$Update" -level Warn
			continue
		}
	}
	
	
	$rowcount = $datatable.Rows.Count
	
	if ($rowcount -eq 0)
	{
		Write-Log -path $LogFilePath -message "No rows returned. No update required." -level info
		continue
	}
	
	try
	{
		Write-Log -path $LogFilePath -message "Attempting Import of $rowcount row(s)" -level info
		Write-Tvp -ErrorAction Stop 
		Write-Log -path $LogFilePath -message "Successfully Imported $rowcount row(s) of SQL Info into the $InstallDatabase on $($sourceserver.name)" -level info
	}
	catch
	{
		Write-Log -path $LogFilePath -message "Bulk insert failed - $_" -level Error
	}
}

END
{
	Write-Log -path $LogFilePath -message "SQLInfo Finished"
	$sourceserver.ConnectionContext.Disconnect()
}
