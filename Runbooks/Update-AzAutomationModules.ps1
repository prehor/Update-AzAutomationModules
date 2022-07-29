# code: insertSpaces=false tabSize=4

<#
Copyright (c) Microsoft Corporation. All rights reserved.
Cypyright (c) Petr Řehoř https://github.com/prehor. All rights reserved.
Licensed under the MIT License.
#>

<#
.SYNOPSIS
Update PowerShell modules in an Azure Automation account.

.DESCRIPTION
This Azure Automation runbook updates PowerShell modules imported into an
Azure Automation account with the module versions published in the PowerShell Gallery.

Prerequisite: an Azure Automation account with an Azure Managed Identity account credential.

.PARAMETER AutomationAccountName
The Azure Automation account name. Uses the default value from the environment variable AZURE_AUTOMATION_ACCOUNT_NAME.

.PARAMETER ResourceGroupName
The Azure Resource Group name. Uses the default value from the environment variable AZURE_AUTOMATION_RESOURCE_GROUP.

.PARAMETER ModuleName
(Optional) The name of modules that will be updated. Supports wildcards.

.PARAMETER SkipModule
(Optional) The name of modules that will be skipped. Supports wildcards.

.PARAMETER ModuleVersionOverrides
(Optional) Module versions to use instead of the latest on the PowerShell Gallery.
If $null, the currently published latest versions will be used.
If not $null, must contain a JSON-serialized dictionary, for example:
	'{ "AzureRM.Compute": "5.8.0", "AzureRM.Network": "6.10.0" }'
or
	@{ 'AzureRM.Compute'='5.8.0'; 'AzureRM.Network'='6.10.0' } | ConvertTo-Json

.PARAMETER PsGalleryApiUrl
(Optional) PowerShell Gallery API URL.

.PARAMETER SimultaneousModuleImportJobCount
(Optional) The maximum number of module import jobs allowed to run concurrently.

.LINK
https://github.com/prehor/Update-AzAutomationModules
https://docs.microsoft.com/en-us/azure/automation/automation-update-azure-modules
https://github.com/Microsoft/AzureAutomation-Account-Modules-Update
#>

###############################################################################
### PARAMETERS ################################################################
###############################################################################

#region Parameters
[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseApprovedVerbs", "")]
# [CmdletBinding()]
param (
	[Parameter()]
	[String]$AutomationAccountName, # = $Env:AZURE_AUTOMATION_ACCOUNT_NAME,

	[Parameter()]
	[String]$ResourceGroupName, # = $Env:AZURE_AUTOMATION_RESOURCE_GROUP,

	[Parameter()]
	[String[]]$ModuleName = @('Az.*', 'Az'),

	[Parameter()]
	[String[]]$SkipModule,

	[Parameter()]
	[String]$ModuleVersionOverrides,

	[Parameter()]
	[String]$PsGalleryApiUrl = 'https://www.powershellgallery.com/api/v2',

	[Parameter()]
	[Int]$SimultaneousModuleImportJobCount = 10
)

#endregion

# Set strict mode
Set-StrictMode -Version Latest

###############################################################################
### CONSTANTS #################################################################
###############################################################################

#region Constants

# Stop on errors
$ErrorActionPreference = 'Stop'

# Azure Automation profile and account modules
$AzAccountsModuleName = "Az.Accounts"
$AzAutomationModuleName = "Az.Automation"

# PowerShell 5/7 comaptibility params for Invoke-WebRequest
$InvokeWebRequestCompatibilityParams = @{}
if ($PSVersionTable.PSVersion.Major -gt 5) {
	$InvokeWebRequestCompatibilityParams.SkipHttpErrorCheck = $true
}

#endregion

###############################################################################
### FUNCTIONS #################################################################
###############################################################################

#region Functions

### Write-Log #################################################################

# Write formatted log message
function Write-Log() {
	param(
		[Parameter(Position=0)]
		[String]$Message,

		[Parameter()]
		[String[]]$Property,

		[Parameter(ValueFromPipeline)]
		[Object[]]$Arguments
	)

	begin {
		$Properties = $Property
	}

	process {
		# Always output verbose messages
		$Private:SavedVerbosePreference = $VerbosePreference
		$VerbosePreference = 'Continue'

		# Format timestamp
		$Timestamp = '{0}Z' -f (Get-Date -Format 's')
		$MessageWithTimestamp = '{0} {1}' -f $Timestamp, $Message

		# Format arguments
		if ($null -eq $Properties) {
			# $Arguments contains array of values
			$Values = @()
			foreach ($Argument in $Arguments) {
				$Values += $_ | Out-String |
				# Remove ANSI colors
				ForEach-Object { $_ -replace '\e\[\d*;?\d+m','' }
			}
			Write-Verbose ($MessageWithTimestamp -f $Values)
		} else {
			# $Arguments contains array of objects with properties
			foreach ($Argument in $Arguments) {
				$Values = $()
				# Convert hashtable to object
				if ($Argument -is 'Hashtable') {
					$Argument = [PSCustomObject]$Argument
				}
				$ArgumentProperties = $Argument.PSObject.Properties.Name
				foreach ($Property in $Properties) {
					$Values += if ($ArgumentProperties -contains $Property) {
						if ($null -ne ($Value = $Argument.$_)) {
							$Value | Out-String |
							# Remove ANSI colors
							ForEach-Object { $_ -replace '\e\[\d*;?\d+m','' }
						} else {
							'ENULL'
						}
					} else {
						'ENONENT'
					}
				}
				Write-Verbose ($MessageWithTimestamp -f $Values)
			}
		}

		# Restore $VerbosePreference
		$VerbosePreference = $Private:SavedVerbosePreference
	}
}

### Login-AzureAutomation #####################################################

# Login in to Azure Active Directory
function Login-AzureAutomation() {
	Write-Log "### Sign in to Azure Active Directory"

	switch ($Env:POWERSHELL_DISTRIBUTION_CHANNEL) {
		'AzureAutomation' {
			Write-Log "Sign in with system managed identity"

			# Ensure that you do not inherit an AzContext
			Disable-AzContextAutosave -Scope Process | Out-Null

			# Connect using a Managed Service Identity
			$AzureContext = (Connect-AzAccount -Identity).Context

			# Set and store context
			Set-AzContext -Tenant $AzureContext.Tenant -SubscriptionId $AzureContext.Subscription -DefaultProfile $AzureContext | Out-Null
		}
		default {
			Write-Log "Using current user credentials"
		}
	}

	# Log Azure Context
	Get-AzContext | Format-List | Out-String -Stream -Width 1000 | Where-Object { $_ -notmatch '^\s*$' } | Write-Log '{0}'
}

### ConvertJsonDictTo-HashTable ###############################################

# Deserialize the JSON string to a hashtable
function ConvertJsonDictTo-HashTable([String]$JsonString) {
	try{
		$JsonObj = ConvertFrom-Json $JsonString -ErrorAction Stop
	} catch [System.ArgumentException] {
		throw "Unable to deserialize the JSON string for parameter ModuleVersionOverrides: ", $_
	}

	$Result = @{}
	foreach ($Property in $JsonObj.PSObject.Properties) {
		$Result[$Property.Name] = $Property.Value
	}

	$Result
}

### Get-ModuleDependencyAndLatestVersion ######################################

# Checks the PowerShell Gallery for the latest available version for the module
function Get-ModuleDependencyAndLatestVersion([String]$Name) {

	$ModuleUrlFormat = "$PsGalleryApiUrl/Search()?`$filter={1}&searchTerm=%27{0}%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"

	$ForcedModuleVersion = $ModuleVersionOverridesHashTable[$Name]

	$CurrentModuleUrl =
		if ($ForcedModuleVersion) {
			$ModuleUrlFormat -f $Name, "Version%20eq%20'$ForcedModuleVersion'"
		} else {
			$ModuleUrlFormat -f $Name, 'IsLatestVersion'
		}

	$SearchResult = Invoke-RestMethod -Method Get -Uri $CurrentModuleUrl -UseBasicParsing

	if (!$SearchResult) {
		Write-Log "Could not find module '$($Name)' on PowerShell Gallery. This may be a module you imported from a different location. Ignoring this module."
	} else {
		if ($SearchResult -is 'Object[]') {
			$SearchResult = $SearchResult | Where-Object { $_.title.InnerText -eq $Name }
		}
		if (!$SearchResult) {
			Write-Log "Could not find module '$($Name)' on PowerShell Gallery. This may be a module you imported from a different location. Ignoring this module."
		} else {
			$PackageDetails = Invoke-RestMethod -Method Get -UseBasicParsing -Uri $SearchResult.id

			$ModuleVersion = $PackageDetails.entry.properties.version
			$Dependencies = $PackageDetails.entry.properties.dependencies

			@($ModuleVersion, $Dependencies)
		}
	}
}

### Get-ModuleContentUrl ######################################################

# Get module content URL
function Get-ModuleContentUrl([String]$Name) {
	$ModuleContentUrlFormat = "$PsGalleryApiUrl/package/{0}"
	$VersionedModuleContentUrlFormat = "$ModuleContentUrlFormat/{1}"

	$ForcedModuleVersion = $ModuleVersionOverridesHashTable[$Name]
	if ($ForcedModuleVersion) {
		$VersionedModuleContentUrlFormat -f $Name, $ForcedModuleVersion
	} else {
		$ModuleContentUrlFormat -f $Name
	}
}

### Update-AutomationModule ###################################################

# Imports the module with given version into Azure Automation
function Update-AutomationModule([String]$Name) {

	# Get module latest version
	$LatestModuleVersionOnGallery = (Get-ModuleDependencyAndLatestVersion $Name)[0]

	# Find the actual blob storage location of the module
	$ModuleContentUrl = Get-ModuleContentUrl $Name
	do {
		$ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing @Script:InvokeWebRequestCompatibilityParams -ErrorAction Ignore).Headers.Location | Select-Object -First 1
	} while (!$ModuleContentUrl.Contains(".nupkg"))

	# Get current installed module
	$CurrentModule = Get-AzAutomationModule -Name $Name -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName

	# Upgrade the module to the latest version
	if ($CurrentModule.Version -eq $LatestModuleVersionOnGallery) {
		Write-Log "Skipping '$($Name)' because is already present with version '$($LatestModuleVersionOnGallery)'"
		return $false
	} else {
		Write-Log "Updating '$($Name)' module '$($CurrentModule.Version)' => '$($LatestModuleVersionOnGallery)'"
		New-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $Name -ContentLink $ModuleContentUrl | Out-Null
		return $true
	}
}

### Get-ModuleNameAndVersionFromPowershellGalleryDependencyFormat #############

# Parses the dependency got from PowerShell Gallery and returns name and version
function Get-ModuleNameAndVersionFromPowershellGalleryDependencyFormat([String]$Dependency) {
	if ($null -eq $Dependency) {
		throw "Improper dependency format"
	}

	$Tokens = $Dependency -split ':'
	if ($Tokens.Count -ne 3) {
		throw "Improper dependency format"
	}

	$Name = $Tokens[0]
	$Version = $Tokens[1].Trim("[","]")

	@($Name, $Version)
}

### AreAllModulesAdded ########################################################

# Validates if the given list of modules has already been added to the module update map
function AreAllModulesAdded([String[]] $ModuleListToAdd) {
	$Result = $true

	foreach ($ModuleToAdd in $ModuleListToAdd) {
		$ModuleAccounted = $false

		# $ModuleToAdd is specified in the following format:
		#	   ModuleName:ModuleVersionSpecification:
		# where ModuleVersionSpecification follows the specifiation
		# at https://docs.microsoft.com/en-us/nuget/reference/package-versioning#version-ranges-and-wildcards
		# For example:
		#	   AzureRm.profile:[4.0.0]:
		# or
		#	   AzureRm.profile:3.0.0:
		# In any case, the dependency version specification is always separated from the module name with
		# the ':' character. The explicit intent of this runbook is to always install the latest module versions,
		# so we want to completely ignore version specifications here.
		$ModuleNameToAdd = $ModuleToAdd -replace '\:.*', ''

		foreach($AlreadyIncludedModules in $ModuleUpdateMapOrder) {
			if ($AlreadyIncludedModules -contains $ModuleNameToAdd) {
				$ModuleAccounted = $true
				break
			}
		}

		if (!$ModuleAccounted) {
			$Result = $false
			break
		}
	}

	$Result
}

### Create-ModuleUpdateMapOrder ###############################################

# Creates a module update map. This is a 2D array of strings so that the first
# element in the array consist of modules with no dependencies.
# The second element only depends on the modules in the first element, the
# third element only dependes on modules in the first and second and so on.
function Create-ModuleUpdateMapOrder() {
	$ModuleUpdateMapOrder = $null
	$ProfileOrAccountsModuleName = $AzAccountsModuleName

	Write-Log "### Obtain list of installed Azure Automation modules"
	$CurrentAutomationModuleList = @(
		Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName |
		Where-Object {
			# Skip AzureRM modules
			!($_.Name -eq 'AzureRM' -or $_.Name -like 'AzureRM.*' -or $_.Name -eq 'Azure' -or $_.Name -like 'Azure.*')
		} |
		Where-Object {
			$AutomationModule = $_
			# Select required modules
			$SkipModule | ForEach-Object {
				if ($AutomationModule.Name -like $_) {
					return $false
				}
			}
			$ModuleName | ForEach-Object {
				if ($AutomationModule.Name -like $_) {
					return $true
				}
			}
			$false
		}
	)
	Write-Log "Found $($CurrentAutomationModuleList.Count) modules"

	$ModuleEntry = $ProfileOrAccountsModuleName
	$ModuleEntryArray = ,$ModuleEntry
	$ModuleUpdateMapOrder += ,$ModuleEntryArray

	do {
		$NextAutomationModuleList = @()
		$CurrentChainVersion = $null
		# Add it to the list if the modules are not available in the same list
		foreach ($Module in $CurrentAutomationModuleList) {
			Write-Log "### Check module '$($Module.Name)' dependencies"
			$VersionAndDependencies = Get-ModuleDependencyAndLatestVersion $Module.Name
			if ($null -eq $VersionAndDependencies) {
				continue
			}

			$Dependencies = $VersionAndDependencies[1].Split("|")

			# If the previous list contains all the dependencies then add it to current list
			if ((-not $Dependencies) -or (AreAllModulesAdded $Dependencies)) {
				Write-Log "Adding module '$($Module.Name)' to dependency chain"
				$CurrentChainVersion += ,$Module.Name
			} else {
				# else add it back to the main loop variable list if not already added
				if (!(AreAllModulesAdded $Module.Name)) {
					Write-Log "Module '$($Module.Name)' does not have all dependencies added as yet. Moving module for later import"
					$NextAutomationModuleList += ,$Module
				}
			}
		}

		$ModuleUpdateMapOrder += ,$CurrentChainVersion

		# Stop if dependecy cannot be satisfied
		if ($CurrentAutomationModuleList.Count -eq $NextAutomationModuleList.Count) {
			$UnsatisfiedDependencies = @()
			foreach ($Module in $NextAutomationModuleList) {
				$UnsatisfiedDependencies += "'$($Module.Name)' => $(Get-ModuleDependencyAndLatestVersion $Module.Name)"
			}
			throw "Cannot satisfy dependencies for modules: $($UnsatisfiedDependencies -join " ")"
		}

		$CurrentAutomationModuleList = $NextAutomationModuleList

	} while ($CurrentAutomationModuleList.Count -gt 0)

	$ModuleUpdateMapOrder
}

### WaitFor-AllModulesImported ################################################

# Wait and confirm that all the modules in the list have been imported successfully in Azure Automation
function WaitFor-AllModulesImported([Collections.Generic.List[String]]$ModuleList) {

	foreach ($Module in $ModuleList) {
		Write-Log "### Check module '$($Module)' import status"
		while ($true) {
			$AutomationModule = Get-AzAutomationModule -Name $Module -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName

			$IsTerminalProvisioningState =
				($AutomationModule.ProvisioningState -eq "Succeeded") -or
				($AutomationModule.ProvisioningState -eq "Failed") -or
				($AutomationModule.ProvisioningState -eq "Created")

			if ($IsTerminalProvisioningState) {
				break
			}

			Write-Log "Module '$($Module)' is getting imported, waiting for 30 seconds"
			Start-Sleep -Seconds 30
		}

		if ($AutomationModule.ProvisioningState -ne "Succeeded") {
			throw "Failed to import module '$($Module)'. See details in the Azure Portal."
		} else {
			Write-Log "Module '$($Module)' successfully imported"
		}
	}
}

### Update-ModulesInAutomationAccordingToDependency ###########################

# Uses the module update map created to import modules.
# It will only import modules from an element in the array if all the modules
# from the previous element have been added.
function Update-ModulesInAutomationAccordingToDependency([String[][]]$ModuleUpdateMapOrder) {

	foreach($ModuleList in $ModuleUpdateMapOrder) {
		$UpdatedModuleList = @()
		foreach ($Module in $ModuleList) {
			Write-Log  "### Update module '$($Module)'"

			if (Update-AutomationModule -Name $Module) {
				$UpdatedModuleList += ,$Module
			}
			# Wait for modules batch import to finish
			if ($UpdatedModuleList.Count -eq $SimultaneousModuleImportJobCount) {
				# It takes some time for the modules to start getting imported.
				# Sleep for sometime before making a query to see the status
				Write-Log "Waiting 30 seconds to start importing modules"
				Start-Sleep -Seconds 30
				WaitFor-AllModulesImported -ModuleList $UpdatedModuleList
				$UpdatedModuleList = @()
			}
		}

		# Wait for the modules import to finish
		if ($UpdatedModuleList.Count -gt 0) {
			# It takes some time for the modules to start getting imported.
			# Sleep for sometime before making a query to see the status
			Write-Log "Waiting 30 seconds to start importing modules"
			Start-Sleep -Seconds 30
			WaitFor-AllModulesImported -ModuleList $UpdatedModuleList
		}
	}
}

### Update-ProfileAndAutomationVersionToLatest ################################

# Ensure the latest versions of the Azure Automation module is in the local sandbox
function Update-ProfileAndAutomationVersionToLatest([String]$AutomationModuleName) {
	Write-Log "### Update '$($AutomationModuleName)' module in the local sandbox"
	# Get the latest Azure Automation module version
	$VersionAndDependencies = Get-ModuleDependencyAndLatestVersion $AutomationModuleName
	# Automation module only has dependency on profile module
	$ModuleDependencies = Get-ModuleNameAndVersionFromPowershellGalleryDependencyFormat $VersionAndDependencies[1]
	$ProfileModuleName = $ModuleDependencies[0]

	# Create web client object for downloading data
	$WebClient = New-Object System.Net.WebClient

	# Download profile module to temp location
	Write-Log "Downloading profile module '$($ProfileModuleName)"
	$ModuleContentUrl = Get-ModuleContentUrl $ProfileModuleName
	$ProfileURL = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing @Script:InvokeWebRequestCompatibilityParams -ErrorAction Ignore).Headers.Location
	$TempPath = if ($Env:TMPDIR) {
		$Env:TMPDIR	# macOS
	} else {
		$Env:TEMP	# Windows
	}
	$ProfilePath = Join-Path $TempPath ($ProfileModuleName + ".zip")
	$WebClient.DownloadFile($ProfileURL, $ProfilePath)

	# Download automation module to temp location
	Write-Log "Downloading automation module '$($AutomationModuleName)"
	$ModuleContentUrl = Get-ModuleContentUrl $AutomationModuleName
	$AutomationURL = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing @Script:InvokeWebRequestCompatibilityParams -ErrorAction Ignore).Headers.Location
	$AutomationPath = Join-Path $TempPath ($AutomationModuleName + ".zip")
	$WebClient.DownloadFile($AutomationURL, $AutomationPath)

	# Create folder for unzipping the module files
	$PathFolderName = New-Guid
	$PathFolder = Join-Path $TempPath $PathFolderName

	# Unzip files
	$ProfileUnzipPath = Join-Path $PathFolder $ProfileModuleName
	Expand-Archive -Path $ProfilePath -DestinationPath $ProfileUnzipPath -Force
	$AutomationUnzipPath = Join-Path $PathFolder $AutomationModuleName
	Expand-Archive -Path $AutomationPath -DestinationPath $AutomationUnzipPath -Force

	# Import modules
	Write-Log "Importing profile module '$($ProfileModuleName)"
	Import-Module (Join-Path $ProfileUnzipPath ($ProfileModuleName + ".psd1")) -Force
	Write-Log "Importing automation module '$($AutomationModuleName)"
	Import-Module (Join-Path $AutomationUnzipPath ($AutomationModuleName + ".psd1")) -Force
}

#endregion

###############################################################################
### MAIN ######################################################################
###############################################################################

#region Main

### Setup PowerShell Preferences ##############################################

# Stop on errors
$Private:SavedVerbosePreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

# Suppress verbose messages
$Private:SavedVerbosePreference = $VerbosePreference
$VerbosePreference = 'SilentlyContinue'

### Open log ##################################################################
$StartTimestamp = Get-Date
Write-Log "### Runbook started at $(Get-Date -Format 's')Z"

### Parameters ################################################################

# $AutomationAccountName
if (-not $AutomationAccountName) {
	switch ($Env:POWERSHELL_DISTRIBUTION_CHANNEL) {
		'AzureAutomation' {
			$AutomationAccountName = Get-AutomationVariable -Name 'AZURE_AUTOMATION_ACCOUNT_NAME'
		}
		default: {
			$AutomationAccountName = $Env:AZURE_AUTOMATION_ACCOUNT_NAME
		}
	}
}
if (-not $AutomationAccountName) {
	throw "$($MyInvocation.MyCommand.Name): Cannot bind argument to parameter 'AutomationAccountName' because it is an empty string."
}

# $ResourceGroupName
if (-not $ResourceGroupName) {
	switch ($Env:POWERSHELL_DISTRIBUTION_CHANNEL) {
		'AzureAutomation' {
			$ResourceGroupName = Get-AutomationVariable -Name 'AZURE_AUTOMATION_RESOURCE_GROUP'
		}
		default: {
			$ResourceGroupName = $Env:AZURE_AUTOMATION_RESOURCE_GROUP
		}
	}
}
if (-not $ResourceGroupName) {
	throw "$($MyInvocation.MyCommand.Name): Cannot bind argument to parameter 'ResourceGroupName' because it is an empty string."
}

### Module Versions Override Hashtable ########################################

# Convert JSON string to hashtable
if ($ModuleVersionOverrides) {
    $ModuleVersionOverridesHashTable = ConvertJsonDictTo-HashTable $ModuleVersionOverrides
} else {
    $ModuleVersionOverridesHashTable = @{}
}

### Update local Azure Automation module ######################################
Update-ProfileAndAutomationVersionToLatest -AutomationModuleName $AzAutomationModuleName

### Sign in to Azure ##########################################################
Login-AzureAutomation

### Update Azure Automation modules ###########################################
Write-Log "### Update Azure Automation '$($ResourceGroupName)/$($AutomationAccountName)' modules"
$ModuleUpdateMapOrder = Create-ModuleUpdateMapOrder
Update-ModulesInAutomationAccordingToDependency $ModuleUpdateMapOrder

### Close log #################################################################
$StopTimestamp = Get-Date
Write-Log "### Runbook finished in $($StopTimestamp - $StartTimestamp)"

### Restore PowerShell Preferences ############################################

# Restore $ErrorActionPreference
$ErrorActionPreference = $Private:SavedVerbosePreference

# Restore $VerbosePreference
$VerbosePreference = $Private:SavedVerbosePreference

#endregion
