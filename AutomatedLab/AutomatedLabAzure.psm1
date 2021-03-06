$PSDefaultParameterValues = @{
    '*-Azure*:Verbose'      = $false
    '*-Azure*:Warning'      = $false
    'Import-Module:Verbose' = $false
}

function Update-LabAzureSettings
{
    # .ExternalHelp AutomatedLab.Help.xml
    if ((Get-PSCallStack).Command -contains 'Import-Lab')
    {
        $Script:lab = Get-Lab
    }
    elseif ((Get-PSCallStack).Command -contains 'Add-LabAzureSubscription')
    {
        $Script:lab = Get-LabDefinition
        if (-not $Script:lab)
        {
            $Script:lab = Get-Lab
        }
    }
    else
    {
        $Script:lab = Get-Lab -ErrorAction SilentlyContinue
    }

    if (-not $Script:lab)
    {
        $Script:lab = Get-LabDefinition
    }

    if (-not $Script:lab)
    {
        throw 'No Lab or Lab Definition available'
    }
}

function Add-LabAzureSubscription
{
    # .ExternalHelp AutomatedLab.Help.xml
    param (
        [string]$SubscriptionName,

        [string]$DefaultLocationName,

        [string]$DefaultStorageAccountName,

        [string]$DefaultResourceGroupName,

        [switch]$PassThru
    )

    Write-LogFunctionEntry
    Update-LabAzureSettings

    if (-not $script:lab)
    {
        throw 'No lab defined. Please call New-LabDefinition first before calling Set-LabDefaultOperatingSystem.'
    }

    #This needs to be loaded manually to import the required DLLs
    $minimumAzureModuleVersion = Get-LabConfigurationItem -Name MinimumAzureModuleVersion
    if (-not (Get-Module -Name AzureRM -ListAvailable | Where-Object Version -ge $minimumAzureModuleVersion))
    {
        throw "The Azure PowerShell module version $($minimumAzureModuleVersion) or greater is not available. Please install it: Install-Module AzureRM -Force"
    }

    Write-ScreenInfo -Message 'Adding Azure subscription data' -Type Info -TaskStart

        # Try to access Azure RM cmdlets. If credentials are expired, an exception will be raised
        $resources = Get-AzureRmResourceProvider -ErrorAction SilentlyContinue
        if (-not $resources)
        {
            Write-ScreenInfo -Message "No Azure context available. Please login to your Azure account in the next step."
            $null = Connect-AzureRmAccount -ErrorAction Stop
        }

        # Select the proper subscription before saving the profile
        if ($SubscriptionName)
        {
            [void](Set-AzureRmContext -Subscription $SubscriptionName -ErrorAction Stop)
        }
        $AzureRmProfile = Get-AzureRmContext

    Update-LabAzureSettings
    if (-not $script:lab.AzureSettings)
    {
        $script:lab.AzureSettings = New-Object AutomatedLab.AzureSettings
    }

    $script:lab.AzureSettings.DefaultRoleSize = Get-LabConfigurationItem -Name DefaultAzureRoleSize
    
    # Select the subscription which is associated with this AzureRmProfile
    $subscriptions = Get-AzureRmSubscription -WarningAction SilentlyContinue
    $script:lab.AzureSettings.Subscriptions = [AutomatedLab.Azure.AzureSubscription]::Create($Subscriptions)
    Write-Verbose "Added $($script:lab.AzureSettings.Subscriptions.Count) subscriptions"

    if ($SubscriptionName -and -not ($script:lab.AzureSettings.Subscriptions | Where-Object Name -eq $SubscriptionName))
    {
        throw "A subscription named '$SubscriptionName' cannot be found. Make sure you specify the right subscription name or let AutomatedLab choose on by not defining a subscription name"
    }

    #select default subscription subscription
    if (-not $SubscriptionName)
    {
        $SubscriptionName = $AzureRmProfile.Subscription.Name
    }

    Write-ScreenInfo -Message "Using Azure Subscription '$SubscriptionName'" -Type Info
    $selectedSubscription = $Subscriptions | Where-Object {$_.Name -eq $SubscriptionName}

    try
    {
        [void](Set-AzureRmContext -Subscription $SubscriptionName -ErrorAction Stop)
    }
    catch
    {
        throw "Error selecting subscription $SubscriptionName. $($_.Exception.Message). The local Azure profile might have expired. Please try Connect-AzureRmAccount and Save-AzureRmContext."
    }

    $script:lab.AzureSettings.DefaultSubscription = [AutomatedLab.Azure.AzureSubscription]::Create($selectedSubscription)
    Write-Verbose "Azure subscription '$SubscriptionName' selected as default"

    $locations = Get-AzureRmLocation
    $script:lab.AzureSettings.Locations = [AutomatedLab.Azure.AzureLocation]::Create($locations)
    Write-Verbose "Added $($script:lab.AzureSettings.Locations.Count) locations"

    if (-not $DefaultLocationName)
    {
        $DefaultLocationName = Get-LabAzureLocation
    }

    try
    {
        Set-LabAzureDefaultLocation -Name $DefaultLocationName -ErrorAction Stop
        Write-ScreenInfo -Message "Using Azure Location '$DefaultLocationName'" -Type Info
    }
    catch
    {
        throw 'Cannot proceed without a valid location specified'
    }

    Write-ScreenInfo -Message "Trying to locate or create default resource group"

    #Create new lab resource group as default
    if (-not $DefaultResourceGroupName)
    {
        $DefaultResourceGroupName = $script:lab.Name
    }

    #Create if no default given or default set and not existing as RG
    $rg = Get-AzureRmResourceGroup -Name $DefaultResourceGroupName -ErrorAction SilentlyContinue
    if (-not $rg)
    {
        $rgParams = @{
            Name     = $DefaultResourceGroupName
            Location = $DefaultLocationName
            Tag      = @{
                AutomatedLab = $script:lab.Name
                CreationTime = Get-Date
            }
        }

        $defaultResourceGroup = New-AzureRmResourceGroup @rgParams -ErrorAction Stop
        $script:lab.AzureSettings.DefaultResourceGroup = [AutomatedLab.Azure.AzureRmResourceGroup]::Create($defaultResourceGroup)
    }
    else
    {
        $script:lab.AzureSettings.DefaultResourceGroup = [AutomatedLab.Azure.AzureRmResourceGroup]::Create((Get-AzureRmResourceGroup -Name $DefaultResourceGroupName))
    }
    Write-Verbose "Selected $DefaultResourceGroupName as default resource group"

    $resourceGroups = Get-AzureRmResourceGroup
    $script:lab.AzureSettings.ResourceGroups = [AutomatedLab.Azure.AzureRmResourceGroup]::Create($resourceGroups)
    Write-Verbose "Added $($script:lab.AzureSettings.ResourceGroups.Count) resource groups"

    $storageAccounts = Get-AzureRmStorageAccount -ResourceGroupName $DefaultResourceGroupName -WarningAction SilentlyContinue
    foreach ($storageAccount in $storageAccounts)
    {
        $alStorageAccount = [AutomatedLab.Azure.AzureRmStorageAccount]::Create($storageAccount)
        $alStorageAccount.StorageAccountKey = ($storageAccount | Get-AzureRmStorageAccountKey)[0].Value
        $script:lab.AzureSettings.StorageAccounts.Add($alStorageAccount)
    }

    Write-Verbose "Added $($script:lab.AzureSettings.StorageAccounts.Count) storage accounts"

    if ($global:cacheAzureRoleSizes)
    {
        Write-ScreenInfo -Message "Querying available vm sizes for Azure location '$DefaultLocationName' (using cache)" -Type Info
        $roleSizes = $global:cacheAzureRoleSizes | Where-Object { $_.InstanceSize -in (Get-LabAzureDefaultLocation).VirtualMachineRoleSizes }
    }
    else
    {
        Write-ScreenInfo -Message "Querying available vm sizes for Azure location '$DefaultLocationName'" -Type Info
        $roleSizes = Get-LabAzureAvailableRoleSize -Location $DefaultLocationName
        $global:cacheAzureRoleSizes = $roleSizes
    }

    if ($roleSizes.Count -eq 0)
    {
        throw "No available role sizes in region '$DefaultLocationName'! Cannot continue."
    }
    $script:lab.AzureSettings.RoleSizes = [AutomatedLab.Azure.AzureRmVmSize]::Create($roleSizes)

    # Add LabSources storage
    New-LabAzureLabSourcesStorage

    # Add ISOs
    $type = Get-Type -GenericType AutomatedLab.DictionaryXmlStore -T String, DateTime

    try
    {
        Write-Verbose -Message 'Get last ISO update time'
        $timestamps = $type::ImportFromRegistry('Cache', 'Timestamps')
        $lastChecked = $timestamps.AzureIsosLastChecked
        Write-Verbose -Message "Last check was '$lastChecked'."
    }
    catch
    {
        Write-Verbose -Message 'Last check time could not be retrieved. Azure ISOs never updated'
        $lastChecked = Get-Date -Year 1601
        $timestamps = New-Object $type
    }

    if ($lastChecked -lt [datetime]::Now.AddDays(-7))
    {
        Write-Verbose -Message 'ISO cache outdated. Updating ISO files.'
        try
        {
            Write-ScreenInfo -Message 'Auto-adding ISO files from Azure labsources share' -TaskStart
            Add-LabIsoImageDefinition -Path "$labSources\ISOs" -ErrorAction Stop
        }
        catch
        {
            Write-ScreenInfo -Message 'No ISO files have been found in your Azure labsources share. Please make sure that they are present when you try mounting them.' -Type Warning
        }
        finally
        {
            $timestamps['AzureIsosLastChecked'] = Get-Date
            $timestamps.ExportToRegistry('Cache', 'Timestamps')
            Write-ScreenInfo -Message 'Done' -TaskEnd
        }
    }

    $script:lab.AzureSettings.VNetConfig = (Get-AzureRmVirtualNetwork) | ConvertTo-Json
    Write-Verbose 'Added virtual network configuration'

    # Read cache
    $type = Get-Type -GenericType AutomatedLab.ListXmlStore -T AutomatedLab.Azure.AzureOSImage

    try
    {
        $importMethodInfo = $type.GetMethod('ImportFromRegistry', [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static)
        $global:cacheVmImages = $importMethodInfo.Invoke($null, ('Cache', 'AzureOperatingSystems'))
        Write-Verbose "Read $($global:cacheVmImages.Count) OS images from the cache"

        if ($global:cacheVmImages)
        {
            Write-Verbose ("Azure OS Cache was older than {0:yyyy-MM-dd HH:mm:ss}. Cache date was {1:yyyy-MM-dd HH:mm:ss}" -f (Get-Date).AddDays(-7) , $global:cacheVmImages.TimeStamp)
        }

        if ($global:cacheVmImages -and $global:cacheVmImages.TimeStamp -gt (Get-Date).AddDays(-7))
        {
            Write-ScreenInfo 'Querying available operating system images (using cache)'
            $vmImages = $global:cacheVmImages
        }
        else
        {
            Write-ScreenInfo 'Could not read OS image info from the cache'
            throw 'Cache outdated or empty'
        }
    }
    catch
    {
        Write-ScreenInfo 'Querying available operating system images from Azure'
        $global:cacheVmImages = Get-LabAzureAvailableSku -Location $DefaultLocationName
        $vmImages = $global:cacheVmImages
    }

    $osImageListType = Get-Type -GenericType AutomatedLab.ListXmlStore -T AutomatedLab.Azure.AzureOSImage
    $script:lab.AzureSettings.VmImages = New-Object $osImageListType

    # Cache all images
    if ($vmImages)
    {
        $osImageList = New-Object $osImageListType


        foreach ($vmImage in $vmImages)
        {
            $osImageList.Add([AutomatedLab.Azure.AzureOSImage]::Create($vmImage))
            $script:lab.AzureSettings.VmImages.Add([AutomatedLab.Azure.AzureOSImage]::Create($vmImage))
        }

        $osImageList.Timestamp = Get-Date
        $osImageList.ExportToRegistry('Cache', 'AzureOperatingSystems')
    }

    Write-Verbose "Added $($script:lab.AzureSettings.VmImages.Count) virtual machine images"

    $vms = Get-AzureRmVM -WarningAction SilentlyContinue
    $script:lab.AzureSettings.VirtualMachines = [AutomatedLab.Azure.AzureVirtualMachine]::Create($vms)
    Write-Verbose "Added $($script:lab.AzureSettings.VirtualMachines.Count) virtual machines"

    #$script:lab.AzureSettings.DefaultStorageAccount cannot be set when creating the definitions but is during the import process
    if (-not $script:lab.AzureSettings.DefaultStorageAccount)
    {
        Write-ScreenInfo -Message 'No default storage account exist. Determining storage account now' -Type Info
        if (-not $DefaultStorageAccountName)
        {
            $DefaultStorageAccountName = ($script:lab.AzureSettings.StorageAccounts | Where-Object StorageAccountName -like 'automatedlab????????' | Select-Object -First 1).StorageAccountName
        }

        if (-not $DefaultStorageAccountName)
        {
            Write-ScreenInfo -Message 'No storage account for AutomatedLab found. Creating a storage account now'
            New-LabAzureDefaultStorageAccount -LocationName $DefaultLocationName -ResourceGroupName $DefaultResourceGroupName
        }
        else
        {
            try
            {
                Set-LabAzureDefaultStorageAccount -Name $DefaultStorageAccountName -ErrorAction Stop
                Write-ScreenInfo -Message "Using Azure Storage Account '$DefaultStorageAccountName'" -Type Info
            }
            catch
            {
                throw 'Cannot proceed with an invalid default storage account'
            }
        }
        Write-Verbose "Mapping storage account '$((Get-LabAzureDefaultStorageAccount).StorageAccountName)' to resource group $DefaultResourceGroupName'"
        [void](Set-AzureRmCurrentStorageAccount -Name $((Get-LabAzureDefaultStorageAccount).StorageAccountName) -ResourceGroupName $DefaultResourceGroupName)
    }

    Write-ScreenInfo -Message "Azure default resource group name will be '$($script:lab.Name)'"

    Write-ScreenInfo -Message "Azure data center location will be '$DefaultLocationName'" -Type Info

    Write-ScreenInfo -Message 'Finished adding Azure subscription data' -Type Info -TaskEnd

    if ($PassThru)
    {
        $script:lab.AzureSettings.Subscription
    }

    Write-LogFunctionExit
}

function Get-LabAzureSubscription
{
    # .ExternalHelp AutomatedLab.Help.xml
    param ()

    Write-LogFunctionEntry

    Update-LabAzureSettings

    $script:lab.AzureSettings.Subscriptions

    Write-LogFunctionExit
}

function Get-LabAzureDefaultSubscription
{
    # .ExternalHelp AutomatedLab.Help.xml
    param ()

    Write-LogFunctionEntry

    Update-LabAzureSettings

    $script:lab.AzureSettings.DefaultSubscription

    Write-LogFunctionExit
}

function Get-LabAzureLocation
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletBinding()]
    param (
        [string]$LocationName,

        [switch]$List
    )

    Write-LogFunctionEntry

    $azureLocations = Get-AzureRmLocation

    if ($LocationName)
    {
        if ($LocationName -notin ($azureLocations.DisplayName))
        {
            Write-Error "Invalid location. Please specify one of the following locations: ""'$($azureLocations.DisplayName -join ''', ''')"
            return
        }

        $azureLocations | Where-Object DisplayName -eq $LocationName
    }
    else
    {
        if ((Get-Lab -ErrorAction SilentlyContinue) -and (-not $list))
        {
            #if lab already exists, use the location used when this was deployed to create lab stickyness
            return (Get-Lab).AzureSettings.DefaultLocation.Name
        }

        $locationUrls = Get-LabConfigurationItem -Name AzureLocationsUrls
        
        foreach ($location in $azureLocations)
        {
            if ($locationUrls."$($location.DisplayName)")
            {
                $location | Add-Member -MemberType NoteProperty -Name 'Url' -Value ($locationUrls."$($location.DisplayName)" + '.blob.core.windows.net')
            }
            $location | Add-Member -MemberType NoteProperty -Name 'Latency' -Value 9999
        }

        $jobs = @()
        foreach ($location in ($azureLocations | Where-Object { $_.Url }))
        {
            $url = $location.Url
            $jobs += Start-Job -Name $location.DisplayName -ScriptBlock {
                $testUrl = $using:url

                try
                {
                    (Test-Port -ComputerName $testUrl -Port 443 -Count 4 -ErrorAction Stop| Measure-Object -Property ResponseTime -Average).Average
                }
                catch
                {
                    9999
                    #Write-Warning "$testUrl $($_.Exception.Message)"
                }
            }
        }

        Wait-LWLabJob -Job $jobs -NoDisplay
        foreach ($job in $jobs)
        {
            $result = Receive-Job -Keep -Job $job
            ($azureLocations | Where-Object {$_.DisplayName -eq $job.Name}).Latency = $result
        }
        $jobs | Remove-Job

        Write-Verbose -Message 'DisplayName            Latency'
        foreach ($location in $azureLocations)
        {
            Write-Verbose -Message "$($location.DisplayName.PadRight(20)): $($location.Latency)"
        }

        if ($List)
        {
            $azureLocations | Sort-Object -Property Latency | Format-Table DisplayName, Latency
        }
        else
        {
            $azureLocations | Sort-Object -Property Latency | Select-Object -First 1 | Select-Object -ExpandProperty DisplayName
        }
    }

    Write-LogFunctionExit
}

function Get-LabAzureDefaultLocation
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param ()

    Write-LogFunctionEntry

    Update-LabAzureSettings

    if (-not $Script:lab.AzureSettings.DefaultLocation)
    {
        Write-Error 'The default location is not defined. Use Set-LabAzureDefaultLocation to define it.'
        return
    }

    $Script:lab.AzureSettings.DefaultLocation

    Write-LogFunctionExit
}

function Set-LabAzureDefaultLocation
{
    # .ExternalHelp AutomatedLab.Help.xml
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-LogFunctionEntry

    Update-LabAzureSettings

    if ($Name -notin $script:lab.AzureSettings.Locations.DisplayName)
    {
        Microsoft.PowerShell.Utility\Write-Error "Invalid location. Please specify one of the following locations: $($script:lab.AzureSettings.Locations.DisplayName -join ', ')"
        return
    }

    $script:lab.AzureSettings.DefaultLocation = $script:lab.AzureSettings.Locations | Where-Object DisplayName -eq $Name

    Write-LogFunctionExit
}

function Set-LabAzureDefaultStorageAccount
{
    # .ExternalHelp AutomatedLab.Help.xml
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    Write-LogFunctionEntry

    Update-LabAzureSettings

    if (-not ($script:lab.AzureSettings.StorageAccounts | Where-Object StorageAccountName -eq $Name))
    {
        Microsoft.PowerShell.Utility\Write-Error "Invalid storage account. Please specify one of the following storage accounts: $($script:lab.AzureSettings.StorageAccounts.StorageAccountName -join ', ')"
        return
    }

    $script:lab.AzureSettings.DefaultStorageAccount = $script:lab.AzureSettings.StorageAccounts | Where-Object StorageAccountName -eq $Name

    Write-LogFunctionExit
}

function Get-LabAzureDefaultStorageAccount
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param ()

    Write-LogFunctionEntry

    Update-LabAzureSettings

    if (-not $Script:lab.AzureSettings.DefaultStorageAccount)
    {
        Write-Error 'The default storage account is not defined. Use Set-LabAzureDefaultStorageAccount to define it.'
        return
    }

    $Script:lab.AzureSettings.DefaultStorageAccount

    Write-LogFunctionExit
}

function New-LabAzureDefaultStorageAccount
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [string]$LocationName,
        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )

    Write-LogFunctionEntry

    Update-LabAzureSettings

    $storageAccountName = "automatedlab$((1..8 | ForEach-Object { [char[]](97..122) | Get-Random }) -join '')"

    $param = @{
        Name              = $storageAccountName
        ResourceGroupName = $ResourceGroupName
        Tag               = @{
            AutomatedLab = $script:lab.Name
            CreationTime = Get-Date
        }
        Sku               = 'Standard_LRS'
    }

    if ($LocationName)
    {
        $location = Get-LabAzureLocation -LocationName $LocationName -ErrorAction Stop
        $param.Add('Location', $location.DisplayName)
        Write-ScreenInfo -Message "Creating a new storage account named '$storageAccountName' for location '$($param.Location)'"
    }

    $result = New-AzureRmStorageAccount @param -ErrorAction Stop -WarningAction SilentlyContinue

    if ($result.ProvisioningState -ne 'Succeeded')
    {
        throw "Could not create storage account $storageAccountName : $($result.ProvisioningState)"
    }

    Write-ScreenInfo -Message  'Storage account now created'

    $StorageAccount = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName -Name $storageAccountName

    $ALStorageAccount = [AutomatedLab.Azure.AzureRmStorageAccount]::Create($StorageAccount)
    $ALStorageAccount.StorageAccountKey = ($StorageAccount | Get-AzureRmStorageAccountKey)[0].Value
    $script:lab.AzureSettings.StorageAccounts.Add($ALStorageAccount)

    Write-Verbose "Added $($script:lab.AzureSettings.StorageAccounts.Count) storage accounts"

    Set-LabAzureDefaultStorageAccount -Name $storageAccountName

    Write-LogFunctionExit
}

function Get-LabAzureDefaultResourceGroup
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param ()

    Write-LogFunctionEntry

    Update-LabAzureSettings

    $script:lab.AzureSettings.ResourceGroups | Where-Object ResourceGroupName -eq $script:lab.Name

    Write-LogFunctionExit
}

#TODO use keyvault -> New AzureProp defaultKeyVaultName
function Import-LabAzureCertificate
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param ()

    throw New-Object System.NotImplementedException
    Write-LogFunctionEntry

    Update-LabAzureSettings

    $resourceGroup = Get-AzureRmResourceGroup -name (Get-LabAzureDefaultResourceGroup)
    $keyVault = Get-AzureRmKeyVault -VaultName (Get-LabAzureDefaultKeyVault) -ResourceGroupName $resourceGroup
    $temp = [System.IO.Path]::GetTempFileName()

    $cert = ($keyVault | Get-AzureKeyVaultCertificate).Data

    if ($cert)
    {
        $cert | Out-File -FilePath $temp
        certutil -addstore -f Root $temp | Out-Null

        Remove-Item -Path $temp
        Write-LogFunctionExit
    }
    else
    {
        Write-LogFunctionExitWithError -Message "Could not receive certificate for resource group '$resourceGroup'"
    }
}

#TODO use keyvault -> New AzureProp defaultKeyVaultName
function New-LabAzureCertificate
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param ()
    throw New-Object System.NotImplementedException
    Write-LogFunctionEntry

    Update-LabAzureSettings

    $certSubject = "CN=$($Script:lab.Name).cloudapp.net"
    $service = Get-LabAzureDefaultResourceGroup
    $cert = dir Cert:\LocalMachine\My | Where-Object Subject -eq $certSubject -ErrorAction SilentlyContinue

    if (-not $cert)
    {
        $temp = [System.IO.Path]::GetTempFileName()

        #not required as SSL is not used yet
        #& 'C:\Program Files (x86)\Microsoft SDKs\Windows\v7.1A\Bin\makecert.exe' -r -pe -n $certSubject -b 01/01/2000 -e 01/01/2036 -eku 1.3.6.1.5.5.7.3.1, 1.3.6.1.5.5.7.3.2 -ss my -sr localMachine -sky exchange -sp "Microsoft RSA SChannel Cryptographic Provider" -sy 12 $temp

        certutil.exe -addstore -f Root $temp | Out-Null

        Remove-Item -Path $temp

        $cert = dir Cert:\LocalMachine\Root | Where-Object Subject -eq $certSubject
    }

    #not required as SSL is not used yet
    #$service | Add-AzureCertificate -CertToDeploy (Get-Item -Path "Cert:\LocalMachine\Root\$($cert.Thumbprint)")
}

#TODO use keyvault -> New AzureProp defaultKeyVaultName
function Get-LabAzureCertificate
{
    # .ExternalHelp AutomatedLab.Help.xml
    [OutputType([System.Security.Cryptography.X509Certificates.X509Certificate2])]
    [cmdletbinding()]
    param ()
    throw New-Object System.NotImplementedException
    Write-LogFunctionEntry

    Update-LabAzureSettings

    $certSubject = "CN=$($Script:lab.Name).cloudapp.net"

    $cert = dir Cert:\LocalMachine\My | Where-Object Subject -eq $certSubject -ErrorAction SilentlyContinue

    if (-not $cert)
    {
        #just returning nothing is more convenient
        #Write-LogFunctionExitWithError -Message "The required certificate does not exist"
    }
    else
    {
        $cert
    }

    Write-LogFunctionExit
}

function New-LabAzureRmResourceGroup
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param (
        [Parameter(Mandatory, Position = 0)]
        [string[]]$ResourceGroupNames,

        [Parameter(Mandatory, Position = 1)]
        [string]$LocationName,

        [switch]$PassThru
    )

    Write-LogFunctionEntry

    Update-LabAzureSettings

    Write-Verbose "Creating the resource groups '$($ResourceGroupNames -join ', ')' for location '$LocationName'"

    $resourceGroups = Get-AzureRmResourceGroup

    foreach ($name in $ResourceGroupNames)
    {
        if ($resourceGroups | Where-Object ResourceGroupName -eq $name)
        {
            if (-not $script:lab.AzureSettings.ResourceGroups.ResourceGroupName.Contains($name))
            {
                $script:lab.AzureSettings.ResourceGroups.Add([AutomatedLab.Azure.AzureRmResourceGroup]::Create((Get-AzureRmResourceGroup -ResourceGroupName $name)))
                Write-Verbose "The resource group '$name' does already exist"
            }
            continue
        }

        $result = New-AzureRmResourceGroup -Name $name -Location $LocationName -Tag @{
            AutomatedLab = $script:lab.Name
            CreationTime = Get-Date
        }

        $script:lab.AzureSettings.ResourceGroups.Add([AutomatedLab.Azure.AzureRmResourceGroup]::Create((Get-AzureRmResourceGroup -ResourceGroupName $name)))
        if ($PassThru)
        {
            $result
        }

        Write-Verbose "Resource group '$name' created"
    }

    Write-LogFunctionExit
}

function Remove-LabAzureResourceGroup
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding()]
    param (
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [string[]]$ResourceGroupName,

        [switch]$Force
    )

    begin
    {
        Write-LogFunctionEntry

        Update-LabAzureSettings

        $resourceGroups = Get-LabAzureResourceGroup -CurrentLab
    }

    process
    {
        foreach ($name in $ResourceGroupName)
        {
            Write-ScreenInfo -Message "Removing the Resource Group '$name'" -Type Warning
            if ($resourceGroups.ResourceGroupName -contains $name)
            {
                Remove-AzureRmResourceGroup -Name $name -Force:$Force -WarningAction SilentlyContinue | Out-Null
                Write-Verbose "Resource Group '$($name)' removed"

                $resourceGroup = $script:lab.AzureSettings.ResourceGroups | Where-Object ResourceGroupName -eq $name
                $script:lab.AzureSettings.ResourceGroups.Remove($resourceGroup) | Out-Null
            }
            else
            {
                Write-ScreenInfo -Message "RG '$name' could not be found" -Type Error
            }
        }
    }

    end
    {
        Write-LogFunctionExit
    }
}

function Get-LabAzureResourceGroup
{
    # .ExternalHelp AutomatedLab.Help.xml
    [cmdletbinding(DefaultParameterSetName = 'ByName')]
    param (
        [Parameter(Position = 0, ParameterSetName = 'ByName')]
        [string[]]$ResourceGroupName,

        [Parameter(Position = 0, ParameterSetName = 'ByLab')]
        [switch]$CurrentLab
    )

    Write-LogFunctionEntry

    Update-LabAzureSettings

    $resourceGroups = $script:lab.AzureSettings.ResourceGroups

    if ($ResourceGroupName)
    {
        Write-Verbose "Getting the resource groups '$($ResourceGroupName -join ', ')'"
        $resourceGroups | Where-Object ResourceGroupName -in $ResourceGroupName
    }
    elseif ($CurrentLab)
    {
        $resourceGroups | Where-Object { $_.Tags.AutomatedLab -eq $script:lab.Name }
    }
    else
    {
        Write-Verbose 'Getting all resource groups'
        $resourceGroups
    }

    Write-LogFunctionExit
}

#region New-LabAzureLabSourcesStorage
function New-LabAzureLabSourcesStorage
{
    # .ExternalHelp AutomatedLab.Help.xml
    [CmdletBinding()]
    param
    (
        [string]$LocationName,

        [switch]$NoDisplay
    )

    Write-LogFunctionEntry

    Test-LabAzureSubscription
    $azureLabSourcesResourceGroupName = 'AutomatedLabSources'

    if (-not $LocationName)
    {
        $LocationName = (Get-LabAzureDefaultLocation -ErrorAction SilentlyContinue).DisplayName
    }
    if (-not $LocationName)
    {
        Write-Error "LocationName was not provided and could not be retrieved from a present lab. Please specify a location name or import a lab"
        return
    }
    if ($LocationName -notin (Get-AzureRmLocation).DisplayName)
    {
        Write-Error "The location name '$LocationName' is not valid. Please invoke 'Get-AzureRmLocation' to get a list of possible locations"
    }

    $currentSubscription = (Get-AzureRmContext).Subscription
    Write-ScreenInfo "Looking for Azure LabSources inside subscription '$($currentSubscription.Name)'" -TaskStart

    $resourceGroup = Get-AzureRmResourceGroup -Name $azureLabSourcesResourceGroupName -ErrorAction SilentlyContinue
    if (-not $resourceGroup)
    {
        Write-ScreenInfo "Resoure Group '$azureLabSourcesResourceGroupName' could not be found, creating it"
        $resourceGroup = New-AzureRmResourceGroup -Name $azureLabSourcesResourceGroupName -Location $LocationName | Out-Null
    }

    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName $azureLabSourcesResourceGroupName -ErrorAction SilentlyContinue | Where-Object StorageAccountName -like automatedlabsources?????
    if (-not $storageAccount)
    {
        Write-ScreenInfo "No storage account for AutomatedLabSources could not be found, creating it"
        $storageAccountName = "automatedlabsources$((1..5 | ForEach-Object { [char[]](97..122) | Get-Random }) -join '')"
        New-AzureRmStorageAccount -ResourceGroupName $azureLabSourcesResourceGroupName -Name $storageAccountName -Location $LocationName -Kind Storage -SkuName Standard_LRS | Out-Null
        $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName automatedlabsources | Where-Object StorageAccountName -like automatedlabsources?????
    }

    $share = Get-AzureStorageShare -Context $StorageAccount.Context -Name labsources -ErrorAction SilentlyContinue
    if (-not $share)
    {
        Write-ScreenInfo "The share 'labsources' could not be found, creating it"
        New-AzureStorageShare -Name 'labsources' -Context $storageAccount.Context | Out-Null
    }

    Write-ScreenInfo "Azure LabSources verified / created" -TaskEnd

    Write-LogFunctionExit
}
#endregion New-LabAzureLabSourcesStorage

function Get-LabAzureLabSourcesStorage
{
    # .ExternalHelp AutomatedLab.Help.xml
    [CmdletBinding()]
    param
    ()

    Write-LogFunctionEntry

    Test-LabAzureSubscription
    $azureLabSourcesResourceGroupName = 'AutomatedLabSources'

    $currentSubscription = (Get-AzureRmContext).Subscription

    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName automatedlabsources -ErrorAction SilentlyContinue | Where-Object StorageAccountName -like automatedlabsources?????

    if (-not $storageAccount)
    {
        Write-Error "The AutomatedLabSources share on Azure does not exist"
        return
    }

    $storageAccount | Add-Member -MemberType NoteProperty -Name StorageAccountKey -Value ($storageAccount | Get-AzureRmStorageAccountKey)[0].Value -Force
    $storageAccount | Add-Member -MemberType NoteProperty -Name Path -Value "\\$($storageAccount.StorageAccountName).file.core.windows.net\labsources" -Force
    $storageAccount | Add-Member -MemberType NoteProperty -Name SubscriptionName -Value (Get-AzureRmContext).Subscription.Name -Force

    $storageAccount
}

function Test-LabAzureLabSourcesStorage
{
    $azureLabSources = Get-LabAzureLabSourcesStorage -ErrorAction SilentlyContinue

    if (-not $azureLabSources)
    {
        return $false
    }

    $azureStorageShare = Get-AzureStorageShare -Context $azureLabSources.Context -ErrorAction SilentlyContinue

    [bool]$azureStorageShare
}

function Test-LabPathIsOnLabAzureLabSourcesStorage
{
    # .ExternalHelp AutomatedLab.Help.xml
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]$Path
    )

    try
    {
        if (Test-LabAzureLabSourcesStorage)
        {
            $azureLabSources = Get-LabAzureLabSourcesStorage

            return $Path -like "$($azureLabSources.Path)*"
        }
    }
    catch
    {
        return $false
    }
}

function Remove-LabAzureLabSourcesStorage
{
    # .ExternalHelp AutomatedLab.Help.xml
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param
    ()

    Write-LogFunctionExit
    Test-LabAzureSubscription

    if (Test-LabAzureLabSourcesStorage)
    {
        $azureLabStorage = Get-LabAzureLabSourcesStorage

        if ($PSCmdlet.ShouldProcess($azureLabStorage.ResourceGroupName, 'Remove Resource Group'))
        {
            Remove-AzureRmResourceGroup -Name $azureLabStorage.ResourceGroupName -Force | Out-Null
            Write-ScreenInfo "Azure Resource Group '$($azureLabStorage.ResourceGroupName)' was removed" -Type Warning
        }
    }

    Write-LogFunctionExit
}

function Sync-LabAzureLabSources
{
    # .ExternalHelp AutomatedLab.Help.xml
    [CmdletBinding()]
    param
    (
        [switch]
        $SkipIsos,

        [switch]
        $DoNotSkipOsIsos,

        [int]
        $MaxFileSizeInMb,

        [string]
        $Filter
    )

    Write-LogFunctionExit
    Test-LabAzureSubscription

    if (-not (Test-LabAzureLabSourcesStorage))
    {
        Write-Error "There is no LabSources share available in the current subscription '$((Get-AzureRmContext).Subscription.Name)'. To create one, please call 'New-LabAzureLabSourcesStorage'."
        return
    }

    $currentSubscription = (Get-AzureRmContext).Subscription
    Write-ScreenInfo -Message "Syncing LabSources in subscription '$($currentSubscription.Name)'" -TaskStart

    # Retrieve storage context
    $storageAccount = Get-AzureRmStorageAccount -ResourceGroupName automatedlabsources | Where-Object StorageAccountName -like automatedlabsources?????

    $localLabsources = Get-LabSourcesLocationInternal -Local
    Unblock-LabSources -Path $localLabsources

    # Create the empty folders first
    foreach ($folder in (Get-ChildItem -Path $localLabsources -Recurse -Directory))
    {
        if ($SkipIsos -and $folder.Name -eq 'ISOs')
        {
            continue
        }

        $folderName = $folder.FullName.Replace($localLabsources, '')
        Write-ScreenInfo "Working on folder '$folderName' with " -NoNewLine

        $err = $null

        # Use an error variable and check the HttpStatusCode since there is no cmdlet to get or test a StorageDirectory
        New-AzureStorageDirectory -Share (Get-AzureStorageShare -Name labsources -Context $storageAccount.Context) -Path $folderName -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
        Write-Verbose "Created directory $($folderName) in labsources"
        if ($err)
        {
            $err = $null

            # Use an error variable and check the HttpStatusCode since there is no cmdlet to get or test a StorageDirectory
            New-AzureStorageDirectory -Share (Get-AzureStorageShare -Name labsources -Context $storageAccount.Context) -Path $folderName -ErrorVariable err -ErrorAction SilentlyContinue | Out-Null
            Write-Verbose "Created directory '$folderName' in labsources"
            if ($err)
            {
                if ($err[0].Exception.RequestInformation.HttpStatusCode -ne 409)
                {
                    throw "An error ocurred during file upload: $($err[0].Exception.Message)"
                }
            }
        }


        # Sync the lab sources
        $fileParams = @{
            Path   = $folder.FullName
            File   = $true
            Filter = if ($Filter) { $Filter}else {"*"}
        }
        $files = Get-ChildItem @fileParams

        Write-ScreenInfo "with $($files.Count) files" -NoNewLine
        foreach ($file in $files)
        {
            Write-ProgressIndicator
            if ($SkipIsos -and $file.Directory.Name -eq 'Isos')
            {
                Write-Verbose "SkipIsos is true, skipping $($file.Name)"
                continue
            }

            if ($MaxFileSizeInMb -and $file.Length / 1MB -ge $MaxFileSizeInMb)
            {
                Write-Verbose "MaxFileSize is $MaxFileSizeInMb MB, skipping '$($file.Name)'"
                continue
            }

            # Check if file is an OS ISO and skip
            if ($file.Extension -eq '.iso')
            {
                $isOs = [bool](Get-LabAvailableOperatingSystem -Path $file.FullName)

                if ($isOs -and -not $DoNotSkipOsIsos)
                {
                    Write-Verbose "Skipping OS ISO $($file.FullName)"
                    continue
                }
            }

            $fileName = $file.FullName.Replace("$(Get-LabSourcesLocationInternal -Local)\", '')

            $azureFile = Get-AzureStorageFile -Share (Get-AzureStorageShare -Name labsources -Context $storageAccount.Context) -Path $fileName -ErrorAction SilentlyContinue
            if ($azureFile)
            {
                $azureHash = $azureFile.Properties.ContentMD5
                $fileHash = (Get-FileHash -Path $file.FullName -Algorithm MD5).Hash
                Write-Verbose "$fileName already exists in Azure. Source hash is $fileHash and Azure hash is $azureHash"
            }

            if (-not $azureFile -or ($azureFile -and $fileHash -ne $azureHash))
            {
                $null = Set-AzureStorageFileContent -Share (Get-AzureStorageShare -Name labsources -Context $storageAccount.Context) -Source $file.FullName -Path $fileName -ErrorAction SilentlyContinue -Force
                Write-Verbose "Azure file $fileName successfully uploaded. Generating file hash..."
            }

            # Try to set the file hash
            $uploadedFile = Get-AzureStorageFile -Share (Get-AzureStorageShare -Name labsources -Context $storageAccount.Context) -Path $fileName -ErrorAction SilentlyContinue
            $uploadedFile.Properties.ContentMD5 = (Get-FileHash -Path $file.FullName -Algorithm MD5).Hash
            $apiResponse = $uploadedFile.SetPropertiesAsync()
            if (-not $apiResponse.Status -eq "RanToCompletion")
            {
                Write-ScreenInfo "Could not generate MD5 hash for file $fileName. Status was $($apiResponse.Status)" -Type Warning
                continue
            }

            Write-Verbose "Azure file $fileName successfully uploaded and hash generated"
        }

        Write-ScreenInfo 'done' #with folder
    }

    Write-ScreenInfo "LabSources Sync complete" -TaskEnd

    Write-LogFunctionExit
}

function Get-LabAzureLabSourcesContent
{
    [CmdletBinding()]
    param
    (
        [string]
        $RegexFilter,

        [switch]
        $File,

        [switch]
        $Directory
    )

    $azureShare = Get-AzureStorageShare -Name labsources -Context (Get-LabAzureLabSourcesStorage).Context

    $content = Get-LabAzureLabSourcesContentRecursive -StorageContext $azureShare

    if (-not [string]::IsNullOrWhiteSpace($RegexFilter))
    {
        $content = $content | Where-Object -FilterScript { $PSItem.Name -match $RegexFilter }
    }

    if ($File)
    {
        $content = $content | Where-Object -FilterScript {$PSItem.GetType().FullName -eq 'Microsoft.WindowsAzure.Storage.File.CloudFile'}
    }

    if ($Directory)
    {
        $content = $content | Where-Object -FilterScript {$PSItem.GetType().FullName -eq 'Microsoft.WindowsAzure.Storage.File.CloudFileDirectory'}
    }

    $content = $content |
    Add-Member -MemberType ScriptProperty -Name FullName -Value {$this.Uri.AbsoluteUri} -Force -PassThru |
    Add-Member -MemberType ScriptProperty -Name Length -Force -Value {$this.Properties.Length} -PassThru

    return $content
}

function Get-LabAzureLabSourcesContentRecursive
{
    [CmdletBinding()]
    param
    (
        $StorageContext
    )

    $content = @()

    $temporaryContent = $StorageContext | Get-AzureStorageFile
    foreach ($item in $temporaryContent)
    {
        if ($item.GetType().FullName -eq 'Microsoft.WindowsAzure.Storage.File.CloudFileDirectory')
        {
            $content += $item
            $content += Get-LabAzureLabSourcesContentRecursive -StorageContext $item
        }
        elseif ($item.GetType().FullName -eq 'Microsoft.WindowsAzure.Storage.File.CloudFile')
        {
            $content += $item
        }
        else
        {
            continue
        }
    }

    return $content
}

function Test-LabAzureSubscription
{
    try
    {
        $ctx = Get-AzureRmContext
    }
    catch
    {
        throw "No Azure Context found, Please run 'Connect-AzureRmAccount' first"
    }
}

function Get-LabAzureAvailableRoleSize
{
    param
    (
        [Parameter(Mandatory)]
        [string]$Location
    )

    if (-not (Get-AzureRmContext -ErrorAction SilentlyContinue))
    {
        [void] (Connect-AzureRmAccount)
    }

    $azLocation = Get-AzureRmLocation | Where-Object -Property DisplayName -eq $Location

    $availableRoleSizes = Get-AzureRmComputeResourceSku | Where-Object {
        $_.ResourceType -eq 'virtualMachines' -and $_.Locations -contains $azLocation.Location #-and $_.Restrictions.ReasonCode -notcontains 'NotAvailableForSubscription'
    } | Select-Object -ExpandProperty Name

    Get-AzureRmVmSize -Location $Location | Where-Object -Property Name -in $availableRoleSizes
}

function Get-LabAzureAvailableSku
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)]
        [string]
        $Location
    )

    # Server
    Get-AzureRmVMImagePublisher -Location $Location |
    Where-Object PublisherName -eq 'MicrosoftWindowsServer' |
    Get-AzureRmVMImageOffer |
    Get-AzureRmVMImageSku |
    Get-AzureRmVMImage |
    Group-Object -Property Skus, Offer |
    ForEach-Object { $_.Group | Sort-Object -Property PublishedDate -Descending | Select-Object -First 1 }

    # Desktop
    Get-AzureRmVMImagePublisher -Location $Location |
    Where-Object PublisherName -eq 'MicrosoftWindowsDesktop' |
    Get-AzureRmVMImageOffer |
    Get-AzureRmVMImageSku |
    Get-AzureRmVMImage |
    Group-Object -Property Skus, Offer |
    ForEach-Object { $_.Group | Sort-Object -Property PublishedDate -Descending | Select-Object -First 1 }

    # SQL
    Get-AzureRmVMImagePublisher -Location $Location |
    Where-Object PublisherName -eq 'MicrosoftSQLServer' |
    Get-AzureRmVMImageOffer |
    Get-AzureRmVMImageSku |
    Get-AzureRmVMImage |
    Where-Object Skus -eq 'Enterprise' |
    Group-Object -Property Skus, Offer |
    ForEach-Object { $_.Group | Sort-Object -Property PublishedDate -Descending | Select-Object -First 1 }

    # VisualStudio
    Get-AzureRmVMImagePublisher -Location $Location |
    Where-Object PublisherName -eq 'MicrosoftVisualStudio' |
    Get-AzureRmVMImageOffer |
    Get-AzureRmVMImageSku |
    Get-AzureRmVMImage |
    Where-Object Offer -eq 'VisualStudio' |
    Group-Object -Property Skus, Offer |
    ForEach-Object { $_.Group | Sort-Object -Property PublishedDate -Descending | Select-Object -First 1 }

    # Client OS
    Get-AzureRmVMImagePublisher -Location $Location |
    Where-Object PublisherName -eq 'MicrosoftVisualStudio' |
    Get-AzureRmVMImageOffer |
    Get-AzureRmVMImageSku |
    Get-AzureRmVMImage |
    Where-Object Offer -eq 'Windows' |
    Group-Object -Property Skus, Offer |
    ForEach-Object { $_.Group | Sort-Object -Property PublishedDate -Descending | Select-Object -First 1 }

    # Sharepoint 2013 and 2016
    Get-AzureRmVMImagePublisher -Location $Location |
    Where-Object PublisherName -eq 'MicrosoftSharePoint' |
    Get-AzureRmVMImageOffer |
    Get-AzureRmVMImageSku |
    Get-AzureRmVMImage |
    Where-Object Offer -eq 'MicrosoftSharePointServer' |
    Group-Object -Property Skus, Offer |
    ForEach-Object { $_.Group | Sort-Object -Property PublishedDate -Descending | Select-Object -First 1 }
}
