$LogFile = ".\logs\$(Get-Date -Format yyyy-MM-dd_HH-mm-ss).log"
$CredentialFile = ".\snapraid-script.cred"
$ConfigFile = ".\snapraid-script.psd1"

Try {
    $Config = Import-PowerShellDataFile -Path $ConfigFile
    $Credential = Import-CliXml -Path $CredentialFile
} Catch {}

function Send-Notification {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)][ValidateNotNullOrEmpty()][ValidateSet("SUCCESS", "FAILURE")][String] $Status
    )

    if( $Credential -eq $Null ){
        return
    }

    $Params = @{
        Subject = ("[$Status] Snapraid report")
        SmtpServer = $Config.Email.SmtpServer
        Port = $Config.Email.Port
        UseSsl = $Config.Email.UseSsl
        From = $Config.Email.From
        To = $Config.Email.To
    }

    $RetryCount = 3
    Do {
        Try {
            Send-MailMessage @Params -Attachments $LogFile -Credential $Credential -ErrorAction Stop
            return
        } Catch {
            $RetryCount++
            Start-Sleep -Seconds 60
        }
    } Until( $RetryCount -lt 4 )
}

function Write-Log {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, ValueFromPipeline)][AllowEmptyString()][String] $Message
    )

    process {
        $Format = "[{0}]: {1}"
        $Stamp = (Get-Date).toString("yyyy/MM/dd HH:mm:ss:fff")
        $Message -split "\n+" | %{ $Format -f ($Stamp, $_) } | Write-Host
    }
}

function Write-Header {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)][String] $Value,
        [Parameter(Mandatory=$False)][Int] $Length = 48
    )

    $CenterOffset = ' ' * [math]::floor(($Length - $Value.Length) / 2)
    Write-Log ('-' * $Length)
    Write-Log ($CenterOffset + $Value)
    Write-Log ('-' * $Length)
}

function Write-ExecutionInfo {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)][ValidateNotNull()][PSCustomObject] $Info,
        [Parameter(Mandatory=$False)][Int] $Length = 48
    )

    Write-Log ('-' * $Length)
    Write-Log ("Duration: {0:g}" -f $Info.Duration)
    Write-Log ("ExitCode: {0}" -f $Info.ExitCode)
    Write-Log ('-' * $Length)
}

function Run-Snapraid {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)][ValidateNotNullOrEmpty()][String] $Command,
        [Parameter(Mandatory=$False)][ValidateNotNullOrEmpty()][String[]] $Params
    )

    Write-Header ("{0} {1} {2}" -f $Config.Snapraid.Executable,$Command,"$Params")
    
    $Output = ""
    $TimeSpan = Measure-Command {
        &$Config.Snapraid.Executable $Command $Params 2>&1 3>&1 4>&1 | %{ "$_" } | Tee-Object -Variable Output | Write-Log
    }

    $ExecutionInfo = [PSCustomObject]@{
        ExitCode = $LastExitCode
        Output = $Output
        Duration = $TimeSpan
    }

    Write-ExecutionInfo $ExecutionInfo

    if( $ExecutionInfo.ExitCode -eq 1 ){
        Write-Log "Execution of '$Command' failed! Aborting."
        Finalize -Status "FAILURE"
    }

    return $ExecutionInfo
}

function Get-Diff-Info {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True, ValueFromPipeline)][ValidateNotNull()][PSCustomObject] $ExecutionInfo
    )

    process {
        $DiffInfo = @{}
        
        $Regex = "^\s*(\d+)\s+(equal|added|removed|updated|moved|copied|restored)\s*$"
        $ExecutionInfo.Output | Select-String $Regex -AllMatches | %{ $_.Matches[0] } | %{ $DiffInfo[$_.Groups[2].Value] = [int]$_.Groups[1].Value }
        if( $DiffInfo.Keys.Count -eq 0 ) {
            Write-Log "Diff command parsing failed!"
            return $Null
        }

        $NumberOfChanges = ($DiffInfo.GetEnumerator() | Where-Object Key -notin "equal" | %{ $_.Value } | Measure-Object -Sum).Sum
        $DiffInfo["total_changes"] = $NumberOfChanges

        # Sync needed when there was any file changes or if 'diff' command returns 'sync required' exitcode (2)
        $DiffInfo["needs_sync"] = ( &{ if( $NumberOfChanges -gt 0 -or $ExecutionInfo.ExitCode -eq 2 ) {$True} Else {$False}} )

        return $DiffInfo
    }
}

function Initialize {
    Start-Transcript -Path $LogFile

    if( $Config -eq $Null ) {
        Write-Log "Failed to read configuration file!"
        Stop-Transcript | Out-Null
        Exit
    }
    
    if( $Config.Notification.OnSuccess -eq $True -or $Config.Notification.OnFailure -eq $True ) {
        if( $Credential -eq $Null ) {
            Write-Log "$CredentialFile file not found!"
            Write-Log "Prompting user for new credentials..."
        
            $Credential = Get-Credential -Message "Enter your smtp username and password:"
            if( $Credential -eq $Null ) {
                Write-Log "Canceled by user"
                Exit
            }

            $Credential | Export-Clixml -Path $CredentialFile
            
            Write-Log "Sending test notification..."
            Finalize -Status "SUCCESS"
        }
    }
}

function Finalize {
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory=$True)][ValidateNotNullOrEmpty()][ValidateSet("SUCCESS", "FAILURE")][String] $Status
    )

    Stop-Transcript | Out-Null

    if( $Config.Notification.OnSuccess -eq $False -and $Status -eq "SUCCESS" ) {
        Exit
    } elseif( $Config.Notification.OnFailure -eq $False -and $Status -eq "FAILURE" ) {
        Exit
    }

    Send-Notification -Status $Status
    Exit
}

Initialize

$DiffInfo = Run-Snapraid -Command "diff" | Get-Diff-Info

if( $DiffInfo -eq $Null ) {
    Finalize -Status "FAILURE"
} elseif( $DiffInfo["removed"] -gt $Config.Snapraid.Diff.DeleteThreshold ) {
    Write-Log ("Number of removed files exceeds configured threshold! ({0} > {1})" -f $DiffInfo["removed"],$Config.Snapraid.Diff.DeleteThreshold)
    Finalize -Status "FAILURE"
} 

if( $DiffInfo["needs_sync"] -eq $True ) {
    Run-Snapraid -Command "sync"
}

Run-Snapraid -Command "scrub" -Params "--plan",$Config.Snapraid.Scrub.Plan,"--older-than",$Config.Snapraid.Scrub.OlderThan | Out-Null
Run-Snapraid -Command "status" | Out-Null

Finalize -Status "SUCCESS"