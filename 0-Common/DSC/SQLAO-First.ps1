Configuration DemoSQL
{
	param
	(
       	[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()]       [string] $domain,
                                                                      [string] $AppName,
										                              [string] $SampleAppLocation,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $LocalUserAccount,
		[Parameter(Mandatory=$true)] [ValidateNotNullorEmpty()] [PSCredential] $DomainUserAccount,
		

        [String]$SQLServiceAccount  = "PuppyDog",
        [String]$DomainNetbiosName  = (Get-NetBIOSName -DomainName $domain),
        [UInt32]$DatabaseEnginePort = 1433,
		[Int]$RetryCount            = 20,
        [Int]$RetryIntervalSec      = 30
    )
	
	Import-DscResource -Module xStorage
	Import-DscResource -Module cDisk

	Import-DscResource -Module xComputerManagement
	Import-DscResource -Module xActiveDirectory

	Import-DscResource -Module xNetworking
	Import-DscResource -Module xSQL



#	Import-DscResource -Module xPSDesiredStateConfiguration
#	Import-DscResource -Module xDatabase
#	Import-DscResource -Module xFailoverCluster

    [System.Management.Automation.PSCredential]$SQLServiceCreds = New-Object System.Management.Automation.PSCredential ("${DomainNetbiosName}\$SQLServiceAccount", $DomainUserAccount.Password)
	
	$bacpac = "FabrikamFiber.bacpac"
	$storacct = "https://clijson.blob.core.windows.net/common-stageartifacts/"
	$stagingFolder  = "C:\Packages"
	
	WaitForSqlSetup

	Node localhost
	{
		LocalConfigurationManager
		{
			RebootNodeIfNeeded = $false
		}

		xWaitforDisk Disk2                               # Make Sure Disk is Ready
		{
			DiskNumber       = 2
			RetryIntervalSec = $RetryIntervalSec
			RetryCount       = $RetryCount
		}

		cDiskNoRestart DataDisk                          # Prepare drive
        {
            DiskNumber = 2
            DriveLetter = "F"
        }

		WindowsFeature FC
		{
			Name   = "Failover-Clustering"
			Ensure = "Present"
		}

		WindowsFeature FCPS
		{
			Name   = "RSAT-Clustering"
			Ensure = "Present"
			IncludeAllSubFeature = $true
		}

		WindowsFeature ADPS
		{
			Name   = "RSAT-AD-PowerShell"
			Ensure = "Present"
		}

		xComputer DomainJoin                              # Join the Domain
		{
			Name       = $env:COMPUTERNAME
			DomainName = $domain
			Credential = $DomainUserAccount
		}






        xFirewall DatabaseEngineFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Database-Engine-TCP-In"
            DisplayName = "SQL Server Database Engine (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Engine."
            DisplayGroup = "SQL Server"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = $DatabaseEnginePort -as [String]
            Ensure = "Present"
        }

        xFirewall DatabaseMirroringFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Database-Mirroring-TCP-In"
            DisplayName = "SQL Server Database Mirroring (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Database Mirroring."
            DisplayGroup = "SQL Server"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = "5022"
            Ensure = "Present"
        }

        xFirewall ListenerFirewallRule
        {
            Direction = "Inbound"
            Name = "SQL-Server-Availability-Group-Listener-TCP-In"
            DisplayName = "SQL Server Availability Group Listener (TCP-In)"
            Description = "Inbound rule for SQL Server to allow TCP traffic for the Availability Group listener."
            DisplayGroup = "SQL Server"
            State = "Enabled"
            Access = "Allow"
            Protocol = "TCP"
            LocalPort = "59999"
            Ensure = "Present"
        }





        xADUser CreateSqlServerServiceAccount                            # create a sevice account for SQL
        {
            DomainAdministratorCredential = $DomainUserAccount
            DomainName                    = $domain
            UserName                      = $SQLServiceAccount
            Password                      = $SQLServiceCreds
            Ensure                        = "Present"
        }

        xSqlLogin AddSqlServerServiceAccountToSysadminServerRole           # we created a service account - make that an admin two
        {
            Name        = $SQLServiceCreds.UserName
            LoginType   = "WindowsUser"
            ServerRoles = "sysadmin"
            Enabled     = $true
            Credential  = $LocalUserAccount
            DependsOn   = "[xADUser]CreateSqlServerServiceAccount"
        }

        xSqlLogin AddDomainAdminAccountToSysadminServerRole              # make the domain admin (AzureAdmin) a sysadmin.  the local admin already is !
        {
            Name        = $DomainUserAccount.UserName
            LoginType   = "WindowsUser"
            ServerRoles = "sysadmin"
            Enabled     = $true
            Credential  = $LocalUserAccount
            DependsOn   = "[xSqlLogin]AddSqlServerServiceAccountToSysadminServerRole"
        }






        xSqlServer ConfigureSqlServerWithAlwaysOn
        {
            InstanceName                  = $env:COMPUTERNAME
            SqlAdministratorCredential    = $DomainUserAccount
            ServiceCredential             = $SQLServiceCreds
            MaxDegreeOfParallelism        = 1
            FilePath                      = "F:\DATA"
            LogPath                       = "F:\LOG"
            DomainAdministratorCredential = $DomainUserAccount
            DependsOn                     = "[xSqlLogin]AddDomainAdminAccountToSysadminServerRole"
        }


	}
}


function Get-NetBIOSName
{ 
    [OutputType([string])]
    param(
        [string]$DomainName
    )

    if ($DomainName.Contains('.')) {
        $length=$DomainName.IndexOf('.')
        if ( $length -ge 16) {
            $length=15
        }
        return $DomainName.Substring(0,$length)
    }
    else {
        if ($DomainName.Length -gt 15) {
            return $DomainName.Substring(0,15)
        }
        else {
            return $DomainName
        }
    }
}

function WaitForSqlSetup
{
    # Wait for SQL Server Setup to finish before proceeding.
    while ($true)
    {
        try
        {
            Get-ScheduledTaskInfo "\ConfigureSqlImageTasks\RunConfigureImage" -ErrorAction Stop
            Start-Sleep -Seconds 5
        }
        catch
        {
            break
        }
    }
}
 