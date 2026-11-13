# Phase 1: Setup Public Ingestion Architecture
# Configurable variables
param(
    [string]$ResourceGroupName = "rg-data-ingestion",
    [string]$Location = "eastus",
    [string]$StorageAccountName = "stdataingest$((Get-Random -Minimum 1000 -Maximum 9999))",
    [string]$ContainerName = "raw-landing",
    [string]$QueueName = "file-ingestion-queue",
    [string]$SubscriptionName = "sub-blob-to-queue"
)

Write-Host "=== Phase 1: Setting up Event-Driven Storage Ingestion (Public Mode) ===" -ForegroundColor Cyan

# 1. Create Resource Group if not exists
Write-Host "Creating Resource Group '$ResourceGroupName'..."
az group create --name $ResourceGroupName --location $Location

# 2. Create Storage Account (Public Access Enabled initially)
Write-Host "Creating Storage Account '$StorageAccountName'..."
az storage account create `
    --name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --location $Location `
    --sku Standard_LRS `
    --kind StorageV2 `
    --allow-blob-public-access false `
    --public-network-access Enabled

$storageId = az storage account show --name $StorageAccountName --resource-group $ResourceGroupName --query id --output tsv

# 3. Create Blob Container
Write-Host "Creating Blob Container '$ContainerName'..."
az storage container create `
    --name $ContainerName `
    --account-name $StorageAccountName `
    --auth-mode login

# 4. Create Storage Queue
Write-Host "Creating Storage Queue '$QueueName'..."
az storage queue create `
    --name $QueueName `
    --account-name $StorageAccountName `
    --auth-mode login

# 5. Create Event Grid System Topic & Event Subscription routing to the Storage Queue
Write-Host "Creating Event Grid Subscription to Queue..."
az eventgrid event-subscription create `
    --name $SubscriptionName `
    --source-resource-id $storageId `
    --endpoint-type storagequeue `
    --endpoint "$storageId/services/queues/$QueueName" `
    --included-event-types Microsoft.Storage.BlobCreated `
    --subject-begins-with "/blobServices/default/containers/$ContainerName/blobs/"

Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "Storage Account: $StorageAccountName"
Write-Host "Container: $ContainerName"
Write-Host "Queue: $QueueName"
