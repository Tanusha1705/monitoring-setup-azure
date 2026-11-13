# Phase 2: Migrate Storage, Function, and PostgreSQL to Private Architecture
param(
    [string]$ResourceGroupName = "rg-data-ingestion",
    [string]$Location = "eastus",
    [string]$StorageAccountName = "stdataingest1234",
    [string]$PostgresServerName = "pg-analytics-1234",
    [string]$VNetName = "vnet-ingestion",
    [string]$FunctionSubnetName = "snet-function",
    [string]$EndpointSubnetName = "snet-private-endpoints"
)

Write-Host "=== Phase 2: Transitioning Storage Account & PostgreSQL to Private Endpoints & VNet ===" -ForegroundColor Cyan

# 1. Create Virtual Network
Write-Host "Creating Virtual Network '$VNetName'..."
az network vnet create `
    --resource-group $ResourceGroupName `
    --name $VNetName `
    --address-prefix 10.0.0.0/16 `
    --subnet-name $EndpointSubnetName `
    --subnet-prefix 10.0.1.0/24

# 2. Create Subnet dedicated for Function App VNet Integration
Write-Host "Creating Function Subnet '$FunctionSubnetName'..."
az network vnet subnet create `
    --resource-group $ResourceGroupName `
    --vnet-name $VNetName `
    --name $FunctionSubnetName `
    --address-prefixes 10.0.2.0/24 `
    --delegations Microsoft.App/environments Microsoft.Web/serverFarms

# 3. Disable private endpoint network policies on endpoint subnet
az network vnet subnet update `
    --resource-group $ResourceGroupName `
    --vnet-name $VNetName `
    --name $EndpointSubnetName `
    --disable-private-endpoint-network-policies true

$storageId = az storage account show --name $StorageAccountName --resource-group $ResourceGroupName --query id --output tsv

# 4. Create Private Endpoint for Blob Service
Write-Host "Creating Private Endpoint for Blob storage..."
az network private-endpoint create `
    --name "pe-$StorageAccountName-blob" `
    --resource-group $ResourceGroupName `
    --vnet-name $VNetName `
    --subnet $EndpointSubnetName `
    --private-connection-resource-id $storageId `
    --group-id blob `
    --connection-name "conn-blob"

# 5. Create Private Endpoint for Queue Service
Write-Host "Creating Private Endpoint for Queue storage..."
az network private-endpoint create `
    --name "pe-$StorageAccountName-queue" `
    --resource-group $ResourceGroupName `
    --vnet-name $VNetName `
    --subnet $EndpointSubnetName `
    --private-connection-resource-id $storageId `
    --group-id queue `
    --connection-name "conn-queue"

# 6. Create Private Endpoint for PostgreSQL Flexible Server (if supported in region)
$postgresId = az postgres flexible-server show --name $PostgresServerName --resource-group $ResourceGroupName --query id --output tsv
Write-Host "Creating Private Endpoint for PostgreSQL Flexible Server..."
az network private-endpoint create `
    --name "pe-$PostgresServerName" `
    --resource-group $ResourceGroupName `
    --vnet-name $VNetName `
    --subnet $EndpointSubnetName `
    --private-connection-resource-id $postgresId `
    --group-id postgresqlServer `
    --connection-name "conn-postgres"

# 7. Configure Private DNS Zones for Blob, Queue, and PostgreSQL
Write-Host "Configuring Private DNS Zones..."
az network private-dns zone create --resource-group $ResourceGroupName --name "privatelink.blob.core.windows.net"
az network private-dns zone create --resource-group $ResourceGroupName --name "privatelink.queue.core.windows.net"
az network private-dns zone create --resource-group $ResourceGroupName --name "privatelink.postgres.database.azure.com"

az network private-dns link vnet create `
    --resource-group $ResourceGroupName `
    --zone-name "privatelink.blob.core.windows.net" `
    --name "link-blob-$VNetName" `
    --virtual-network $VNetName `
    --registration-enabled false

az network private-dns link vnet create `
    --resource-group $ResourceGroupName `
    --zone-name "privatelink.queue.core.windows.net" `
    --name "link-queue-$VNetName" `
    --virtual-network $VNetName `
    --registration-enabled false

az network private-dns link vnet create `
    --resource-group $ResourceGroupName `
    --zone-name "privatelink.postgres.database.azure.com" `
    --name "link-postgres-$VNetName" `
    --virtual-network $VNetName `
    --registration-enabled false

# 8. Disable Public Network Access on Storage and PostgreSQL
Write-Host "Locking down Storage Account: Disabling Public Network Access..." -ForegroundColor Yellow
az storage account update `
    --name $StorageAccountName `
    --resource-group $ResourceGroupName `
    --public-network-access Disabled

Write-Host "Locking down PostgreSQL: Disabling Public Access..." -ForegroundColor Yellow
az postgres flexible-server update `
    --name $PostgresServerName `
    --resource-group $ResourceGroupName `
    --public-network-access Disabled

Write-Host "Private Transition Complete! All traffic is now isolated inside $VNetName." -ForegroundColor Green
