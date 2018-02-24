Param(
    [string]$migrationDirection="P2S"
)

# $cred = Get-Credential
 Add-AzureAccount

$vnet = ""
$subnet = ""

$subscriptionId = ""
$storageAcc=""
$cloudService = ""

Set-AzureSubscription -SubscriptionId $subscriptionId -CurrentStorageAccountName $storageAcc

$machines = Get-Content machinelist.txt

foreach($machineName in $machines)
{
       $attachedDrives = Get-AzureDisk |where {$_.AttachedTo -like "*$machineName*" }
       
       $vm = Get-AzureVM |where {$_.Name -eq "$machineName"}
       $vmSize = $vm.InstanceSize
       $vmCS = $vm.ServiceName
       $vmIP = $vm.IpAddress
       
       #check for S in instance Size
       if($vmSize -like "*DS*")
       {
        $vmSize = $vmSize.Replace("DS","D")
        Write-Host "Line Replaced"
       }

       $attachedDrives |select DiskName
       $vmSize
       $vmCS
       $vmIP

              #power down the Existing VM
       Write-Host "Power down VM"       
       Stop-AzureVM -Name $machineName -serviceName $vmCS -Force
       
       # move the drives
       $count = 0
       ForEach($drives in $attachedDrives)
       {
            
            $StorageAccSrc = $drives.MediaLink
            $DriveStorageAcc = $StorageAccSrc.DnsSafeHost.Split(".")
            $DriveStorageAcc[0]
            $StorageKey = (Get-AzureStorageKey -StorageAccountName $DriveStorageAcc[0]).Primary

            $blobName = $StorageAccSrc.Segments[2]

            Write-Host "Copy disk "+$blobName


            # Source Storage Account Information #
            $sourceStorageAccountName = $DriveStorageAcc[0]
            $sourceKey = $StorageKey
            $sourceContext = New-AzureStorageContext �StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceKey  
            $sourceContainer = "vhds"

            # Destination Storage Account Information #
            $destinationStorageAccountName = ""
            $destinationKey = ""
            $destinationContext = New-AzureStorageContext �StorageAccountName $destinationStorageAccountName -StorageAccountKey $destinationKey  

            # Create the destination container #
            $destinationContainerName = "copiedvhds"
            New-AzureStorageContainer -Name $destinationContainerName -Context $destinationContext 

			# Wait 1 minute
			Start-Sleep -s 60
			
			# break the lease if it exists
			.\BreakBlobLease.ps1 -StorageAccountName $vmCS -ContainerName "vhds" -BlobName $blobName
			
            # Copy the blob # 
            $blobCopy = Start-AzureStorageBlobCopy -DestContainer $destinationContainerName `
                                    -DestContext $destinationContext `
                                    -SrcBlob $blobName `
                                    -Context $sourceContext `
                                    -SrcContainer $sourceContainer

            while(($blobCopy | Get-AzureStorageBlobCopyState).Status -eq "Pending")
            {
                Start-Sleep -s 3
                $blobCopy | Get-AzureStorageBlobCopyState
            }

			if(($blobCopy | Get-AzureStorageBlobCopyState).Status -eq "Failed")
			{			
				exit
			}
			
            $newDiskName = "https://"+$destinationStorageAccountName+".blob.core.windows.net/copiedvhds/"+$blobName

            If($count -eq 0)
            {
                $diskName = $machineName+"-Drive-"+$count
                Add-AzureDisk -DiskName $diskName -OS Windows -MediaLocation $newDiskName -Verbose
            }
            else
            {
                 $diskName = $machineName+"-Drive-"+$count
                 Add-AzureDisk -DiskName $diskName -MediaLocation $newDiskName -Verbose
           }
           $count++
            

       }

       $OSDrive = $machineName+"-Drive-0"
       $vmc = New-AzureVMConfig -Name $machineName -InstanceSize $vmSize -DiskName $OSDrive
       Add-AzureEndpoint -Protocol tcp -LocalPort 3389 -PublicPort 5842 -Name 'RDP' -VM $vmc
       Set-AzureSubnet $subnet -VM $vmc
       
       # remove disk 0 as this is part of the config command. Any remaining ones we add as dataDisks
       
       $dataDisks = $attachedDrives[1..($attachedDrives.Length-1)]
       
       $lun = 1
       foreach($diskName in $dataDisks.DiskName)
       {
              $diskName = $machineName+"-Drive-"+$lun
              Add-AzureDataDisk -Import $diskName -LUN $lun -VM $vmc
              $lun++
       }
       
       #remove the existing VM
       Remove-AzureVM -Name $machineName -serviceName $vmCS
       
       # found moving on immediately just upsets things, so we'll wait 2 minutes...
       Start-Sleep -s 120
       
       #create it again, and wait for it to powerup
       New-AzureVM -ServiceName $cloudService -VMs $vmc -VNetName $vnet
       $vmState = Get-AzureVM -Name $machineName -serviceName $cloudService
       while($vmState.Status -ne "ReadyRole")
       {
              Start-Sleep -s 10
              $vmState = Get-AzureVM -Name $machineName -serviceName $cloudService
       }

       # re-ip the server, then move on
       Get-AzureVM -Name $machineName -serviceName $cloudService | Set-AzureStaticVNetIP -IPAddress $vmIP
       
}
