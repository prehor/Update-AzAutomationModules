# Azure Automation Runbooks

This folder contains PowerShell scripts that are synced to Azure Automation as Runbooks:
* https://docs.microsoft.com/en-us/azure/automation/source-control-integration

## Usage

Fork this repository and synchronize it using (Azure Automation Source Control)[https://docs.microsoft.com/en-us/azure/automation/source-control-integration]:
* Source Control Name: Update Azure Automation Modules
* Source Control Type: GitHub
* Repository: Update-AzAutomationModules
* Branch: main
* Folder Path: /Runbooks
* Auto Sync: Off
* Publish Runbook: On

## Update-AzAutomationModules.ps1

Update PowerShell modules in an Azure Automation account.

Environment variables:
* AZURE_AUTOMATION_ACCOUNT_NAME: Azure Automation account name.
* AZURE_AUTOMATION_RESOURCE_GROUP: Azure Automation account resource group name.
