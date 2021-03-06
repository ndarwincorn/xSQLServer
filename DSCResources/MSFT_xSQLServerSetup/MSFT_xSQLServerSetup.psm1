$script:currentPath = Split-Path -Path $MyInvocation.MyCommand.Path -Parent
Import-Module -Name (Join-Path -Path (Split-Path -Path (Split-Path -Path $script:currentPath -Parent) -Parent) -ChildPath 'xSQLServerHelper.psm1')
Import-Module -Name (Join-Path -Path (Split-Path -Path (Split-Path -Path $script:currentPath -Parent) -Parent) -ChildPath 'xPDT.psm1')

<#
    .SYNOPSIS
        Returns the current state of the SQL Server features.

    .PARAMETER SourcePath
        The path to the root of the source files for installation. I.e and UNC path to a shared resource.

    .PARAMETER SourceFolder
        Folder within the source path containing the source files for installation. Default value is 'Source'.

    .PARAMETER SetupCredential
        Credential to be used to perform the installation.

    .PARAMETER SourceCredential
        Credentials used to access the path set in the parameter `SourcePath` and `SourceFolder`. The parameter `SourceCredential` is used
        to evaluate what major version the file 'setup.exe' has in the path set, again, by the parameter `SourcePath` and `SourceFolder`.

    .PARAMETER InstanceName
        Name of the SQL instance to be installed.
#>
function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [Parameter()]
        [System.String]
        $SourcePath = "$PSScriptRoot\..\..\",

        [Parameter()]
        [System.String]
        $SourceFolder = 'Source',

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SetupCredential,

        [Parameter()]
        [System.Management.Automation.PSCredential]
        $SourceCredential,

        [Parameter(Mandatory = $true)]
        [System.String]
        $InstanceName
    )

    $InstanceName = $InstanceName.ToUpper()

    if ($SourceCredential)
    {
        NetUse -SourcePath $SourcePath -Credential $SourceCredential -Ensure 'Present'
    }

    $path = Join-Path -Path (Join-Path -Path $SourcePath -ChildPath $SourceFolder) -ChildPath 'setup.exe'
    $path = ResolvePath -Path $path

    New-VerboseMessage -Message "Using path: $path"

    $sqlVersion = GetSQLVersion -Path $path

    if ($SourceCredential)
    {
        NetUse -SourcePath $SourcePath -Credential $SourceCredential -Ensure 'Absent'
    }

    if ($InstanceName -eq 'MSSQLSERVER')
    {
        $databaseServiceName = 'MSSQLSERVER'
        $agentServiceName = 'SQLSERVERAGENT'
        $fullTextServiceName = 'MSSQLFDLauncher'
        $reportServiceName = 'ReportServer'
        $analysisServiceName = 'MSSQLServerOLAPService'
    }
    else
    {
        $databaseServiceName = "MSSQL`$$InstanceName"
        $agentServiceName = "SQLAgent`$$InstanceName"
        $fullTextServiceName = "MSSQLFDLauncher`$$InstanceName"
        $reportServiceName = "ReportServer`$$InstanceName"
        $analysisServiceName = "MSOLAP`$$InstanceName"
    }

    $integrationServiceName = "MsDtsServer$($sqlVersion)0"

    $features = ''

    $services = Get-Service
    if ($services | Where-Object {$_.Name -eq $databaseServiceName})
    {
        $features += 'SQLENGINE,'

        $sqlServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$databaseServiceName'").StartName
        $agentServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$agentServiceName'").StartName

        $fullInstanceId = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -Name $InstanceName).$InstanceName

        # Check if Replication sub component is configured for this instance
        New-VerboseMessage -Message "Detecting replication feature (HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$fullInstanceId\ConfigurationState)"
        $isReplicationInstalled = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$fullInstanceId\ConfigurationState").SQL_Replication_Core_Inst
        if ($isReplicationInstalled -eq 1)
        {
            New-VerboseMessage -Message 'Replication feature detected'
            $Features += 'REPLICATION,'
        }
        else
        {
            New-VerboseMessage -Message 'Replication feature not detected'
        }

        $instanceId = $fullInstanceId.Split('.')[1]
        $instanceDirectory = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$fullInstanceId\Setup" -Name 'SqlProgramDir').SqlProgramDir.Trim("\")

        $databaseServer = Connect-SQL -SQLServer 'localhost' -SQLInstanceName $InstanceName

        $sqlCollation = $databaseServer.Collation

        $sqlSystemAdminAccounts = @()
        foreach ($sqlUser in $databaseServer.Logins)
        {
            foreach ($sqlRole in $sqlUser.ListMembers())
            {
                if ($sqlRole -like 'sysadmin')
                {
                    $sqlSystemAdminAccounts += $sqlUser.Name
                }
            }
        }

        if ($databaseServer.LoginMode -eq 'Mixed')
        {
            $securityMode = 'SQL'
        }
        else
        {
            $securityMode = 'Windows'
        }

        $installSQLDataDirectory = $databaseServer.InstallDataDirectory
        $sqlUserDatabaseDirectory = $databaseServer.DefaultFile
        $sqlUserDatabaseLogDirectory = $databaseServer.DefaultLog
        $sqlBackupDirectory = $databaseServer.BackupDirectory
    }

    if ($services | Where-Object {$_.Name -eq $fullTextServiceName})
    {
        $features += 'FULLTEXT,'
        $fulltextServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$fullTextServiceName'").StartName
    }

    if ($services | Where-Object {$_.Name -eq $reportServiceName})
    {
        $features += 'RS,'
        $reportingServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$reportServiceName'").StartName
    }

    if ($services | Where-Object {$_.Name -eq $analysisServiceName})
    {
        $features += 'AS,'
        $analysisServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$analysisServiceName'").StartName

        $analysisServer = Connect-SQLAnalysis -SQLServer localhost -SQLInstanceName $InstanceName

        $analysisCollation = $analysisServer.ServerProperties['CollationName'].Value
        $analysisDataDirectory = $analysisServer.ServerProperties['DataDir'].Value
        $analysisTempDirectory = $analysisServer.ServerProperties['TempDir'].Value
        $analysisLogDirectory = $analysisServer.ServerProperties['LogDir'].Value
        $analysisBackupDirectory = $analysisServer.ServerProperties['BackupDir'].Value

        $analysisSystemAdminAccounts = $analysisServer.Roles['Administrators'].Members.Name

        $analysisConfigDirectory = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$analysisServiceName" -Name 'ImagePath').ImagePath.Replace(' -s ',',').Split(',')[1].Trim('"')
    }

    if ($services | Where-Object {$_.Name -eq $integrationServiceName})
    {
        $features += 'IS,'
        $integrationServiceAccountUsername = (Get-CimInstance -ClassName Win32_Service -Filter "Name = '$integrationServiceName'").StartName
    }

    $registryUninstallPath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall'

    # Verify if SQL Server Management Studio 2008 or SQL Server Management Studio 2008 R2 (major version 10) is installed
    $installedProductSqlServerManagementStudio2008R2 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{72AB7E6F-BC24-481E-8C45-1AB5B3DD795D}'
    ) -ErrorAction SilentlyContinue

    # Verify if SQL Server Management Studio 2012 (major version 11) is installed
    $installedProductSqlServerManagementStudio2012 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{A7037EB2-F953-4B12-B843-195F4D988DA1}'
    ) -ErrorAction SilentlyContinue

    # Verify if SQL Server Management Studio 2014 (major version 12) is installed
    $installedProductSqlServerManagementStudio2014 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{75A54138-3B98-4705-92E4-F619825B121F}'
    ) -ErrorAction SilentlyContinue

    if (
        ($sqlVersion -eq 10 -and $installedProductSqlServerManagementStudio2008R2) -or
        ($sqlVersion -eq 11 -and $installedProductSqlServerManagementStudio2012) -or
        ($sqlVersion -eq 12 -and $installedProductSqlServerManagementStudio2014)
        )
    {
        $features += 'SSMS,'
    }

    # Evaluating if SQL Server Management Studio Advanced 2008  or SQL Server Management Studio Advanced 2008 R2 (major version 10) is installed
    $installedProductSqlServerManagementStudioAdvanced2008R2 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{B5FE23CC-0151-4595-84C3-F1DE6F44FE9B}'
    ) -ErrorAction SilentlyContinue

    # Evaluating if SQL Server Management Studio Advanced 2012 (major version 11) is installed
    $installedProductSqlServerManagementStudioAdvanced2012 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{7842C220-6E9A-4D5A-AE70-0E138271F883}'
    ) -ErrorAction SilentlyContinue

    # Evaluating if SQL Server Management Studio Advanced 2014 (major version 12) is installed
    $installedProductSqlServerManagementStudioAdvanced2014 = Get-ItemProperty -Path (
        Join-Path -Path $registryUninstallPath -ChildPath '{B5ECFA5C-AC4F-45A4-A12E-A76ABDD9CCBA}'
    ) -ErrorAction SilentlyContinue

    if (
        ($sqlVersion -eq 10 -and $installedProductSqlServerManagementStudioAdvanced2008R2) -or
        ($sqlVersion -eq 11 -and $installedProductSqlServerManagementStudioAdvanced2012) -or
        ($sqlVersion -eq 12 -and $installedProductSqlServerManagementStudioAdvanced2014)
        )
    {
        $features += 'ADV_SSMS,'
    }

    $features = $features.Trim(',')
    if ($features -ne '')
    {
        $registryInstallerComponentsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components'

        switch ($sqlVersion)
        {
            '10'
            {
                $registryKeySharedDir = '0D1F366D0FE0E404F8C15EE4F1C15094'
                $registryKeySharedWOWDir = 'C90BFAC020D87EA46811C836AD3C507F'
            }

            '11'
            {
                $registryKeySharedDir = 'FEE2E540D20152D4597229B6CFBC0A69'
                $registryKeySharedWOWDir = 'A79497A344129F64CA7D69C56F5DD8B4'
            }

            '12'
            {
                $registryKeySharedDir = 'FEE2E540D20152D4597229B6CFBC0A69'
                $registryKeySharedWOWDir = 'C90BFAC020D87EA46811C836AD3C507F'
            }

            '13'
            {
                $registryKeySharedDir = 'FEE2E540D20152D4597229B6CFBC0A69'
                $registryKeySharedWOWDir = 'A79497A344129F64CA7D69C56F5DD8B4'
            }
        }

        if ($registryKeySharedDir)
        {
            $installSharedDir = Get-FirstItemPropertyValue -Path (Join-Path -Path $registryInstallerComponentsPath -ChildPath $registryKeySharedDir)
        }

        if ($registryKeySharedWOWDir)
        {
            $installSharedWOWDir = Get-FirstItemPropertyValue -Path (Join-Path -Path $registryInstallerComponentsPath -ChildPath $registryKeySharedWOWDir)
        }
    }

    return @{
        SourcePath = $SourcePath
        SourceFolder = $SourceFolder
        Features = $features
        InstanceName = $InstanceName
        InstanceID = $instanceID
        InstallSharedDir = $installSharedDir
        InstallSharedWOWDir = $installSharedWOWDir
        InstanceDir = $instanceDirectory
        SQLSvcAccountUsername = $sqlServiceAccountUsername
        AgtSvcAccountUsername = $agentServiceAccountUsername
        SQLCollation = $sqlCollation
        SQLSysAdminAccounts = $sqlSystemAdminAccounts
        SecurityMode = $securityMode
        InstallSQLDataDir = $installSQLDataDirectory
        SQLUserDBDir = $sqlUserDatabaseDirectory
        SQLUserDBLogDir = $sqlUserDatabaseLogDirectory
        SQLTempDBDir = $null
        SQLTempDBLogDir = $null
        SQLBackupDir = $sqlBackupDirectory
        FTSvcAccountUsername = $fulltextServiceAccountUsername
        RSSvcAccountUsername = $reportingServiceAccountUsername
        ASSvcAccountUsername = $analysisServiceAccountUsername
        ASCollation = $analysisCollation
        ASSysAdminAccounts = $analysisSystemAdminAccounts
        ASDataDir = $analysisDataDirectory
        ASLogDir = $analysisLogDirectory
        ASBackupDir = $analysisBackupDirectory
        ASTempDir = $analysisTempDirectory
        ASConfigDir = $analysisConfigDirectory
        ISSvcAccountUsername = $integrationServiceAccountUsername
    }
}

<#
    .SYNOPSIS
        Installs the SQL Server features to the node.

    .PARAMETER SourcePath
        The path to the root of the source files for installation. I.e and UNC path to a shared resource.

    .PARAMETER SourceFolder
        Folder within the source path containing the source files for installation. Default value is 'Source'.

    .PARAMETER SetupCredential
        Credential to be used to perform the installation.

    .PARAMETER SourceCredential
        Credentials used to access the path set in the parameter `SourcePath` and `SourceFolder`. Using this parameter will trigger a copy
        of the installation media to a temp folder on the target node. Setup will then be started from the temp folder on the target node.
        For any subsequent calls to the resource, the parameter `SourceCredential` is used to evaluate what major version the file 'setup.exe'
        has in the path set, again, by the parameter `SourcePath` and `SourceFolder`.

    .PARAMETER SuppressReboot
        Suppressed reboot.

    .PARAMETER ForceReboot
        Forces reboot.

    .PARAMETER Features
        SQL features to be installed.

    .PARAMETER InstanceName
        Name of the SQL instance to be installed.

    .PARAMETER InstanceID
        SQL instance ID, if different from InstanceName.

    .PARAMETER PID
        Product key for licensed installations.

    .PARAMETER UpdateEnabled
        Enabled updates during installation.

    .PARAMETER UpdateSource
        Path to the source of updates to be applied during installation.

    .PARAMETER SQMReporting
        Enable customer experience reporting.

    .PARAMETER ErrorReporting
        Enable error reporting.

    .PARAMETER InstallSharedDir
        Installation path for shared SQL files.

    .PARAMETER InstallSharedWOWDir
        Installation path for x86 shared SQL files.

    .PARAMETER InstanceDir
        Installation path for SQL instance files.

    .PARAMETER SQLSvcAccount
        Service account for the SQL service.

    .PARAMETER AgtSvcAccount
        Service account for the SQL Agent service.

    .PARAMETER SQLCollation
        Collation for SQL.

    .PARAMETER SQLSysAdminAccounts
        Array of accounts to be made SQL administrators.

    .PARAMETER SecurityMode
        Security mode to apply to the SQL Server instance.

    .PARAMETER SAPwd
        SA password, if SecurityMode is set to 'SQL'.

    .PARAMETER InstallSQLDataDir
        Root path for SQL database files.

    .PARAMETER SQLUserDBDir
        Path for SQL database files.

    .PARAMETER SQLUserDBLogDir
        Path for SQL log files.

    .PARAMETER SQLTempDBDir
        Path for SQL TempDB files.

    .PARAMETER SQLTempDBLogDir
        Path for SQL TempDB log files.

    .PARAMETER SQLBackupDir
        Path for SQL backup files.

    .PARAMETER FTSvcAccount
        Service account for the Full Text service.

    .PARAMETER RSSvcAccount
        Service account for Reporting Services service.

    .PARAMETER ASSvcAccount
       Service account for Analysis Services service.

    .PARAMETER ASCollation
        Collation for Analysis Services.

    .PARAMETER ASSysAdminAccounts
        Array of accounts to be made Analysis Services admins.

    .PARAMETER ASDataDir
        Path for Analysis Services data files.

    .PARAMETER ASLogDir
        Path for Analysis Services log files.

    .PARAMETER ASBackupDir
        Path for Analysis Services backup files.

    .PARAMETER ASTempDir
        Path for Analysis Services temp files.

    .PARAMETER ASConfigDir
        Path for Analysis Services config.

    .PARAMETER ISSvcAccount
       Service account for Integration Services service.

    .PARAMETER BrowserSvcStartupType
       Specifies the startup mode for SQL Server Browser service
#>
function Set-TargetResource
{
    # Suppressing this rule because $global:DSCMachineStatus is used to trigger a reboot, either by force or when there are pending changes.
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidGlobalVars', '')]
    [CmdletBinding()]
    param
    (
        [System.String]
        $SourcePath = "$PSScriptRoot\..\..\",

        [System.String]
        $SourceFolder = 'Source',

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SetupCredential,

        [System.Management.Automation.PSCredential]
        $SourceCredential,

        [System.Boolean]
        $SuppressReboot,

        [System.Boolean]
        $ForceReboot,

        [System.String]
        $Features,

        [parameter(Mandatory = $true)]
        [System.String]
        $InstanceName,

        [System.String]
        $InstanceID,

        [System.String]
        $PID,

        [System.String]
        $UpdateEnabled,

        [System.String]
        $UpdateSource,

        [System.String]
        $SQMReporting,

        [System.String]
        $ErrorReporting,

        [System.String]
        $InstallSharedDir,

        [System.String]
        $InstallSharedWOWDir,

        [System.String]
        $InstanceDir,

        [System.Management.Automation.PSCredential]
        $SQLSvcAccount,

        [System.Management.Automation.PSCredential]
        $AgtSvcAccount,

        [System.String]
        $SQLCollation,

        [System.String[]]
        $SQLSysAdminAccounts,

        [System.String]
        $SecurityMode,

        [System.Management.Automation.PSCredential]
        $SAPwd,

        [System.String]
        $InstallSQLDataDir,

        [System.String]
        $SQLUserDBDir,

        [System.String]
        $SQLUserDBLogDir,

        [System.String]
        $SQLTempDBDir,

        [System.String]
        $SQLTempDBLogDir,

        [System.String]
        $SQLBackupDir,

        [System.Management.Automation.PSCredential]
        $FTSvcAccount,

        [System.Management.Automation.PSCredential]
        $RSSvcAccount,

        [System.Management.Automation.PSCredential]
        $ASSvcAccount,

        [System.String]
        $ASCollation,

        [System.String[]]
        $ASSysAdminAccounts,

        [System.String]
        $ASDataDir,

        [System.String]
        $ASLogDir,

        [System.String]
        $ASBackupDir,

        [System.String]
        $ASTempDir,

        [System.String]
        $ASConfigDir,

        [System.Management.Automation.PSCredential]
        $ISSvcAccount,

        [System.String]
        [ValidateSet('Automatic', 'Disabled', 'Manual')]
        $BrowserSvcStartupType
    )

    $parameters = @{
        SourcePath = $SourcePath
        SourceFolder = $SourceFolder
        SetupCredential = $SetupCredential
        SourceCredential = $SourceCredential
        InstanceName = $InstanceName
    }

    $sqlData = Get-TargetResource @parameters

    $InstanceName = $InstanceName.ToUpper()

    $mediaSourcePath = (Join-Path -Path $SourcePath -ChildPath $SourceFolder)

    if ($SourceCredential)
    {
        NetUse -SourcePath $SourcePath -Credential $SourceCredential -Ensure 'Present'

        $tempPath = Get-TemporaryFolder
        $mediaDestinationPath = (Join-Path -Path $tempPath -ChildPath $SourceFolder)

        New-VerboseMessage -Message "Robocopy is copying media from source '$mediaSourcePath' to destination '$mediaDestinationPath'"
        Copy-ItemWithRoboCopy -Path $mediaSourcePath -DestinationPath $mediaDestinationPath

        NetUse -SourcePath $SourcePath -Credential $SourceCredential -Ensure 'Absent'

        $mediaSourcePath = $mediaDestinationPath
    }

    $path = ResolvePath (Join-Path -Path $mediaSourcePath -ChildPath 'setup.exe')

    New-VerboseMessage -Message "Using path: $path"

    $sqlVersion = GetSQLVersion -Path $path

    # Determine features to install
    $featuresToInstall = ""
    foreach ($feature in $Features.Split(","))
    {
        # Given that all the returned features are uppercase, make sure that the feature to search for is also uppercase
        $feature = $feature.ToUpper();

        if (($sqlVersion -eq '13') -and (($feature -eq 'SSMS') -or ($feature -eq 'ADV_SSMS')))
        {
            Throw New-TerminatingError -ErrorType FeatureNotSupported -FormatArgs @($feature) -ErrorCategory InvalidData
        }

        if (!($sqlData.Features.Contains($feature)))
        {
            $featuresToInstall += "$feature,"
        }
    }

    $Features = $featuresToInstall.Trim(',')

    # If SQL shared components already installed, clear InstallShared*Dir variables
    switch ($sqlVersion)
    {
        '10'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\0D1F366D0FE0E404F8C15EE4F1C15094' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\C90BFAC020D87EA46811C836AD3C507F' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }

        '11'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\30AE1F084B1CF8B4797ECB3CCAA3B3B6' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\A79497A344129F64CA7D69C56F5DD8B4' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }

        '12'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\FEE2E540D20152D4597229B6CFBC0A69' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\C90BFAC020D87EA46811C836AD3C507F' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }

        '13'
        {
            if((Get-Variable -Name 'InstallSharedDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\FEE2E540D20152D4597229B6CFBC0A69' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedDir' -Value ''
            }
            if((Get-Variable -Name 'InstallSharedWOWDir' -ErrorAction SilentlyContinue) -and (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Components\A79497A344129F64CA7D69C56F5DD8B4' -ErrorAction SilentlyContinue))
            {
                Set-Variable -Name 'InstallSharedWOWDir' -Value ''
            }
        }
    }

    # Remove trailing "\" from paths
    foreach ($var in @(
        'InstallSQLDataDir',
        'SQLUserDBDir',
        'SQLUserDBLogDir',
        'SQLTempDBDir',
        'SQLTempDBLogDir',
        'SQLBackupDir',
        'ASDataDir',
        'ASLogDir',
        'ASBackupDir',
        'ASTempDir',
        'ASConfigDir')
    )
    {
        if (Get-Variable -Name $var -ErrorAction SilentlyContinue)
        {
            Set-Variable -Name $var -Value (Get-Variable -Name $var).Value.TrimEnd('\')
        }
    }

    # Create install arguments
    $arguments = "/Quiet=`"True`" /IAcceptSQLServerLicenseTerms=`"True`" /Action=`"Install`""
    $argumentVars = @(
        'InstanceName',
        'InstanceID',
        'UpdateEnabled',
        'UpdateSource',
        'Features',
        'PID',
        'SQMReporting',
        'ErrorReporting',
        'InstallSharedDir',
        'InstallSharedWOWDir',
        'InstanceDir'
    )

    if ($null -ne $BrowserSvcStartupType)
    {
        $argumentVars += 'BrowserSvcStartupType'
    }

    if ($Features.Contains('SQLENGINE'))
    {
        $argumentVars += @(
            'SecurityMode',
            'SQLCollation',
            'InstallSQLDataDir',
            'SQLUserDBDir',
            'SQLUserDBLogDir',
            'SQLTempDBDir',
            'SQLTempDBLogDir',
            'SQLBackupDir'
        )

        if ($PSBoundParameters.ContainsKey('SQLSvcAccount'))
        {
            $arguments = $arguments | Join-ServiceAccountInfo -UsernameArgumentName 'SQLSVCACCOUNT' -PasswordArgumentName 'SQLSVCPASSWORD' -User $SQLSvcAccount
        }

        if($PSBoundParameters.ContainsKey('AgtSvcAccount'))
        {
            $arguments = $arguments | Join-ServiceAccountInfo -UsernameArgumentName 'AGTSVCACCOUNT' -PasswordArgumentName 'AGTSVCPASSWORD' -User $AgtSvcAccount
        }

        $arguments += ' /AGTSVCSTARTUPTYPE=Automatic'
    }

    if ($Features.Contains('FULLTEXT'))
    {
        if ($PSBoundParameters.ContainsKey('FTSvcAccount'))
        {
            $arguments = $arguments | Join-ServiceAccountInfo -UsernameArgumentName 'FTSVCACCOUNT' -PasswordArgumentName 'FTSVCPASSWORD' -User $FTSvcAccount
        }
    }

    if ($Features.Contains('RS'))
    {
        if ($PSBoundParameters.ContainsKey('RSSvcAccount'))
        {
            $arguments = $arguments | Join-ServiceAccountInfo -UsernameArgumentName 'RSSVCACCOUNT' -PasswordArgumentName 'RSSVCPASSWORD' -User $RSSvcAccount
        }
    }

    if ($Features.Contains('AS'))
    {
        $argumentVars += @(
            'ASCollation',
            'ASDataDir',
            'ASLogDir',
            'ASBackupDir',
            'ASTempDir',
            'ASConfigDir'
        )

        if ($PSBoundParameters.ContainsKey('ASSvcAccount'))
        {
            $arguments = $arguments | Join-ServiceAccountInfo -UsernameArgumentName 'ASSVCACCOUNT' -PasswordArgumentName 'ASSVCPASSWORD' -User $ASSvcAccount
        }
    }

    if ($Features.Contains('IS'))
    {
        if ($PSBoundParameters.ContainsKey('ISSvcAccount'))
        {
            $arguments = $arguments | Join-ServiceAccountInfo -UsernameArgumentName 'ISSVCACCOUNT' -PasswordArgumentName 'ISSVCPASSWORD' -User $ISSvcAccount
        }
    }

    foreach ($argumentVar in $argumentVars)
    {
        if ((Get-Variable -Name $argumentVar).Value -ne '')
        {
            $arguments += " /$argumentVar=`"" + (Get-Variable -Name $argumentVar).Value + "`""
        }
    }

    if ($Features.Contains('SQLENGINE'))
    {
        $arguments += " /SQLSysAdminAccounts=`"" + $SetupCredential.UserName + "`""
        if ($PSBoundParameters.ContainsKey('SQLSysAdminAccounts'))
        {
            foreach ($adminAccount in $SQLSysAdminAccounts)
            {
                $arguments += " `"$adminAccount`""
            }
        }

        if ($SecurityMode -eq 'SQL')
        {
            $arguments += " /SAPwd=" + $SAPwd.GetNetworkCredential().Password
        }
    }

    if ($Features.Contains('AS'))
    {
        $arguments += " /ASSysAdminAccounts=`"" + $SetupCredential.UserName + "`""
        if($PSBoundParameters.ContainsKey("ASSysAdminAccounts"))
        {
            foreach($adminAccount in $ASSysAdminAccounts)
            {
                $arguments += " `"$adminAccount`""
            }
        }
    }

    # Replace sensitive values for verbose output
    $log = $arguments
    if ($SecurityMode -eq 'SQL')
    {
        $log = $log.Replace($SAPwd.GetNetworkCredential().Password,"********")
    }

    if ($PID -ne "")
    {
        $log = $log.Replace($PID,"*****-*****-*****-*****-*****")
    }

    $logVars = @('AgtSvcAccount', 'SQLSvcAccount', 'FTSvcAccount', 'RSSvcAccount', 'ASSvcAccount','ISSvcAccount')
    foreach ($logVar in $logVars)
    {
        if ($PSBoundParameters.ContainsKey($logVar))
        {
            $log = $log.Replace((Get-Variable -Name $logVar).Value.GetNetworkCredential().Password,"********")
        }
    }

    New-VerboseMessage -Message "Starting setup using arguments: $log"

    $process = StartWin32Process -Path $path -Arguments $arguments
    New-VerboseMessage -Message $process
    WaitForWin32ProcessEnd -Path $path -Arguments $arguments

    if ($ForceReboot -or ($null -ne (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name 'PendingFileRenameOperations' -ErrorAction SilentlyContinue)))
    {
        if (!($SuppressReboot))
        {
            $global:DSCMachineStatus = 1
        }
        else
        {
            New-VerboseMessage -Message 'Suppressing reboot'
        }
    }

    if (!(Test-TargetResource @PSBoundParameters))
    {
        throw New-TerminatingError -ErrorType TestFailedAfterSet -ErrorCategory InvalidResult
    }
}

<#
    .SYNOPSIS
        Tests if the SQL Server features are installed on the node.

    .PARAMETER SourcePath
        The path to the root of the source files for installation. I.e and UNC path to a shared resource.

    .PARAMETER SourceFolder
        Folder within the source path containing the source files for installation. Default value is 'Source'.

    .PARAMETER SetupCredential
        Credential to be used to perform the installation.

    .PARAMETER SourceCredential
        Credentials used to access the path set in the parameter `SourcePath` and `SourceFolder`. The parameter `SourceCredential` is used
        to evaluate what major version the file 'setup.exe' has in the path set, again, by the parameter `SourcePath` and `SourceFolder`.

    .PARAMETER SuppressReboot
        Suppresses reboot.

    .PARAMETER ForceReboot
        Forces reboot.

    .PARAMETER Features
        SQL features to be installed.

    .PARAMETER InstanceName
        Name of the SQL instance to be installed.

    .PARAMETER InstanceID
        SQL instance ID, if different from InstanceName.

    .PARAMETER PID
        Product key for licensed installations.

    .PARAMETER UpdateEnabled
        Enabled updates during installation.

    .PARAMETER UpdateSource
        Path to the source of updates to be applied during installation.

    .PARAMETER SQMReporting
        Enable customer experience reporting.

    .PARAMETER ErrorReporting
        Enable error reporting.

    .PARAMETER InstallSharedDir
        Installation path for shared SQL files.

    .PARAMETER InstallSharedWOWDir
        Installation path for x86 shared SQL files.

    .PARAMETER InstanceDir
        Installation path for SQL instance files.

    .PARAMETER SQLSvcAccount
        Service account for the SQL service.

    .PARAMETER AgtSvcAccount
        Service account for the SQL Agent service.

    .PARAMETER SQLCollation
        Collation for SQL.

    .PARAMETER SQLSysAdminAccounts
        Array of accounts to be made SQL administrators.

    .PARAMETER SecurityMode
        Security mode to apply to the SQL Server instance.

    .PARAMETER SAPwd
        SA password, if SecurityMode is set to 'SQL'.

    .PARAMETER InstallSQLDataDir
        Root path for SQL database files.

    .PARAMETER SQLUserDBDir
        Path for SQL database files.

    .PARAMETER SQLUserDBLogDir
        Path for SQL log files.

    .PARAMETER SQLTempDBDir
        Path for SQL TempDB files.

    .PARAMETER SQLTempDBLogDir
        Path for SQL TempDB log files.

    .PARAMETER SQLBackupDir
        Path for SQL backup files.

    .PARAMETER FTSvcAccount
        Service account for the Full Text service.

    .PARAMETER RSSvcAccount
        Service account for Reporting Services service.

    .PARAMETER ASSvcAccount
       Service account for Analysis Services service.

    .PARAMETER ASCollation
        Collation for Analysis Services.

    .PARAMETER ASSysAdminAccounts
        Array of accounts to be made Analysis Services admins.

    .PARAMETER ASDataDir
        Path for Analysis Services data files.

    .PARAMETER ASLogDir
        Path for Analysis Services log files.

    .PARAMETER ASBackupDir
        Path for Analysis Services backup files.

    .PARAMETER ASTempDir
        Path for Analysis Services temp files.

    .PARAMETER ASConfigDir
        Path for Analysis Services config.

    .PARAMETER ISSvcAccount
       Service account for Integration Services service.

    .PARAMETER BrowserSvcStartupType
       Specifies the startup mode for SQL Server Browser service
#>
function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [System.String]
        $SourcePath = "$PSScriptRoot\..\..\",

        [System.String]
        $SourceFolder = 'Source',

        [parameter(Mandatory = $true)]
        [System.Management.Automation.PSCredential]
        $SetupCredential,

        [System.Management.Automation.PSCredential]
        $SourceCredential,

        [System.Boolean]
        $SuppressReboot,

        [System.Boolean]
        $ForceReboot,

        [System.String]
        $Features,

        [parameter(Mandatory = $true)]
        [System.String]
        $InstanceName,

        [System.String]
        $InstanceID,

        [System.String]
        $PID,

        [System.String]
        $UpdateEnabled,

        [System.String]
        $UpdateSource,

        [System.String]
        $SQMReporting,

        [System.String]
        $ErrorReporting,

        [System.String]
        $InstallSharedDir,

        [System.String]
        $InstallSharedWOWDir,

        [System.String]
        $InstanceDir,

        [System.Management.Automation.PSCredential]
        $SQLSvcAccount,

        [System.Management.Automation.PSCredential]
        $AgtSvcAccount,

        [System.String]
        $SQLCollation,

        [System.String[]]
        $SQLSysAdminAccounts,

        [System.String]
        $SecurityMode,

        [System.Management.Automation.PSCredential]
        $SAPwd,

        [System.String]
        $InstallSQLDataDir,

        [System.String]
        $SQLUserDBDir,

        [System.String]
        $SQLUserDBLogDir,

        [System.String]
        $SQLTempDBDir,

        [System.String]
        $SQLTempDBLogDir,

        [System.String]
        $SQLBackupDir,

        [System.Management.Automation.PSCredential]
        $FTSvcAccount,

        [System.Management.Automation.PSCredential]
        $RSSvcAccount,

        [System.Management.Automation.PSCredential]
        $ASSvcAccount,

        [System.String]
        $ASCollation,

        [System.String[]]
        $ASSysAdminAccounts,

        [System.String]
        $ASDataDir,

        [System.String]
        $ASLogDir,

        [System.String]
        $ASBackupDir,

        [System.String]
        $ASTempDir,

        [System.String]
        $ASConfigDir,

        [System.Management.Automation.PSCredential]
        $ISSvcAccount,

        [System.String]
        [ValidateSet('Automatic', 'Disabled', 'Manual')]
        $BrowserSvcStartupType
    )

    $parameters = @{
        SourcePath = $SourcePath
        SourceFolder = $SourceFolder
        SetupCredential = $SetupCredential
        SourceCredential = $SourceCredential
        InstanceName = $InstanceName
    }

    $sqlData = Get-TargetResource @parameters
    New-VerboseMessage -Message "Features found: '$($SQLData.Features)'"

    $result = $false
    if ($sqlData.Features )
    {
        $result = $true

        foreach ($feature in $Features.Split(","))
        {
            # Given that all the returned features are uppercase, make sure that the feature to search for is also uppercase
            $feature = $feature.ToUpper();

            if(!($sqlData.Features.Contains($feature)))
            {
                New-VerboseMessage -Message "Unable to find feature '$feature' among the installed features: '$($sqlData.Features)'"
                $result = $false
            }
        }
    }

    $result
}

<#
    .SYNOPSIS
        Returns the SQL Server major version from the setup.exe executable provided in the Path parameter.

    .PARAMETER Path
        String containing the path to the SQL Server setup.exe executable.
#>
function GetSQLVersion
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [String]
        $Path
    )

    (Get-Item -Path $Path).VersionInfo.ProductVersion.Split('.')[0]
}

<#
    .SYNOPSIS
        Returns the first item value in the registry location provided in the Path parameter.

    .PARAMETER Path
        String containing the path to the registry.
#>
function Get-FirstItemPropertyValue
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true)]
        [String]
        $Path
    )

    $registryProperty = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if ($registryProperty)
    {
        $registryProperty = $registryProperty | Select-Object -ExpandProperty Property | Select-Object -First 1
        if ($registryProperty)
        {
            $registryPropertyValue = (Get-ItemProperty -Path $Path -Name $registryProperty).$registryProperty.TrimEnd('\')
        }
    }

    return $registryPropertyValue
}

<#
    .SYNOPSIS
        Copy folder structure using RoboCopy. Every file and folder, including empty ones are copied.

    .PARAMETER Path
        Source path to be copied.

    .PARAMETER DestinationPath
        The path to the destination.
#>
function Copy-ItemWithRoboCopy
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $Path,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]
        $DestinationPath
    )

    $robocopyExecutable = Get-Command -Name "Robocopy.exe" -ErrorAction Stop

    $robocopyArgumentSilent = '/njh /njs /ndl /nc /ns /nfl'
    $robocopyArgumentCopySubDirectoriesIncludingEmpty = '/e'
    $robocopyArgumentDeletesDestinationFilesAndDirectoriesNotExistAtSource = '/purge'

    if ([System.Version]$robocopyExecutable.FileVersionInfo.ProductVersion -ge [System.Version]'6.3.9600.16384')
    {
        Write-Verbose "Robocopy is using unbuffered I/O."
        $robocopyArgumentUseUnbufferedIO = '/J'
    }
    else
    {
        Write-Verbose 'Unbuffered I/O cannot be used due to incompatible version of Robocopy.'
    }

    $robocopyArgumentList = '{0} {1} {2} {3} {4} {5}' -f $Path,
                                                         $DestinationPath,
                                                         $robocopyArgumentCopySubDirectoriesIncludingEmpty,
                                                         $robocopyArgumentDeletesDestinationFilesAndDirectoriesNotExistAtSource,
                                                         $robocopyArgumentUseUnbufferedIO,
                                                         $robocopyArgumentSilent

    $robocopyStartProcessParameters = @{
        FilePath = $robocopyExecutable.Name
        ArgumentList = $robocopyArgumentList
    }

    Write-Verbose ('Robocopy is started with the following arguments: {0}' -f $robocopyArgumentList )
    $robocopyProcess = Start-Process @robocopyStartProcessParameters -Wait -NoNewWindow -PassThru

    switch ($($robocopyProcess.ExitCode))
    {
        {$_ -in 8, 16}
        {
            throw "Robocopy reported errors when copying files. Error code: $_."
        }

        {$_ -gt 7 }
        {
            throw "Robocopy reported that failures occured when copying files. Error code: $_."
        }

        1
        {
            Write-Verbose 'Robocopy copied files sucessfully'
        }

        2
        {
            Write-Verbose 'Robocopy found files at the destination path that is not present at the source path, these extra files was remove at the destination path.'
        }

        3
        {
            Write-Verbose 'Robocopy copied files to destination sucessfully. Robocopy also found files at the destination path that is not present at the source path, these extra files was remove at the destination path.'
        }

        {$_ -eq 0 -or $null -eq $_ }
        {
            Write-Verbose 'Robocopy reported that all files already present.'
        }
    }
}

<#
    .SYNOPSIS
        Returns the path of the current user's temporary folder.
#>
function Get-TemporaryFolder
{
    [CmdletBinding()]
    [OutputType([System.String])]
    param()

    return [IO.Path]::GetTempPath()
}

<#
    .SYNOPSIS
        Returns the argument string appeneded with the account information as is given in UserAlias and User parameters
#>
function Join-ServiceAccountInfo
{
    <#
        Suppressing this rule because there are parameters that contain the text 'UserName' and 'Password' 
        but they are not actually used to pass any credentials. Instead the parameters are used to provide the
        argument that should be evaluated for setup.exe.
    #>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '')]
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '')]
    param(
        [Parameter(Mandatory, ValueFromPipeline=$true)]
        [string]
        $ArgumentString,

        [Parameter(Mandatory)]
        [PSCredential]
        $User,

        [Parameter(Mandatory)]
        [string]
        $UsernameArgumentName,

        [Parameter(Mandatory)]
        [string]
        $PasswordArgumentName
    )

    process {

        <#
            Regex to determine if given username is an NT Authority account or not.
            Accepted inputs are optional ntauthority with or without space between nt and authority
            then a predefined list of users system, networkservice and localservice
        #>
        if($User.UserName.ToUpper() -match '^(NT ?AUTHORITY\\)?(SYSTEM|LOCALSERVICE|NETWORKSERVICE)$')
        {
            # Dealing with NT Authority user
            $ArgumentString += (' /{0}="NT AUTHORITY\{1}"' -f $UsernameArgumentName, $matches[2])
        }
        elseif ($User.UserName -like '*$')
        {
            # Dealing with Managed Service Account
            $ArgumentString += (' /{0}="{1}"' -f $UsernameArgumentName, $User.UserName)
        }
        else
        {
            # Dealing with local or domain user
            $ArgumentString += (' /{0}="{1}"' -f $UsernameArgumentName, $User.UserName)
            $ArgumentString += (' /{0}="{1}"' -f $PasswordArgumentName, $User.GetNetworkCredential().Password)
        }

        return $ArgumentString
    }
}

Export-ModuleMember -Function *-TargetResource
