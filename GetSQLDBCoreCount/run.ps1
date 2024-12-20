using namespace System.Net

# Input bindings are passed in via param block.
param($Request, $TriggerMetadata)

$storageAccountKey = $Env:STORAGE_ACCOUNT_KEY
$storageAccountName = $Env:STORAGE_ACCOUNT
$containerName = $Env:CONTAINER_NAME

# Write to the Azure Functions log stream.
Write-Host "PowerShell HTTP trigger function started successfully."
# Interact with query parameters or the body of the request.
$outputFilename = "SQLDBCoreCount.csv"
$filenameParam = $Request.Query.FileName
if (-not $filenameParam) {
    $filenameParam = $Request.Body.FileName
}
if ($filenameParam) {
    $outputFileName = $filenameParam + ".csv"
}
$body = ""
if (-not $storageAccountName) {
    $body = "Missing value - You must set the storage account name in the app's environment variables."
}
if (-not $storageAccountKey) {
    $body = "Missing value - You must set the storage account key in the app's environment variables."
}
if (-not $containerName) {
    $body = "Missing value - You must set the storage container name in the app's environment variables."
}
if ($body -ne "") {
    # Associate values to output bindings by calling 'Push-OutputBinding'.
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body = $body
    })
    return
}

$body = "This HTTP triggered function was initiated successfully."

$moduleVersion = Get-Command -Module 'Az.ResourceGraph' -CommandType 'Cmdlet' | Select-Object Version
Write-Host "Installed Az.ResourceGraph module ready for use."
Write-Host "Version: $moduleVersion"

# Set context to the current tenant (enables query results to include all subs)
$tenantId = Get-AzTenant | Select-Object TenantId
Write-Host "Current tenant ID: $tenantId"
Write-Host "Setting context to current tenant."
Set-AzContext -Tenant $tenantId

# Show which subscriptions are available in the current context
$currSubs = (Get-AzContext).Account.ExtendedProperties.Subscriptions
Write-Host "Curr subs: $currSubs"

$PSDefaultParameterValues=@{"Search-AzGraph:Subscription"= $(Get-AzSubscription).ID}

$sqldbQuery = 'resources ' +
'| where type =~ "microsoft.sql/servers/databases" ' +
'| where name != "master"' +
'| project name,resourceGroup,subscriptionId,location,tostring(properties[''elasticPoolId'']),' +
'properties[''currentSku''].name, properties[''currentSku''].capacity, properties[''currentSku''].tier,' +
'properties[''maxSizeBytes'']/1024/1022/1024, tostring(properties[''highAvailabilityReplicaCount'']), ' +
'tostring(properties[''licenseType'']), tostring(properties[''subscriptionName''])'

Write-Host "Running query to retrieve SQL DB core count..."

# Note: including the -First 1000 parameter ensures that the results don't cut off at 100 items
$fullResults = Search-AzGraph -First 1000 -Query $sqldbQuery
$bytesResult = @()
$numLines = 0
$currLine = "Name,ResourceGroup,SubscriptionId,Location,ElasticPoolId,CurrentSKUName,CurrentSKUCapacity,CurrentSKUTier,MaxSizeBytes,HAReplicaCount,LicenseType,SubscriptionName,EntryDate"
$currLineBytes = [system.Text.Encoding]::UTF8.getBytes($currLine) + '0x0d' + '0x0a'
$bytesResult += $currLineBytes
$entryDate = Get-Date -Format "yyyy-MM-dd"
foreach($currEntry in $fullResults) {
    $name = $currEntry.name
    $resourceGroup = $currEntry.resourceGroup
    $subscriptionId = $currEntry.subscriptionId
    $location = $currEntry.location
    $elasticPoolId = $currEntry.properties_elasticPoolId
    $currentSkuName = $currEntry.properties_currentSku_name
    $currentSkuCapacity = $currEntry.properties_currentSku_capacity
    $currentSkuTier = $currEntry.properties_currentSku_tier
    $maxSizeBytes = $currEntry.Column1
    $highAvailabilityReplicaCount = $currEntry.properties_highAvailabilityReplicaCount
    $licenseType = $currEntry.properties_licenseType
    $subscriptionName = $currEntry.properties_subscriptionName
    $currLine = "$name,$resourceGroup,$subscriptionId,$location,$elasticPoolId,$currentSkuName,$currentSkuCapacity,$currentSkuTier,"
    $currLine += "$maxSizeBytes,$highAvailabilityReplicaCount,$licenseType,$subscriptionName,$entryDate"
    $currLineBytes = [system.Text.Encoding]::UTF8.getBytes($currLine) + '0x0d' + '0x0a'
    $bytesResult += $currLineBytes
    $numLines++
}
Write-Host "Number of lines in result: $numLines"
Write-Host "Number of bytes in result: "
Write-Host $bytesResult.Length

if ($numLines -gt 0) {
    $body = "Success - query ran and returned results ($numLines lines)"

    $storageContext = New-AzStorageContext -StorageAccountName $storageAccountName -StorageAccountKey $storageAccountKey
    Write-Host "Set storage context: $storageContext"

    $container = Get-AzStorageContainer -Name $containerName -Context $storageContext
    $container.CloudBlobContainer.GetBlockBlobReference($outputFileName).UploadFromByteArray($bytesResult,0,$bytesResult.Length)
    $body += " Results written to output file : $outputFileName"
}
else {
    $body = "Error - could not run query, or no results returned."
}

# Associate values to output bindings by calling 'Push-OutputBinding'.
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body = $body
})
