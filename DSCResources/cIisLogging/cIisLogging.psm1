function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $LogPath
    )

    # assumption: if log file mode is Site, we should get and set settings in /sites/siteDefaults/logFile. If Server, /log

    $currentLogSettings = Get-WebConfiguration -Filter '/system.applicationHost/log'

    Write-Verbose -Message "Get-TargetResource has been run."

    $LogFileMode = [System.String]$currentLogSettings.centralLogFileMode
    if ($null -eq $LogFileMode -or $LogFileMode -eq "Site")
    {
        $LogFileMode = "Site"
        $currentLogSettings = Get-WebConfiguration -Filter '/system.applicationHost/sites/siteDefaults/logFile'
        $returnValue = @{
            LogPath     = $currentLogSettings.directory
            LogFlags    = [System.String[]]$currentLogSettings.logExtFileFlags
            LogFileMode = "Site"
            LogFormat   = $currentLogSettings.logFormat
        }
    }
    else
    {
        $LogFormat = $LogFileMode.Replace("Central", "")
        $LogFileMode = "Server"
        $LogFlags = $null
        if ($null -ne $currentLogSettings.centralW3CLogFile)
        {
            $LogFlags = [System.String[]]$currentLogSettings.centralW3CLogFile.logExtFileFlags
        }
        
        $returnValue = @{
            LogPath     = (Get-WebConfigurationProperty -Filter ("/system.applicationHost/log/central{0}LogFile" -f $LogFormat) -Name directory).Value
            LogFlags    = $LogFlags
            LogFileMode = $LogFileMode
            LogFormat   = $LogFormat
        }
    }

    $returnValue
    
}


function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $LogPath,

        [ValidateSet("Date","Time","ClientIP","UserName","SiteName","ComputerName","ServerIP","Method","UriStem","UriQuery","HttpStatus","Win32Status","BytesSent","BytesRecv","TimeTaken","ServerPort","UserAgent","Cookie","Referer","ProtocolVersion","Host","HttpSubStatus")]
        [System.String[]]
        $LogFlags,

        [ValidateSet("Site","Server")]
        [System.String]
        $LogFileMode,

        [ValidateSet("IIS","W3C","NCSA","Binary")]
        [System.String]
        $LogFormat
    )

    # rules to enforce:
    # if using LogFlags, LogFormat must be W3C
    # for LogFileMode "Server", valid LogFormats are "W3C" and "Binary"
    # for LogFileMode "Site", valid LogFormats are "W3C", "IIS", and "NCSA"
    # if LogFlags are specified, set LogFormat to W3C

    # should we have default values in certain scenarios? for example:
    # if LogFileMode is server and no LogFormat specified, LogFormat = W3C
    # if LogFileMode is site and no LogFormat specified, if LogFlags specified, LogFormat = W3C

    $currentLogState = Get-TargetResource -LogPath $LogPath

    # validation:
    if ($PSBoundParameters.ContainsKey('LogFlags'))
    {
        if ($PSBoundParameters.ContainsKey('LogFormat'))
        {
            if ($LogFormat -ne 'W3C')
            {
                Write-Verbose -Message "Specified LogFormat $LogFormat, but since LogFlags were specified, overriding LogFormat to W3C to support flags."
                $LogFormat = 'W3C'
            }
        }
        elseif ($currentLogState.LogFormat -ne 'W3C')
        {
            Write-Verbose -Message "Current LogFormat $LogFormat does not support LogFlags. Changing LogFormat to W3C to support requested log flags."
            $PSBoundParameters.Add('LogFormat', 'W3C')
        }
    }

    # figure out if we're dealing with Site or Server filemode first, as this will affect where we make changes
    if ($PSBoundParameters.ContainsKey('LogFileMode') -and ($LogFileMode -ne $currentLogState.LogFileMode))
    {
        Write-Verbose -Message ("LogFileMode '{0}' is not in the desired state '{1}' and will be updated" -f $currentLogState.LogFileMode, $LogFileMode)
        # Server will be either CentralW3C or CentralBinary. Site will be Site.
        if ($LogFileMode -eq "Server")
        {
            $centralLogFileMode = "Central{0}" -f $currentLogState.LogFormat

            if ($PSBoundParameters.ContainsKey('LogFormat'))
            {
                if (($LogFormat -ne 'W3C') -and ($LogFormat -ne 'Binary'))
                {
                    # throw exception not allowed combination of params
                    throw "LogFileMode 'Server' not allowed with LogFormat '$LogFormat'"
                }
                
                $centralLogFileMode = "Central$LogFormat"

                # let's remove LogFormat from the bound parameters so it won't be processed again.
                $PSBoundParameters.Remove('LogFormat')
            }
            else
            {
                # we're changing to Server log file mode but didn't specify log format. assume W3C since Binary would not have been valid in site mode
                $centralLogFileMode = "CentralW3C"
            }
            
            Set-WebConfigurationProperty '/system.applicationHost/log' -Name centralLogFileMode -Value $centralLogFileMode
        }
        else
        {
            Set-WebConfigurationProperty '/system.applicationHost/log' -Name centralLogFileMode -Value $LogFileMode
        }
        
        Write-Verbose -Message "Refreshing current log state variable from Get-TargetResource"
        $currentLogState = Get-TargetResource -LogPath $LogPath
    }

    # $currentLogFileMode now contains the new file mode (or current unchanged)
    # UPDATE: let's just keep currentLogState up to date?

    # Update LogFormat if needed
    if ($PSBoundParameters.ContainsKey('LogFormat') -and ($LogFormat -ne $currentLogState.LogFormat))
    {
        # if we just changed file mode to server, we shouldn't be here since we removed it above.
        # we still need to handle the case where filemode was already Server and log format is changing 
        if ($currentLogState.LogFileMode -eq "Server")
        {
            Write-Verbose -Message "Server level LogFormat is not in the desired state and will be updated"
            if (($LogFormat -ne 'W3C') -and ($LogFormat -ne 'Binary'))
            {
                # throw exception not allowed combination of params
                throw "LogFileMode 'Server' not allowed with LogFormat '$LogFormat'"
            }

            Set-WebConfigurationProperty "/system.applicationHost/log" -Name centralLogFile -Value ("Central{0}" -f $LogFormat)
        }
        else
        {
            Write-Verbose -Message "Site default level LogFormat is not in the desired state and will be updated"
            if ($LogFormat -eq 'Binary')
            {
                throw "LogFileMode 'Site' not allowed with LogFormat '$LogFormat'"
            }
            Set-WebConfigurationProperty '/system.applicationHost/sites/siteDefaults/logfile' -Name logFormat -Value $LogFormat
        }

        $currentLogState = Get-TargetResource -LogPath $LogPath
    }

    # If flags are passed in, let's assume format should be W3C.
    # If flags and format -ne W3C passed in, change desired foramt to W3C and output warning
    if ($PSBoundParameters.ContainsKey('LogFlags') -and (-not (Compare-LogFlags -LogFlags $LogFlags)))
    {
        Write-Verbose -Message "LogFlags not in desired state and will be updated"
        if ($currentLogState.LogFileMode -eq 'Server')
        {
            Set-WebConfigurationProperty '/system.applicationHost/log/centralW3CLogFile' -Name logExtFileFlags -Value ($LogFlags -join ',')
        }
        else
        {
            Set-WebConfigurationProperty '/system.applicationHost/sites/siteDefaults/logfile' -Name logExtFileFlags -Value ($LogFlags -join ',')
        }

        # finally, check to see if flags need to be updated
    }

    if ($PSBoundParameters.ContainsKey('LogPath') -and ($LogPath -ne $currentLogState.LogPath))
    {
        Write-Verbose -Message "LogPath not in desired state and will be updated"
        if ($currentLogState.LogFileMode -eq 'Server')
        {
            Set-WebConfigurationProperty ('/system.applicationHost/log/central{0}LogFile' -f $currentLogState.LogFormat) -Name directory -Value $LogPath
        }
        else
        {
            Set-WebConfigurationProperty '/system.applicationHost/sites/siteDefaults/logfile' -Name directory -Value $LogPath
        }
    }
    
}


function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [System.String]
        $LogPath,

        [ValidateSet("Date","Time","ClientIP","UserName","SiteName","ComputerName","ServerIP","Method","UriStem","UriQuery","HttpStatus","Win32Status","BytesSent","BytesRecv","TimeTaken","ServerPort","UserAgent","Cookie","Referer","ProtocolVersion","Host","HttpSubStatus")]
        [System.String[]]
        $LogFlags,

        [ValidateSet("Site","Server")]
        [System.String]
        $LogFileMode,

        [ValidateSet("IIS","W3C","NCSA","Binary")]
        [System.String]
        $LogFormat
    )

    $currentLogState = Get-TargetResource -LogPath $LogPath
    $result = $true
        
    # Check LogFormat
    if ($PSBoundParameters.ContainsKey('LogFormat'))
    {
        # Warn if LogFlags are passed in and Desired LogFormat is not W3C
        if ($PSBoundParameters.ContainsKey('LogFlags') -and $LogFormat -ne 'W3C')
        {
            Write-Verbose -Message "You specified LogFlags and a LogFormat of '$LogFormat'. LogFormat needs to be 'W3C' to support LogFlags"
        }
            
        # Check LogFormat 
        if ($LogFormat -ne $currentLogState.LogFormat)
        {
            Write-Verbose -Message "LogFormat does not match desired state."
            $result = $false 
        }
    }
        
    # Check LogFlags
    if ($PSBoundParameters.ContainsKey('LogFlags') -and `
        (-not (Compare-LogFlags -LogFlags $LogFlags)))  
    {
        Write-Verbose -Message ("LogFlags does not match desired state.")
        $result = $false
    }
            
    # Check LogPath
    if ($PSBoundParameters.ContainsKey('LogPath') -and `
        ($LogPath -ne $currentLogState.LogPath))
    { 
        Write-Verbose -Message ("LogPath does not match desired state.")
        $result = $false 
    }
    
    return $result
}

function Compare-LogFlags
{
    [CmdletBinding()]
    [OutputType([Boolean])]
    param
    (
        [ValidateSet('Date','Time','ClientIP','UserName','SiteName','ComputerName','ServerIP','Method','UriStem','UriQuery','HttpStatus','Win32Status','BytesSent','BytesRecv','TimeTaken','ServerPort','UserAgent','Cookie','Referer','ProtocolVersion','Host','HttpSubStatus')]
        [String[]] $LogFlags
    )

    $currentLogState = Get-TargetResource -LogPath "This doesn't matter"

    $currentLogFlags = $currentLogState.LogFlags -split ',' | Sort-Object

    $proposedLogFlags = $LogFlags -split ',' | Sort-Object

    if (Compare-Object -ReferenceObject $currentLogFlags `
                       -DifferenceObject $proposedLogFlags)
    {
        return $false
    }
    
    return $true

}


Export-ModuleMember -Function *-TargetResource

