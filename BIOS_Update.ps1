# This script checks the current BIOS version and compares it to the latest available version from the manufacturer. If an update is needed, it downloads and installs the update, then prompts the user to reboot. Requires Reboot Tool to be installed.
# https://github.com/damienvanrobaeys/Lenovo_BIOS_Auto_Update
# https://github.com/gwblok/garytown/blob/master/RunScripts/Update-HPBIOS.ps1
# https://github.com/MSEndpointMgr/Intune/tree/master/Firmware/Intune%20BIOS%20Update%20Control/BIOSUpdate_PR
# https://github.com/gwblok/garytown/blob/master/Intune/Update-HPCSML.ps1

[string]$Global:IntuneManagementExtensionPath = $(Join-Path -Path $env:ProgramData "Microsoft\IntuneManagementExtension\Logs")
[string]$Global:LogFilePath = $null
[string]$Global:LogFilePath = $(Join-Path -Path $IntuneManagementExtensionPath -ChildPath 'BIOS_Update.log')

[string]$Global:RebootPath = "$(${env:ProgramFiles(x86)})\SPIE\Reboot\"

[string]$Global:HpBIOSPassword = $null
[string]$Global:LenovoBIOSPassword = $null

function Write-Log
{
    Param(
        [Parameter(
            Mandatory = $true,
            ValueFromPipeline = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogText,

        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [string]$Component = '',

        [Parameter(Mandatory = $false)]
        [ValidateSet('Information','Warning','Error')]
        [string]$Type = 'Information',

        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [int]$Thread = $PID,

        [Parameter(Mandatory = $false)]
        [ValidateNotNull()]
        [string]$File = '',

        [Parameter(Mandatory = $false)]
        [int]$LogMaxSize = 2.5MB,

        [Parameter(Mandatory = $false)]
        [int]$LogMaxHistory = 1
    )
    
    Begin
    {
        switch ($Type)
        {
            'Information' { $TypeNum = 1 }
            'Warning'     { $TypeNum = 2 }
            'Error'       { $TypeNum = 3 }
        }
    
        if (-not $Global:LogFilePath) {
            Write-Error -Message 'Variable $LogFilePath not defined in scope $Global:'
            exit 1
        }
        
        if (-not (Test-Path -Path $Global:LogFilePath -PathType Leaf)) {
            New-Item -Path $Global:LogFilePath -ItemType File -ErrorAction Stop | Out-Null
        }
        
        $LogFile = Get-Item -Path $Global:LogFilePath
        if ($LogFile.Length -ge $LogMaxSize) {
            $ArchiveLogFiles = Get-ChildItem -Path $LogFile.Directory -Filter "$($LogFile.BaseName)*.log" | Where-Object {$_.Name -match "$($LogFile.BaseName)-\d{8}-\d{6}\.log"} | Sort-Object -Property BaseName
            if ($ArchiveLogFiles.Count -gt $LogMaxHistory) {
                $ArchiveLogFiles | Select-Object -Skip ($ArchiveLogFiles.Count - $LogMaxHistory) | Remove-Item
            }

            $NewFileName = "{0}-{1:yyyyMMdd-HHmmss}{2}" -f $LogFile.BaseName, $LogFile.LastWriteTime, $LogFile.Extension
            $LogFile | Rename-Item -NewName $NewFileName
            New-Item -Path $Global:LogFilePath -ItemType File -ErrorAction Stop | Out-Null
        }
    }
    
    Process
    {
        $now = Get-Date
        $Bias = ($now.ToUniversalTime() - $now).TotalMinutes
        [string]$Line = "<![LOG[{0}]LOG]!><time=`"{1:HH:mm:ss.fff}{2}`" date=`"{1:MM-dd-yyyy}`" component=`"{3}`" context=`"`" type=`"{4}`" thread=`"{5}`" file=`"{6}`">" -f $LogText, $now, $Bias, $Component, $TypeNum, $Thread, $File
        $Line | Out-File -FilePath $Global:LogFilePath -Encoding utf8 -Append -ErrorAction Stop
    }
    
    End
    {
    }
}

function Check-RebootPending {
    function Test-RegistryValue {
        param (
            [parameter(Mandatory)][string]$Path,
            [parameter(Mandatory)][string]$Value
        )
        try {
            Get-ItemProperty -Path $Path -Name $Value -ErrorAction Stop | Out-Null
            $true
        } catch {
            $false
        }
    }

    $PendingReboot = $false

    # Registry keys to check
    $keys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\PostRebootReporting",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\ServerManager\CurrentRebootAttempts"
    )

    # Registry values to check
    $values = @(
        @{ Path="HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing"; Name="RebootInProgress" },
        @{ Path="HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing"; Name="PackagesPending" },
        @{ Path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Name="PendingFileRenameOperations" },
        @{ Path="HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager"; Name="PendingFileRenameOperations2" },
        @{ Path="HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"; Name="DVDRebootSignal" },
        @{ Path="HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon"; Name="JoinDomain" },
        @{ Path="HKLM:\SYSTEM\CurrentControlSet\Services\Netlogon"; Name="AvoidSpnSet" }
    )

    # Check keys
    foreach ($key in $keys) {
        if (Test-Path $key) {
            #Write-Host $key
            $PendingReboot = $true
        }
    }

    # Check values
    foreach ($item in $values) {
        if (Test-RegistryValue -Path $item.Path -Value $item.Name) {
            #Write-Host "$($item.Path) > $($item.Name)"
            $PendingReboot = $true
        }
    }

    return $PendingReboot
}

function Show-ToastMessage(){
	$Component = "ToastMessage"
	
	$ToastScript = Join-Path -Path $Global:RebootPath -ChildPath "Remediate-ToastNotification.ps1"
	$BIOSConfig = Join-Path -Path $Global:RebootPath -ChildPath "config-toast-biosupdate.xml"
	$PSInvoker = Join-Path -Path $Global:RebootPath -ChildPath "PSInvoker.exe"
	$TaskName = 'TempToast'
	
	Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false

	$TaskAction = New-ScheduledTaskAction -Execute $PSInvoker -Argument "`"$ToastScript`" `"$BIOSConfig`""
	$TaskPrincipal = New-ScheduledTaskPrincipal -GroupId S-1-5-32-545
	$Task = New-ScheduledTask -Action $TaskAction -Principal $TaskPrincipal

	$ScheduledTask = $null
	try {
		Write-Log -Component $Component -LogText "Trying to show toast notification"
		$ScheduledTask = Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -InputObject $Task
		Start-ScheduledTask -InputObject $ScheduledTask
	} finally {
		if ($ScheduledTask) {
			Unregister-ScheduledTask -InputObject $ScheduledTask -Confirm:$false
		}
	}
	
	Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
}

# Check pending reboot
if(Check-RebootPending -contains $true){
	Write-Log -Component $Component -LogText "Pending Reboot. Aborting BIOS update."
    #Write-Log -Component $Component -LogText "Pending Reboot."
    #exit 1
}

# --- AC POWER CHECK ---
try {
	$Component = "AC POWER CHECK"
    $PowerStatus = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue

    if ($PowerStatus) {
        # BatteryStatus 2 = Charging, 6 = Charging and High, 7 = Charging and Low, 8 = Charging and Critical
        if ($PowerStatus.BatteryStatus -notin 2,6,7,8) {
            Write-Log -Component $Component -LogText "Device is NOT connected to AC power. Aborting BIOS update."
            exit 1
        }
    }
    else {
        Write-Log -Component $Component -LogText "No battery detected (likely desktop) -> continuing"
    }
}
catch {
    Write-Log -Component $Component -LogText "Could not determine power status: $_"
    exit 1
}

$Manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer

if ($Manufacturer -match "HP")
{
	# --- HPCMSL ---
	Import-Module HPCMSL -ErrorAction SilentlyContinue

	if (-not (Get-Module HPCMSL))
	{
		$Component = "HPCMSL"
		Write-Log -Component $Component -LogText "HPCMSL not available"
		exit 1
	}

	try {
		$Component = "HP BIOS"
		[version]$BIOSVersion = Get-HPBIOSVersion
		$LatestHPBIOS = Get-HPBIOSUpdates -Latest

		if ($BIOSVersion -ge [version]$LatestHPBIOS.Ver)
		{
			Write-Log -Component $Component -LogText "BIOS is already up-to-date: $BIOSVersion"
			exit 0
		}
		
		if ([datetime]$LatestHPBIOS.Date -le (Get-Date).AddDays(-14)) {
			#Write-Output "BIOS update is at least 2 weeks old"
		} else {
			Write-Log -Component $Component -LogText "BIOS update is newer than 2 weeks. Not installing yet!"
			exit 0
		}

		Write-Log -Component $Component -LogText "Updating BIOS: $BIOSVersion -> $($LatestHPBIOS.Ver)"

		$BIOSPassSet = Get-HPBIOSSetupPasswordIsSet

		if ($BIOSPassSet)
		{
			#Get-HPBIOSUpdates -Flash -Quiet -Yes -Password $Global:HpBIOSPassword
			Write-Log -Component $Component -LogText "BIOS has password" -Type Error
			exit 1
		}
		else
		{
			Get-HPBIOSUpdates -Flash -Quiet -Yes -BitLocker Suspend
		}

		Write-Log -Component $Component -LogText "BIOS update staged successfully"

		try {   
			Show-ToastMessage
		}
		catch {
			Write-Log -Component $Component -LogText "Toast notification failed: $_" -Type Error
		}

		# Give firmware staging time
		#Start-Sleep -Seconds 30

		# --- FORCED REBOOT ---
		#shutdown.exe /r /t 60 /c "BIOS update installed. System will reboot to complete the update." /f

		exit 0
	}
	catch {
		Write-Log -Component $Component -LogText "Error during remediation: $_" -Type Error
		exit 1
	}
} elseif ($Manufacturer -eq "lenovo"){

    $Component = "Lenovo BIOS"
	
	$WMI_computersystem = Get-CimInstance Win32_ComputerSystem
    $Get_MTM = ($WMI_computersystem.Model.SubString(0, 4)).Trim()
	
	$OS_Ver = (Get-ciminstance Win32_OperatingSystem).Caption
	If($OS_Ver -like "*10*"){$WindowsVersion = "win10"}ElseIf($OS_Ver -like "*11*"){$WindowsVersion = "win11"}
	$CatalogUrl = "https://download.lenovo.com/catalog/$Get_MTM`_$WindowsVersion.xml"
	[System.Xml.XmlDocument]$CatalogXml = $null
	try	{
		$CatalogXml = (New-Object -TypeName System.Net.WebClient).DownloadString($CatalogUrl)
	}
	catch {	
		Write-Log -Component $Component -LogText "Can not get BIOS Catalog info from Lenovo: $_" -Type Error
		exit 1 		
	}
	
	$PackageUrls = ($CatalogXml.packages.ChildNodes | Where-Object { $_.category -match "BIOS UEFI" }).location | Sort-Object | Select-Object -Last 1
	[System.Xml.XmlDocument]$PackageXml = $null
	if(($null -ne $PackageUrls) -and ($PackageUrls.Count -eq 1))
	{
		$PackageXml = (New-Object -TypeName System.Net.WebClient).DownloadString($PackageUrls)		
	} else {	
		Write-Log -Component $Component -LogText "No BIOS Packages found for Lenovo model $Get_MTM" -Type Error
		exit 1 			
	}
	
	$baseUrl = $PackageUrls.Substring(0,$PackageUrls.LastIndexOf('/')+1)
	$LatestHPBIOS = $PackageXml.Package	
	if($null -eq $LatestHPBIOS)	{
		Write-Log -Component $Component -LogText "Can not get BIOS info from Lenovo: $_" -Type Error
		exit 1
	}
	
	if ([datetime]$LatestHPBIOS.ReleaseDate -gt (Get-Date).AddDays(-14)) {
		Write-Log -Component $Component -LogText "BIOS update is newer than 2 weeks. Not installing yet!"
		exit 0
	}
	
	$BIOS_info = get-ciminstance win32_bios | Select-Object *
	$BIOS_Maj_Version = $BIOS_info.SystemBiosMajorVersion 
	$BIOS_Min_Version = $BIOS_info.SystemBiosMinorVersion 
	$BIOSVersion = "$BIOS_Maj_Version.$BIOS_Min_Version"
	
	$LatestHPBIOSVersion = $LatestHPBIOS.version

	if([System.Version]$LatestHPBIOSVersion -gt [System.Version]$BIOSVersion) {
		
		Write-Log -Component $Component -LogText "Downloading BIOS: $LatestHPBIOSVersion"
		Invoke-WebRequest -Uri ($baseUrl + $PackageXml.Package.Files.Installer.File.Name) -OutFile ("$($env:windir)\Temp\" + "Lenovo_BIOS_Update_$($LatestHPBIOSVersion).exe")
		If(Test-Path ("$($env:windir)\Temp\" + "Lenovo_BIOS_Update_$($LatestHPBIOSVersion).exe")){
			Write-Log -Component $Component -LogText "Updating BIOS: $BIOSVersion -> $LatestHPBIOSVersion"
			$Extract_Folder_Path = $null
			try	{
                Write-Log -Component $Component -LogText "Trying to extract BIOS update"
                $Extract_Folder_Path = "$($env:windir)\Temp\" + "Lenovo_BIOS_Update_$($LatestHPBIOSVersion)"
				Start-Process -FilePath ("$($env:windir)\Temp\" + "Lenovo_BIOS_Update_$($LatestHPBIOSVersion).exe") -ArgumentList "/VERYSILENT /DIR=$Extract_Folder_Path /EXTRACT=YES" -PassThru -Wait
				
                $FlashSwitches = " /S"
                if ($Global:LenovoBIOSPassword)
		        {
                    $FlashSwitches = $FlashSwitches + " /pass:$($Global:LenovoBIOSPassword)"
			        Write-Log -Component $Component -LogText "BIOS has password" -Type Error
			        exit 1
		        }

                $WinUPTPUtility = $null
                if ([Environment]::Is64BitOperatingSystem) {
                    $WinUPTPUtility = Get-ChildItem -Path $Extract_Folder_Path -Filter "*.exe" -Recurse | Where-Object { $_.Name -like "WinUPTP64.exe" } | Select-Object -ExpandProperty FullName
                }

                if (!($WinUPTPUtility)) {
                    $WinUPTPUtility = Get-ChildItem -Path $Extract_Folder_Path -Filter "*.exe" -Recurse | Where-Object { $_.Name -like "WinUPTP.exe" } | Select-Object -ExpandProperty FullName
                }

                if(Test-Path $WinUPTPUtility){
                    Write-Log -Component $Component -LogText "Disable BitLocker for one reboot"
				    #& cmd.exe /c "manage-bde -protectors -disable C:"
                    if ((Manage-Bde -Status C:) -match "Protection On") {
                        Suspend-BitLocker -MountPoint "$($env:SystemDrive)" -RebootCount 1
                    }

                    Write-Log -Component $Component -LogText "Tryig to install BIOS Update: $WinUPTPUtility $FlashSwitches"
                    $FlashProcess = Start-Process -FilePath $WinUPTPUtility -ArgumentList "$FlashSwitches" -Passthru -Wait

                    Write-Log -Component $Component -LogText "BIOS Update installed with exit code: $($FlashProcess.ExitCode)"
                }
				
				try {   
					Show-ToastMessage
				}
				catch {
					Write-Log -Component $Component -LogText "Toast notification failed: $_" -Type Error
				}
			}
			catch {
				Write-Log -Component $Component -LogText "Error during last BIOS action" -Type Error
                
                $BLinfo = Get-Bitlockervolume | Where-Object { $_.MountPoint -eq $env:SystemDrive}
                if($blinfo.ProtectionStatus -ne 'On'){
                    Write-Host "Enable Bitlocker"
                    Resume-BitLocker -MountPoint ($BLinfo.MountPoint)
                }

                if($Extract_Folder_Path){
					Remove-Item -Path $Extract_Folder_Path -Force -Recurse -ErrorAction SilentlyContinue
				}
				Remove-Item -Path ("$($env:windir)\Temp\" + "Lenovo_BIOS_Update_$($LatestHPBIOSVersion).exe") -Force -ErrorAction SilentlyContinue

				exit 1
			} finally {
				if($Extract_Folder_Path){
					Remove-Item -Path $Extract_Folder_Path -Force -Recurse -ErrorAction SilentlyContinue
				}
				Remove-Item -Path ("$($env:windir)\Temp\" + "Lenovo_BIOS_Update_$($LatestHPBIOSVersion).exe") -Force -ErrorAction SilentlyContinue
			}
		}
		
	} else {
		Write-Log -Component $Component -LogText "BIOS is already up-to-date: $BIOSVersion"
		exit 0
	}
		
} else {
	$Component = "Manufacturer"
    Write-Log -Component $Component -LogText "Not a HP or Lenovo device: $Manufacturer"
    exit 0
}