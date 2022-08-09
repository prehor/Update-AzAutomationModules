# Azure Automation Runbooks

This folder contains PowerShell scripts that are synced to Azure Automation as Runbooks:
* https://docs.microsoft.com/en-us/azure/automation/source-control-integration

## Update-AzAutomationModules.ps1

Update PowerShell modules in an Azure Automation account.

Prerequisites:
* Aan Azure Automation account with an Azure Managed Identity account credential.

Optional Azure Automation account variables:
* `AZURE_AUTOMATION_ACCOUNT_NAME` - Name of Azure Automation account.
* `AZURE_AUTOMATION_RESOURCE_GROUP` - Name of Azure Automation account Resource Group.

Required Azure permissions:
* `Contributor` for *updating Azure Automation System Managed Identity* to *updated Azure Account*.
