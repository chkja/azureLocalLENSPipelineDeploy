<#
.SYNOPSIS
Splits a large Azure Monitor Workbook JSON into a main workbook and a capacity child workbook.

.DESCRIPTION
The Azure Monitor Workbooks REST API has a hard payload limit (~600 KB).
This function extracts the 'capacity-tab-group' item from the workbook into a standalone
child workbook, and rewires the Capacity tab in the main workbook to open the child via a
WorkbookTemplate link.

Returns a hashtable with keys:
  MainJson     - Compact JSON string for the main workbook (with placeholder or real resource ID)
  CapacityJson - Compact JSON string for the capacity child workbook

.PARAMETER WorkbookJson
The full workbook JSON string (raw content of the workbook file).

.PARAMETER CapacityResourceId
Azure resource ID for the capacity child workbook.
Use 'LENS_CAPACITY_RESOURCE_ID_PLACEHOLDER' when generating cache files;
supply the real resource ID at deploy time.

.EXAMPLE
$split = Split-LENSWorkbook -WorkbookJson $json -CapacityResourceId $realId
Invoke-WorkbookDeploy ... -SerializedData $split.CapacityJson
Invoke-WorkbookDeploy ... -SerializedData $split.MainJson
#>
function Split-LENSWorkbook {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)] [string]$WorkbookJson,
        [Parameter(Mandatory = $true)] [string]$CapacityResourceId
    )

    $workbookData = $WorkbookJson | ConvertFrom-Json -Depth 50
    $items        = @($workbookData.items)

    $capacityGroupIdx = -1
    $globalParamIdx   = -1
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].name -eq 'capacity-tab-group')        { $capacityGroupIdx = $i }
        if ($items[$i].name -eq 'global-subscription-param') { $globalParamIdx   = $i }
    }

    if ($capacityGroupIdx -lt 0) {
        throw "Split-LENSWorkbook: could not find 'capacity-tab-group' in workbook items."
    }

    # Build capacity child workbook: subscription param + all capacity content items
    $childItemList = [System.Collections.Generic.List[object]]::new()
    if ($globalParamIdx -ge 0) { $childItemList.Add($items[$globalParamIdx]) }
    foreach ($ci in $items[$capacityGroupIdx].content.items) { $childItemList.Add($ci) }

    $childWorkbook = [PSCustomObject]@{
        version             = 'Notebook/1.0'
        items               = $childItemList.ToArray()
        fallbackResourceIds = @('azure monitor')
        '$schema'           = 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
    }

    # Build main workbook: remove capacity-tab-group, update the Capacity tab to link to child
    $mainItems    = @($items | Where-Object { $_.name -ne 'capacity-tab-group' })
    $mainTabsItem = $mainItems | Where-Object { $_.name -eq 'main-tabs' }
    if ($mainTabsItem) {
        $capacityLink = @($mainTabsItem.content.links) | Where-Object { $_.id -eq 'capacity-tab-001' }
        if ($capacityLink.Count -gt 0) {
            $lnk = $capacityLink[0]
            $lnk.linkTarget = 'WorkbookTemplate'
            if ($lnk.PSObject.Properties['cellValue']) { $lnk.PSObject.Properties.Remove('cellValue') }
            if ($lnk.PSObject.Properties['subTarget']) { $lnk.PSObject.Properties.Remove('subTarget') }
            $lnk | Add-Member -NotePropertyName 'templateId'      -NotePropertyValue $CapacityResourceId -Force
            $lnk | Add-Member -NotePropertyName 'workbookContext' -NotePropertyValue ([PSCustomObject]@{
                componentIdSource = 'workbook'
                resourceIdsSource = 'workbook'
                templateIdSource  = 'static'
                templateId        = $CapacityResourceId
                typeSource        = 'workbook'
                gallerySource     = 'workbook'
                locationSource    = 'default'
            }) -Force
        }
    }
    $workbookData.items = $mainItems

    return @{
        MainJson     = ($workbookData | ConvertTo-Json -Depth 50 -Compress)
        CapacityJson = ($childWorkbook | ConvertTo-Json -Depth 50 -Compress)
    }
}
