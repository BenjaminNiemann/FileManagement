<#

.SYNOPSIS
    Migration of userdata
.DESCRIPTION
    Migration of userdata based on a given CSV file 
.EXAMPLE
    Continous migration: 

        Start-Migration.ps1 -logDirectory "C:\windows\log" 

.EXAMPLE
    AdHoc migration: 

        Start-Migration.ps1 -logDirectory "C:\windows\log" -AdHoc 

.NOTES
    09.11.2020: Created by Michael Bachmann - Perinova IT-Management GmbH 
    02.12.2020: Added Accessrights managment - Benjamin Niemann - Perinova IT-Management GmbH

    Min. PS Version 5 

#>

#Requires -Version 5

[CmdletBinding(DefaultParameterSetName='Default')]
Param (
    # logDirectory : Directory for logging 
    [Parameter(ParameterSetName='Default')]
    [ValidateNotNull()]
    [ValidateNotNullOrEmpty()]
    [string]
    $logDirectory = "",
    
    # ControlFile : Exact path to the control CSV file 
    [Parameter(ParameterSetName='Default')]
    [ValidateNotNull()]
    [ValidateNotNullOrEmpty()]
    [String]
    $ControlFile = "",

    [Parameter(ParameterSetName='Default')]
    [ValidateNotNull()]
    [ValidateNotNullOrEmpty()]
    [string[]]
    $ControlFileHeader = @("MigrationActive", "FinalizeMigration", "UserName", "UserSrcPath", "UserDstPath", "LastMigration", "LastMigrationResult", "MigrationLog"), 

    # Parameter help description
    [Parameter(ParameterSetName='Default')]
    [switch]
    $AdHoc
)
begin {
    #region define some functions 
    function Write-Log {
        param (
            $LogFile,
            $Message
        )
        try {
            $DateTime = Get-Date -Format "dd.MM.yyyy - HH:mm:ss"
            $DataString = "[$($DateTime)]   $Message" 
            Add-Content -Path $LogFile -Value $DataString -Encoding UTF8
        } 
        catch {
            $PSCmdlet.WriteError($_)
        }
        
    }
    #endregion define some functions 
}
#region process
process {
    $TimeStamp = Get-Date -Format ddMMyyyy-HHmmss 
    $TimeStampForCSV = Get-Date -Format dd.MM.yyyy 
    $ErrorActionPreference = "Stop"
    try {
        #region Input
        if (Test-Path -Path $ControlFile) { # If file exists
            # import control file as csv with predefined headers 
            try {
                $InputDataSet = Get-Content -Path $ControlFile -Encoding UTF8 | ConvertFrom-Csv -Delimiter ";" -Header $ControlFileHeader 
            } catch {
                throw("Cannot open file '$ControlFile'. Please verify the file exists and is accessible! $_")
            }
        } else {
            # throw an error message, when file does not exist
            throw("Cannot find file '$ControlFile'. Please verify the file exists!")
        }
        #endregion Input

        #region migration 
        $OutputDataSet = $InputDataSet | ForEach-Object -Process {
            if ($_."MigrationActive" -ieq "True") {
                # Only if "MigrationActive" is set to "True" (not case sensitive!)
                if (($AdHoc -and ($_."FinalizeMigration" -ieq "True")) -or ( !$AdHoc ) ) {
                    # Only if AdHoc is enabled and "FinalizeMigration" is set to "True" (not case sensitive) OR if AdHoc is $false 
                    $UserName = $_."UserName"
                    $UserSrcPath = [STRING]::Format("{0}\{1}", ($_."UserSrcPath").TrimEnd("\"), $UserName)
                    $UserDstPath = [STRING]::Format("{0}\{1}", ($_."UserDstPath").TrimEnd("\"), $UserName)
                    # user Log file name 
                    $UserLogFileName = "$($TimeStamp)_$($UserName).log"
                    $UserRobocopyLogFileName = "$($TimeStamp)_$($UserName)_Robocopy.log"
                    $_."MigrationLog" = $UserLogFileName
                    Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Starting migration of user '$UserName'."
                    # If user source and destination paths exist 
                    if (Test-Path -Path $UserSrcPath) { 
                        
                        if ( ! (Test-Path -Path $UserDstPath)) { 
                            Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "UserDstPath does not exist! '$UserDstPath'"  
                            Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Create UserDstPath '$UserDstPath'"  
                            $return = [System.IO.Directory]::CreateDirectory($UserDstPath)

                        }
                        #if owner exist, we have to hijack the ownership.
                        Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "UserDstPath does exist! '$UserDstPath'"  

                        #Create new owner ship.
                        Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Hijack ownership of '$UserDstPath'" 
                        [System.Security.AccessControl.FileSystemSecurity]$UserDstPathACL = Get-ACL -Path $UserDstPath
                        [System.Security.Principal.IdentityReference]$mySecurityPrinciple = New-Object System.Security.Principal.NTAccount($env:UserDomain, $env:UserName)
                        $UserDstPathACL.SetOwner($mySecurityPrinciple)
                        Set-Acl -Path $UserDstPath -AclObject $UserDstPathACL
                        
                        #add write/read access to folder and subfolder/subfiles.
                        Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Hijack access rights of '$UserDstPath'" 
                        [System.Security.AccessControl.AccessRule]$myAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("$env:UserDomain\$env:UserName",'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                        $UserDstPathACL.AddAccessRule($myAccessRule)
                        Set-Acl -Path $UserDstPath -AclObject $UserDstPathACL
                        
                         # Define robocopy argument list 
                         $RobocopyArguments = @("`"$UserSrcPath`"", "`"$UserDstPath`"", "*.*", "/MIR", "/R:5", "/W:10", "/LOG+:`"$logDirectory\$UserRobocopyLogFileName`"")
                         # Logging 
                         Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Starting robocopy with arguments '$($RobocopyArguments -join ' ')'."    
                         # Start robocopy job
                         $objProc = Start-Process -FilePath "C:\windows\System32\Robocopy.exe" -ArgumentList $RobocopyArguments -NoNewWindow -Wait -PassThru 
                         # analyse exit codes. normally everything bellow 8 is just a warning or success 
                         Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Robocopy exit code '$($objProc.ExitCode)'."  
                         if ($objProc.ExitCode -lt 8) {
                             Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Robocopy was successful." 
                             # Set LastMigration to Success and set date
                             $_."LastMigrationResult" = "SUCCESS"
                             $_."LastMigration" = $TimeStampForCSV
                             # If it was a AdHoc User migration, set MigrationActive to False 
                             if (($_."FinalizeMigration" -ieq "True")) {
                                 $_."MigrationActive" = "False"
                                 $_."LastMigration" = $TimeStampForCSV
                             }
                         } else {
                             Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Robocopy failed."
                             $_."LastMigrationResult" = "FAILED"
                             $_."LastMigration" = $TimeStampForCSV
                         }

                        #System and user principal have to be added, so wf can work.
                        Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Reset access rights for '$env:UserDomain\$UserName' to UserDstPath '$UserDstPath'" 
                        [System.Security.AccessControl.FileSystemSecurity]$UserDstPathACL = Get-ACL -Path $UserDstPath
                        [System.Security.Principal.IdentityReference]$userSecurityPrinciple = New-Object System.Security.Principal.NTAccount($env:UserDomain, $UserName)
                        [System.Security.AccessControl.AccessRule]$usersAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("$env:UserDomain\$UserName",'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                        [System.Security.AccessControl.AccessRule]$systemAccessRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM",'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                        
                        #Disable inheritance on user folder.
                        $UserDstPathACL.SetAccessRuleProtection($True, $false)                       
                        #Add user and system to acl.
                        $UserDstPathACL.AddAccessRule($usersAccessRule)
                        $UserDstPathACL.AddAccessRule($systemAccessRule)
                        Set-Acl -Path $UserDstPath -AclObject $UserDstPathACL

                        #Reset ownership for all folders to users principal.
                        Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Reset owner for '$env:UserDomain\$UserName' to UserDstPath '$UserDstPath'" 
                        (Get-ChildItem -Path $UserDstPath).Foreach{
                            $acl = Get-ACL -Path $_.Fullname
                            $acl.SetOwner($userSecurityPrinciple)
                            Set-Acl -Path $_.FullName -AclObject $acl
                        }
                        $UserDstPathACL.SetOwner($userSecurityPrinciple)
                        Set-Acl -Path $UserDstPath -AclObject $UserDstPathACL

                    }
                    else {
                        Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "UserSrcPath does not exist! '$UserSrcPath'"  
                            $_."LastMigrationResult" = "FAILED"
                            $_."LastMigration" = $TimeStampForCSV
                    }
                    Write-Log -LogFile "$($logDirectory)\$($UserLogFileName)" -Message "Migration of user '$UserName' finished."
                }
            }
            # throw the datasetitem $_ to pipe 
            $_ 
        }
        #endregion migration 

        #region Output
        Copy-Item -Path $ControlFile -Destination "$($ControlFile).$TimeStamp.bak"
        $OutputDataSet | ConvertTo-Csv -Delimiter ";" -NoTypeInformation | Set-Content -Path $ControlFile -Encoding UTF8 
        #endregion Output
    }catch {
        $PSCmdlet.WriteError($_)
    }
}
#endregion process