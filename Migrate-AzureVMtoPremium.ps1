<#
.Synopsis
This script is provided as an EXAMPLE to show how to migrate a vm from a standard storage account to a premium storage account. You can customize it according to your specific requirements.

.Description
The script will copy the vhds (page blobs) of the source vm to the new storage account.
And then it will create a new vm from these copied vhds based on the inputs that you specified for the new VM.
You can modify the script to satisfy your specific requirement but please be aware of the items specified
in the Terms of Use section.

cloud service: deadpool2016
VM Name: deadp


.Terms of Use
Copyright © 2015 Microsoft Corporation.  All rights reserved.

THIS CODE AND ANY ASSOCIATED INFORMATION ARE PROVIDED “AS IS” WITHOUT WARRANTY OF ANY KIND,
EITHER EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY
AND/OR FITNESS FOR A PARTICULAR PURPOSE. THE ENTIRE RISK OF USE, INABILITY TO USE, OR
RESULTS FROM THE USE OF THIS CODE REMAINS WITH THE USER.

.Example (Save this script as Migrate-AzureVM.ps1)

.\Migrate-AzureVM.ps1 -SourceServiceName CurrentServiceName -SourceVMName CurrentVMName –DestStorageAccount newpremiumstorageaccount -DestServiceName NewServiceName -DestVMName NewDSVMName -DestVMSize "Standard_DS2" –Location “Southeast Asia”

.Link
To find more information about how to set up Azure PowerShell, refer to the following links.
http://azure.microsoft.com/documentation/articles/powershell-install-configure/
http://azure.microsoft.com/documentation/articles/storage-powershell-guide-full/
http://azure.microsoft.com/blog/2014/10/22/migrate-azure-virtual-machines-between-storage-accounts/

#>

Param(
# the cloud service name of the VM.
[Parameter(Mandatory = $true)]
[string] $SourceServiceName,

# The VM name to copy.
[Parameter(Mandatory = $true)]
[String] $SourceVMName,

# The destination storage account name.
[Parameter(Mandatory = $true)]
[String] $DestStorageAccount,

# The destination cloud service name
[Parameter(Mandatory = $true)]
[String] $DestServiceName,

# the destination vm name
[Parameter(Mandatory = $true)]
[String] $DestVMName,

# the destination vm size
[Parameter(Mandatory = $true)]
[String] $DestVMSize,

# the location of destination VM.
[Parameter(Mandatory = $true)]
[string] $Location,

# whether or not to copy the os disk, the default is only copy data disks
[Parameter(Mandatory = $false)]
[String] $DataDiskOnly = $true,

# how frequently to report the copy status in sceconds
[Parameter(Mandatory = $false)]
[Int32] $CopyStatusReportInterval = 15,

# the name suffix to add to new created disks to avoid conflict with source disk names
[Parameter(Mandatory = $false)]
[String]$DiskNameSuffix = "-prem"

) #end param

#######################################################################
#  Verify Azure PowerShell module and version
#######################################################################

#import the Azure PowerShell module
Write-Host "`n[WORKITEM] - Importing Azure PowerShell module" -ForegroundColor Yellow
$azureModule = Import-Module Azure -PassThru

if ($azureModule -ne $null)
{
    Write-Host "`tSuccess" -ForegroundColor Green
}
else
{
    #show module not found interaction and bail out
    Write-Host "[ERROR] - PowerShell module not found. Exiting." -ForegroundColor Red
    Exit
}


#Check the Azure PowerShell module version
Write-Host "`n[WORKITEM] - Checking Azure PowerShell module verion" -ForegroundColor Yellow
If ($azureModule.Version -ge (New-Object System.Version -ArgumentList "0.8.14"))
{
    Write-Host "`tSuccess" -ForegroundColor Green
}
Else
{
    Write-Host "[ERROR] - Azure PowerShell module must be version 0.8.14 or higher. Exiting." -ForegroundColor Red
    Exit
}

#Check if there is an azure subscription set up in PowerShell
Write-Host "`n[WORKITEM] - Checking Azure Subscription" -ForegroundColor Yellow
$currentSubs = Get-AzureSubscription -Current
if ($currentSubs -ne $null)
{
    Write-Host "`tSuccess" -ForegroundColor Green
    Write-Host "`tYour current azure subscription in PowerShell is $($currentSubs.SubscriptionName)." -ForegroundColor Green
}
else
{
    Write-Host "[ERROR] - There is no valid azure subscription found in PowerShell. Please refer to this article http://azure.microsoft.com/documentation/articles/powershell-install-configure/ to connect an azure subscription. Exiting." -ForegroundColor Red
    Exit
}


#######################################################################
#  Check if the VM is shut down
#  Stopping the VM is a required step so that the file system is consistent when you do the copy operation.
#  Azure does not support live migration at this time..
#######################################################################

if (($sourceVM = Get-AzureVM –ServiceName $SourceServiceName –Name $SourceVMName) -eq $null)
{
    Write-Host "[ERROR] - The source VM doesn't exist in the current subscription. Exiting." -ForegroundColor Red
    Exit
}

# check if VM is shut down
if ( $sourceVM.Status -notmatch "Stopped" )
{
    Write-Host "[Warning] - Stopping the VM is a required step so that the file system is consistent when you do the copy operation. Azure does not support live migration at this time. If you’d like to create a VM from a generalized image, sys-prep the Virtual Machine before stopping it." -ForegroundColor Yellow
    $ContinueAnswer = Read-Host "`n`tDo you wish to stop $SourceVMName now? Input 'N' if you want to shut down the vm mannually and come back later.(Y/N)"
    If ($ContinueAnswer -ne "Y") { Write-Host "`n Exiting." -ForegroundColor Red;Exit }
    $sourceVM | Stop-AzureVM

    # wait until the VM is shut down
    $VMStatus = (Get-AzureVM –ServiceName $SourceServiceName –Name $vmName).Status
    while ($VMStatus -notmatch "Stopped")
    {
        Write-Host "`n[Status] - Waiting VM $vmName to shut down" -ForegroundColor Green
        Sleep -Seconds 5
        $VMStatus = (Get-AzureVM –ServiceName $SourceServiceName –Name $vmName).Status
    }
}

# exporting the sourve vm to a configuration file, you can restore the original VM by importing this config file
# see more information for Import-AzureVM
$workingDir = (Get-Location).Path
$vmConfigurationPath = $env:HOMEPATH + "\VM-" + $SourceVMName + ".xml"
Write-Host "`n[WORKITEM] - Exporting VM configuration to $vmConfigurationPath" -ForegroundColor Yellow
$exportRe = $sourceVM | Export-AzureVM -Path $vmConfigurationPath


#######################################################################
#  Copy the vhds of the source vm
#  You can choose to copy all disks including os and data disks by specifying the
#  parameter -DataDiskOnly to be $false. The default is to copy only data disk vhds
#  and the new VM will boot from the original os disk.
#######################################################################

$sourceOSDisk = $sourceVM.VM.OSVirtualHardDisk
$sourceDataDisks = $sourceVM.VM.DataVirtualHardDisks

# Get source storage account information, not considering the data disks and os disks are in different accounts
$sourceStorageAccountName = $sourceOSDisk.MediaLink.Host -split "\." | select -First 1
$sourceStorageKey = (Get-AzureStorageKey -StorageAccountName $sourceStorageAccountName).Primary
$sourceContext = New-AzureStorageContext –StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceStorageKey

# Create destination context
$destStorageKey = (Get-AzureStorageKey -StorageAccountName $DestStorageAccount).Primary
$destContext = New-AzureStorageContext –StorageAccountName $DestStorageAccount -StorageAccountKey $destStorageKey

# Create a container of vhds if it doesn't exist
if ((Get-AzureStorageContainer -Context $destContext -Name vhds -ErrorAction SilentlyContinue) -eq $null)
{
    Write-Host "`n[WORKITEM] - Creating a container vhds in the destination storage account." -ForegroundColor Yellow
    New-AzureStorageContainer -Context $destContext -Name vhds
}


$allDisksToCopy = $sourceDataDisks
# check if need to copy os disk
$sourceOSVHD = $sourceOSDisk.MediaLink.Segments[2]
if ($DataDiskOnly)
{
    # copy data disks only, this option requires to delete the source VM so that dest VM can boot
    # from the same vhd blob.
    $ContinueAnswer = Read-Host "`n`tMoving VM requires to remove the original VM (the disks and backing vhd files will NOT be deleted) so that the new VM can boot from the same vhd. Do you wish to proceed right now? (Y/N)"
    If ($ContinueAnswer -ne "Y") { Write-Host "`n Exiting." -ForegroundColor Red;Exit }
    $destOSVHD = Get-AzureStorageBlob -Blob $sourceOSVHD -Container vhds -Context $sourceContext
    Write-Host "`n[WORKITEM] - Removing the original VM (the vhd files are NOT deleted)." -ForegroundColor Yellow
    Remove-AzureVM -Name $SourceVMName -ServiceName $SourceServiceName

    Write-Host "`n[WORKITEM] - Waiting utill the OS disk is released by source VM. This may take up to several minutes."
    $diskAttachedTo = (Get-AzureDisk -DiskName $sourceOSDisk.DiskName).AttachedTo
    while ($diskAttachedTo -ne $null)
    {
        Start-Sleep -Seconds 10
        $diskAttachedTo = (Get-AzureDisk -DiskName $sourceOSDisk.DiskName).AttachedTo
    }

}
else
{
    # copy the os disk vhd
    Write-Host "`n[WORKITEM] - Starting copying os disk $($disk.DiskName) at $(get-date)." -ForegroundColor Yellow
    $allDisksToCopy += @($sourceOSDisk)
    $targetBlob = Start-AzureStorageBlobCopy -SrcContainer vhds -SrcBlob $sourceOSVHD -DestContainer vhds -DestBlob $sourceOSVHD -Context $sourceContext -DestContext $destContext -Force
    $destOSVHD = $targetBlob
}


# Copy all data disk vhds
# Start all async copy requests in parallel.
foreach($disk in $sourceDataDisks)
{
    $blobName = $disk.MediaLink.Segments[2]
    # copy all data disks
    Write-Host "`n[WORKITEM] - Starting copying data disk $($disk.DiskName) at $(get-date)." -ForegroundColor Yellow
    $targetBlob = Start-AzureStorageBlobCopy -SrcContainer vhds -SrcBlob $blobName -DestContainer vhds -DestBlob $blobName -Context $sourceContext -DestContext $destContext -Force
    # update the media link to point to the target blob link
    $disk.MediaLink = $targetBlob.ICloudBlob.Uri.AbsoluteUri
}

# Wait until all vhd files are copied.
$diskComplete = @()
do
{
    Write-Host "`n[WORKITEM] - Waiting for all disk copy to complete. Checking status every $CopyStatusReportInterval seconds." -ForegroundColor Yellow
    # check status every 30 seconds
    Sleep -Seconds $CopyStatusReportInterval
    foreach ( $disk in $allDisksToCopy)
    {
        if ($diskComplete -contains $disk)
        {
            Continue
        }
        $blobName = $disk.MediaLink.Segments[2]
        $copyState = Get-AzureStorageBlobCopyState -Blob $blobName -Container vhds -Context $destContext
        if ($copyState.Status -eq "Success")
        {
            Write-Host "`n[Status] - Success for disk copy $($disk.DiskName) at $($copyState.CompletionTime)" -ForegroundColor Green
            $diskComplete += $disk
        }
        else
        {
            if ($copyState.TotalBytes -gt 0)
            {
                $percent = ($copyState.BytesCopied / $copyState.TotalBytes) * 100
                Write-Host "`n[Status] - $('{0:N2}' -f $percent)% Complete for disk copy $($disk.DiskName)" -ForegroundColor Green
            }
        }
    }
}
while($diskComplete.Count -lt $allDisksToCopy.Count)

#######################################################################
#  Create a new vm
#  the new VM can be created from the copied disks or the original os disk.
#  You can ddd your own logic here to satisfy your specific requirements of the vm.
#######################################################################

# Create a vm from the existing os disk
if ($DataDiskOnly)
{
    $vm = New-AzureVMConfig -Name $DestVMName -InstanceSize $DestVMSize -DiskName $sourceOSDisk.DiskName
}
else
{
    $newOSDisk = Add-AzureDisk -OS $sourceOSDisk.OS -DiskName ($sourceOSDisk.DiskName + $DiskNameSuffix) -MediaLocation $destOSVHD.ICloudBlob.Uri.AbsoluteUri
    $vm = New-AzureVMConfig -Name $DestVMName -InstanceSize $DestVMSize -DiskName $newOSDisk.DiskName
}
# Attached the copied data disks to the new VM
foreach ($dataDisk in $sourceDataDisks)
{
    # add -DiskLabel $dataDisk.DiskLabel if there are labels for disks of the source vm
    $diskLabel = "drive" + $dataDisk.Lun
    $vm | Add-AzureDataDisk -ImportFrom -DiskLabel $diskLabel -LUN $dataDisk.Lun -MediaLocation $dataDisk.MediaLink
}

# Edit this if you want to add more custimization to the new VM
# $vm | Add-AzureEndpoint -Protocol tcp -LocalPort 443 -PublicPort 443 -Name 'HTTPs'
# $vm | Set-AzureSubnet "PubSubnet","PrivSubnet"

New-AzureVM -ServiceName $DestServiceName -VMs $vm -Location $Location