#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-push consistency checks for the single-template Baltic VM deployment.

.DESCRIPTION
    These templates are fetched from the repository at deploy time, so a template that
    disagrees with its UI definition or with a module is only discovered by a coach whose
    deployment fails. Every check here covers a kind of drift that has shipped at least
    once:

      1. Every JSON file parses.
      2. Every templateLink.contentVersion matches the contentVersion of the module it
         points at (a mismatch fails the deployment at the nested template).
      3. Every file's own version has a changelog.md entry naming that file.
      4. Every UI output maps to a parameter the main template declares, and every
         parameter without a defaultValue is supplied by the UI.
      5. Every routeway the UI offers exists as a key in the main template's rwkeyVault.
      6. The module location is still parameterised, and vmPlatform still exists.
      7. Every course image a UI offers exists in the VM module's image map. Several courses
         sharing one image is deliberate and is not flagged. Course values the template allows
         but no image exists for are reported as warnings, since they are unreachable from
         the UI.
      8. No resource hard-codes an apiVersion - each file declares one <namespace>Api
         variable and every resource uses it.
      9. Every programme in apprenticeshipProgramme has a courseImageValue entry pointing at
         a declared parameter, and nothing is left in the map that the template no longer
         allows.
     10. Every function used in a UI expression is a real createUiDefinition function.
     11. Any _moduleRepo path names the folder these templates actually live in.
     12. The public IP gate holds together - a conditional public IP deployment, the
         publicIpEnabled pass to the NIC module, and a conditional FQDN output, all
         reading the same expression.
     13. Every module builds vmNamePrefix the same way, and the longest host name the
         parameters allow still fits the 15 character Windows limit.
     14. The managed identity gate holds together - a role assignment on each VM, a
         system-assigned identity to assign it to, and the role definition id reaching
         the module from main.json.
     15. The idle hibernation gate holds together - the UI dropdown, main.json's allowed
         values and the VM application all agree on Enabled/Disabled, and the tag the
         automation reads is still written.
     16. No file hardcodes a subscription id. These templates are published to a public
         repository and every subscription reference comes from the routeway Key Vault.
     17. The coach email domain is consistent - the UI appends one domain, the text box
         refuses an address, and the label, placeholder, tooltip and validation message
         all name the same domain the output appends.
     18. No Guest Configuration extension is declared. It is deployed by the Azure Policy
         prerequisites initiative, because installing it here raced the handler upgrade
         and failed whole deployments.
     19. The extensions are chained one per machine, transitively, and every dependency
         uses its own copy loop so the machines still build in parallel.

    The original two-template folder has twelve checks. Three of them existed only to detect
    drift between serverMain and desktopMain - the rwkeyVault map agreeing, the outputs
    agreeing, both mains pointing at the same module ref. They are gone here because there
    is one main template, so there is nothing to drift against.

    Exits 0 when everything is consistent, 1 otherwise.

.PARAMETER Path
    The vmdeployment folder. Defaults to the parent of this script's folder.

.EXAMPLE
    pwsh ./tools/Test-Templates.ps1
#>
[CmdletBinding()]
param(
    [string] $Path
)

$ErrorActionPreference = 'Stop'

if (-not $Path) { $Path = Split-Path -Parent $PSScriptRoot }
$root          = (Resolve-Path -LiteralPath $Path).Path
$modulesDir    = Join-Path $root 'modules'
$changelogPath = Join-Path $root 'changelog.md'

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]
$docs     = @{}

function Add-Failure {
    param([string] $Message)
    $failures.Add($Message) | Out-Null
}

function Add-Warning {
    param([string] $Message)
    $warnings.Add($Message) | Out-Null
}

function Get-Json {
    param([string] $FilePath)
    $key = $FilePath.ToLowerInvariant()
    if (-not $docs.ContainsKey($key)) { return $null }
    return $docs[$key]
}

# UI definitions pair with the main template they drive.
$pairs = @(
    [pscustomobject] @{ Ui = 'ui.json'; Main = 'main.json' }
)

# ---------------------------------------------------------------- 1. JSON parses
$jsonFiles = @()
$jsonFiles += Get-ChildItem -LiteralPath $root -Filter '*.json' -File
if (Test-Path -LiteralPath $modulesDir) {
    $jsonFiles += Get-ChildItem -LiteralPath $modulesDir -Filter '*.json' -File
}

foreach ($file in $jsonFiles) {
    try {
        $raw = Get-Content -LiteralPath $file.FullName -Raw
        $docs[$file.FullName.ToLowerInvariant()] = $raw | ConvertFrom-Json
    }
    catch {
        Add-Failure "JSON is not valid: $($file.Name) - $($_.Exception.Message)"
    }
}

# ------------------------------------------------- 2. templateLink content versions
foreach ($pair in $pairs) {
    $main = Get-Json (Join-Path $root $pair.Main)
    if (-not $main) { Add-Failure "Could not read $($pair.Main)"; continue }

    foreach ($resource in @($main.resources)) {
        $link = $resource.properties.templateLink
        if (-not $link) { continue }

        if ($link.uri -notmatch "/(?<file>[A-Za-z0-9_.\-]+\.json)'\)\]") {
            Add-Failure "$($pair.Main): cannot determine the module file from templateLink uri '$($link.uri)'"
            continue
        }

        $moduleFile = $Matches['file']
        $module     = Get-Json (Join-Path $modulesDir $moduleFile)
        if (-not $module) {
            Add-Failure "$($pair.Main): templateLink points at modules/$moduleFile, which is missing or unreadable"
            continue
        }

        if ($link.contentVersion -ne $module.contentVersion) {
            $message = '{0} -> modules/{1}: link declares contentVersion {2}, module is {3}' -f
                $pair.Main, $moduleFile, $link.contentVersion, $module.contentVersion
            Add-Failure $message
        }
    }
}

# --------------------------------------------------------- 3. changelog coverage
if (-not (Test-Path -LiteralPath $changelogPath)) {
    Add-Failure 'changelog.md is missing'
}
else {
    $changelog = Get-Content -LiteralPath $changelogPath -Raw

    # Versions recorded under "# All Files" apply to every file in the solution.
    $allFilesVersions = @()
    if ($changelog -match '(?ms)^#\s+All Files\s*$(?<body>.*?)(?=^#\s+(?!#)|\z)') {
        $allFilesVersions = [regex]::Matches($Matches['body'], '(?m)^##\s*\[(?<v>[0-9.]+)\]') |
            ForEach-Object { $_.Groups['v'].Value }
    }

    foreach ($file in $jsonFiles) {
        $doc = Get-Json $file.FullName
        if (-not $doc) { continue }

        $names = $doc.PSObject.Properties.Name
        $version = $null
        if ($names -contains 'contentVersion')      { $version = $doc.contentVersion }
        elseif ($names -contains 'currentVersion')  { $version = $doc.currentVersion }

        if (-not $version) {
            Add-Failure "$($file.Name): no contentVersion or currentVersion"
            continue
        }

        if ($allFilesVersions -contains $version) { continue }

        $stem    = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $pattern = '(?m)^##\s*\[' + [regex]::Escape($version) + '\][^\r\n]*\r?\n\[' + [regex]::Escape($stem) + '\]'
        if ($changelog -notmatch $pattern) {
            Add-Failure "changelog.md: no '## [$version]' entry followed by '[$stem]' for $($file.Name)"
        }
    }
}

# ------------------------------------------------- 4. UI outputs vs main parameters
foreach ($pair in $pairs) {
    $ui   = Get-Json (Join-Path $root $pair.Ui)
    $main = Get-Json (Join-Path $root $pair.Main)
    if (-not $ui -or -not $main) { continue }

    $uiOutputs  = @($ui.parameters.outputs.PSObject.Properties.Name)
    $mainParams = @($main.parameters.PSObject.Properties)
    $paramNames = @($mainParams | ForEach-Object { $_.Name })

    foreach ($output in $uiOutputs) {
        if ($paramNames -notcontains $output) {
            Add-Failure "$($pair.Ui): emits '$output', which $($pair.Main) does not declare as a parameter - the portal rejects the deployment"
        }
    }

    foreach ($param in $mainParams) {
        $hasDefault = $param.Value.PSObject.Properties.Name -contains 'defaultValue'
        if (-not $hasDefault -and $uiOutputs -notcontains $param.Name) {
            Add-Failure "$($pair.Main): parameter '$($param.Name)' has no defaultValue and is not supplied by $($pair.Ui)"
        }
    }
}

# ------------------------------------------- 5. routeway values vs rwkeyVault keys
function Find-UiElement {
    param($Node, [string] $Name)

    if ($null -eq $Node) { return $null }

    if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        foreach ($item in $Node) {
            $hit = Find-UiElement -Node $item -Name $Name
            if ($hit) { return $hit }
        }
        return $null
    }

    if ($Node -isnot [psobject]) { return $null }

    if (($Node.PSObject.Properties.Name -contains 'name') -and ($Node.name -eq $Name)) {
        return $Node
    }

    foreach ($prop in $Node.PSObject.Properties) {
        if (@('toolTip', 'label', 'text', 'placeholder') -contains $prop.Name) { continue }
        $hit = Find-UiElement -Node $prop.Value -Name $Name
        if ($hit) { return $hit }
    }
    return $null
}

foreach ($pair in $pairs) {
    $ui   = Get-Json (Join-Path $root $pair.Ui)
    $main = Get-Json (Join-Path $root $pair.Main)
    if (-not $ui -or -not $main) { continue }

    $vault = $main.variables.rwkeyVault
    if (-not $vault) { continue }
    $vaultKeys = @($vault.PSObject.Properties.Name)

    $element = Find-UiElement -Node $ui.parameters.steps -Name 'routeway'
    if (-not $element) {
        Add-Failure "$($pair.Ui): no 'routeway' element found"
        continue
    }

    foreach ($allowed in @($element.constraints.allowedValues)) {
        if ($vaultKeys -notcontains $allowed.value) {
            Add-Failure "$($pair.Ui): routeway option '$($allowed.value)' has no rwkeyVault entry in $($pair.Main) - selecting it fails the Key Vault lookup"
        }
    }
}

# ------------------- 6. the module location is still parameterised, not hard-coded
# P3-1 in the original folder's REVIEW.md. The two-main drift checks that used to live here
# (rwkeyVault agreement, matching outputs) are gone: there is one main template now, so there
# is nothing for them to drift against. That is the point of this folder.
$mainDoc = Get-Json (Join-Path $root 'main.json')
if ($mainDoc) {
    foreach ($name in @('_artifactsLocation', '_artifactsRef')) {
        $param = $mainDoc.parameters.$name
        if (-not $param) {
            Add-Failure "main.json: parameter '$name' is missing - the module URIs are hard-coded again"
        }
        elseif ($param.PSObject.Properties.Name -notcontains 'defaultValue') {
            Add-Failure "main.json: parameter '$name' has no defaultValue, and the UI does not supply it"
        }
    }

    # every platform-specific expression must branch on vmPlatform, never on a stale platform name
    if (-not $mainDoc.parameters.vmPlatform) {
        Add-Failure 'main.json: parameter vmPlatform is missing - it is what makes one template serve both platforms'
    }
}

# ----------------------------- 7. course images: every choice resolves to a real image
# The VM modules look the chosen course up in operatingSystemValues. A value with no entry
# there fails at deployment with a property-not-found error, which says nothing useful.
$vmModuleFor = @{ 'main.json' = 'windowsVm.json' }

foreach ($pair in $pairs) {
    $ui   = Get-Json (Join-Path $root $pair.Ui)
    $main = Get-Json (Join-Path $root $pair.Main)
    $vm   = Get-Json (Join-Path $modulesDir $vmModuleFor[$pair.Main])
    if (-not $ui -or -not $main -or -not $vm) { continue }

    $images = @($vm.variables.operatingSystemValues.PSObject.Properties.Name)
    if (-not $images) { continue }

    # a) what the UI actually offers must resolve, and must not offer the same image twice
    $dropdowns = New-Object System.Collections.Generic.List[object]
    function Find-Dropdowns {
        param($Node)
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            foreach ($item in $Node) { Find-Dropdowns -Node $item }
            return
        }
        if ($Node -isnot [psobject]) { return }
        if ($Node.PSObject.Properties.Name -contains 'name' -and
            $Node.type -eq 'Microsoft.Common.DropDown' -and
            ($Node.name -like 'courseImage*' -or $Node.name -like '*examImage*')) {
            $dropdowns.Add($Node) | Out-Null
        }
        foreach ($prop in $Node.PSObject.Properties) {
            if (@('toolTip', 'label', 'text', 'placeholder') -contains $prop.Name) { continue }
            Find-Dropdowns -Node $prop.Value
        }
    }
    Find-Dropdowns -Node $ui.parameters.steps

    # Several courses sharing one image is deliberate: coaches pick their own course by name,
    # and more than one course is taught from the same build. Do not flag repeated values.
    foreach ($dd in $dropdowns) {
        foreach ($option in @($dd.constraints.allowedValues)) {
            if ($images -notcontains $option.value) {
                Add-Failure "$($pair.Ui): course option '$($option.label)' selects image '$($option.value)', which $($vmModuleFor[$pair.Main]) has no operatingSystemValues entry for"
            }
        }
    }

    # b) values the template still allows but no image exists for: unreachable from the UI
    #    today, so a warning rather than a failure - it becomes a failure above the moment
    #    someone wires one of them into a dropdown.
    foreach ($param in @($main.parameters.PSObject.Properties)) {
        if ($param.Name -notlike '*Course') { continue }
        foreach ($value in @($param.Value.allowedValues)) {
            if ($value -eq 'NoValue') { continue }   # the sentinel for "this dropdown is not in use"
            if ($images -notcontains $value) {
                Add-Warning "$($pair.Main): parameter '$($param.Name)' allows '$value', but $($vmModuleFor[$pair.Main]) has no image map entry for it. Unreachable from the UI today; selecting it would fail."
            }
        }
    }
}

# -------------------------------- 8. apiVersions come from one variable per namespace
# P3-3 standardised these. A hard-coded apiVersion is how the drift started: one file
# ended up with three different versions of the same resource type.
foreach ($file in $jsonFiles) {
    if ($file.Name -like 'ui*') { continue }
    $doc = Get-Json $file.FullName
    if (-not $doc -or -not $doc.resources) { continue }

    function Test-ApiVersions {
        param($Node, [string] $FileName)
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            foreach ($item in $Node) { Test-ApiVersions -Node $item -FileName $FileName }
            return
        }
        if ($Node -isnot [psobject]) { return }
        if ($Node.PSObject.Properties.Name -contains 'apiVersion') {
            if ($Node.apiVersion -notmatch "^\[variables\('\w+Api'\)\]$") {
                Add-Failure "$FileName : resource '$($Node.type)' hard-codes apiVersion '$($Node.apiVersion)' - use the file's one Api variable"
            }
        }
        foreach ($prop in $Node.PSObject.Properties) {
            Test-ApiVersions -Node $prop.Value -FileName $FileName
        }
    }
    Test-ApiVersions -Node $doc.resources -FileName $file.Name
}

# --------------------------- 9. every programme is wired all the way to an image
# Merging two templates means one courseImageValue map covering nine programmes. Adding a
# programme to allowedValues without adding the map entry, or pointing the map at a parameter
# that does not exist, both fail at deployment with a property-not-found error.
if ($mainDoc) {
    $courseMap = $mainDoc.variables.courseImageValue
    $paramNames = @($mainDoc.parameters.PSObject.Properties.Name)

    foreach ($programme in @($mainDoc.parameters.apprenticeshipProgramme.allowedValues)) {
        if (-not $courseMap.$programme) {
            Add-Failure "main.json: programme '$programme' is in apprenticeshipProgramme allowedValues but has no courseImageValue entry"
            continue
        }
        $expr = $courseMap.$programme.courseImageDefinitionName
        if ($expr -notmatch "parameters\('(?<p>\w+)'\)") {
            Add-Failure "main.json: courseImageValue['$programme'] does not resolve to a parameter: $expr"
            continue
        }
        if ($paramNames -notcontains $Matches['p']) {
            Add-Failure "main.json: courseImageValue['$programme'] reads parameter '$($Matches['p'])', which is not declared"
        }
    }

    foreach ($programme in @($courseMap.PSObject.Properties.Name)) {
        if (@($mainDoc.parameters.apprenticeshipProgramme.allowedValues) -notcontains $programme) {
            Add-Warning "main.json: courseImageValue has an entry for '$programme', which apprenticeshipProgramme does not allow - dead map entry"
        }
    }
}

# ------------------- 10. every UI expression uses a real createUiDefinition function
# The portal silently refuses to render a form containing an unknown function, and the sandbox
# reports it as a schema-reference problem rather than naming the culprit. This caught
# `false()`, which does not exist in createUiDefinition - bare `true` / `false` literals are
# the way to write a boolean.
$uiFunctions = @(
    # collection
    'contains', 'empty', 'filter', 'first', 'last', 'length', 'map', 'skip', 'split', 'take',
    # conversion
    'bool', 'decodeBase64', 'decodeUriComponent', 'encodeBase64', 'encodeUriComponent',
    'float', 'int', 'parse', 'string',
    # date
    'addHours', 'addMinutes', 'addSeconds', 'utcNow',
    # logical
    'and', 'coalesce', 'equals', 'greater', 'greaterOrEquals', 'if', 'less', 'lessOrEquals',
    'not', 'or',
    # math
    'add', 'ceil', 'div', 'floor', 'max', 'min', 'mod', 'mul', 'rand', 'range', 'sub',
    # referencing
    'basics', 'location', 'resourceGroup', 'steps', 'subscription',
    # string
    'concat', 'endsWith', 'guid', 'indexOf', 'lastIndexOf', 'replace', 'startsWith',
    'substring', 'toLower', 'toUpper'
)

# prose properties are skipped, so "virtual machine(s)" in a tooltip is not mistaken for a call
$proseProperties = @('toolTip', 'label', 'text', 'placeholder', 'description', 'validationMessage')

foreach ($pair in $pairs) {
    $ui = Get-Json (Join-Path $root $pair.Ui)
    if (-not $ui) { continue }

    $expressions = New-Object System.Collections.Generic.List[string]

    function Get-Expressions {
        param($Node)
        if ($null -eq $Node) { return }
        if ($Node -is [string]) {
            if ($Node.StartsWith('[') -and $Node.EndsWith(']')) { $expressions.Add($Node) | Out-Null }
            return
        }
        if ($Node -is [System.Collections.IEnumerable]) {
            foreach ($item in $Node) { Get-Expressions -Node $item }
            return
        }
        if ($Node -isnot [psobject]) { return }
        foreach ($prop in $Node.PSObject.Properties) {
            if ($proseProperties -contains $prop.Name) { continue }
            Get-Expressions -Node $prop.Value
        }
    }
    Get-Expressions -Node $ui.parameters

    $seen = @{}
    foreach ($expression in $expressions) {
        foreach ($match in [regex]::Matches($expression, '([A-Za-z][A-Za-z0-9]*)\(')) {
            $fn = $match.Groups[1].Value
            if ($uiFunctions -contains $fn) { continue }
            if ($seen.ContainsKey($fn)) { continue }
            $seen[$fn] = $true
            Add-Failure "$($pair.Ui): expression uses '$fn(...)', which is not a createUiDefinition function - the portal will refuse to render the form"
        }
    }
}

# ------------- 11. the module repo path matches the folder these templates live in
# main.json inherited "/deployment/vmdeployment/modules" when it was copied into
# vmdeployment-single, so it would have fetched its modules from the other folder and 404'd.
# The templateLink version check cannot see this: it finds the module by filename locally and
# never looks at the rest of the URL.
$folderName = Split-Path -Leaf $root

foreach ($file in $jsonFiles) {
    if ($file.Name -like 'ui*') { continue }
    $doc = Get-Json $file.FullName
    if (-not $doc -or -not $doc.variables) { continue }
    $repo = $doc.variables._moduleRepo
    if (-not $repo) { continue }

    if ($repo -notmatch "/(?<folder>[A-Za-z0-9._-]+)/modules'") {
        Add-Failure "$($file.Name): cannot read the folder name out of _moduleRepo: $repo"
        continue
    }
    if ($Matches['folder'] -ne $folderName) {
        Add-Failure "$($file.Name): _moduleRepo points at '$($Matches['folder'])/modules' but these templates are in '$folderName' - the modules would be fetched from the wrong folder"
    }
}

# ------------------------- 12. the public IP gate holds together
# rdpPublish decides whether a public IP is deployed at all, and that decision has to be
# made in three places at once: the public IP deployment's condition, the publicIpEnabled
# value passed to the NIC module, and the FQDN output condition. Drop the NIC half and
# every NIC points at an IP that was never created; drop the output half and the
# deployment fails referencing a skipped deployment. Both only show up at deploy time.
$mainDoc = Get-Json (Join-Path $root 'main.json')

if ($mainDoc) {
    $pipDeployment = $mainDoc.resources | Where-Object { $_.name -eq 'DeployPublicIPAddress' }
    $nicDeployment = $mainDoc.resources | Where-Object { $_.name -eq 'DeployNetworkInterface' }
    $pipCondition  = $pipDeployment.condition

    if ($pipCondition) {
        $nicValue = $nicDeployment.properties.parameters.publicIpEnabled.value
        if (-not $nicValue) {
            Add-Failure "main.json: DeployPublicIPAddress is conditional but DeployNetworkInterface is not passed publicIpEnabled - every NIC would point at a public IP that was not created"
        }
        elseif ($nicValue -ne $pipCondition) {
            Add-Failure "main.json: DeployPublicIPAddress condition is '$pipCondition' but publicIpEnabled is passed '$nicValue' - these must be the same expression"
        }

        $fqdnCondition = $mainDoc.outputs.virtualMachineFQDN.condition
        if (-not $fqdnCondition) {
            Add-Failure "main.json: DeployPublicIPAddress is conditional but the virtualMachineFQDN output is not - referencing the outputs of a skipped deployment fails the deployment"
        }
        elseif ($fqdnCondition -ne $pipCondition) {
            Add-Failure "main.json: DeployPublicIPAddress condition is '$pipCondition' but the virtualMachineFQDN output condition is '$fqdnCondition' - these must be the same expression"
        }

        $nicDoc = Get-Json (Join-Path $root 'modules\networkInterface.json')
        if ($nicDoc -and -not $nicDoc.parameters.publicIpEnabled) {
            Add-Failure "modules/networkInterface.json: main.json passes publicIpEnabled but the module does not declare it"
        }
    }
}

# ------------------- 13. machine names agree across modules and fit in 15 characters
# Four modules build vmNamePrefix independently - the VM, its NIC, its public IP and its
# shutdown schedule - and they find each other by that name. One of them spelling it
# differently means the VM looks for a NIC that does not exist. The name also lands in
# osProfile.computerName, where Windows stops at 15 characters, so the parameters'
# own limits have to add up to no more than that: vmName + initials + suffix + index.
$prefixExpressions = @{}

foreach ($file in $jsonFiles) {
    if ($file.Name -like 'ui*') { continue }
    $doc = Get-Json $file.FullName
    if (-not $doc -or -not $doc.variables -or -not $doc.variables.vmNamePrefix) { continue }
    $prefixExpressions[$file.Name] = $doc.variables.vmNamePrefix

    if ($doc.variables.vmNamePrefix -match 'nameSuffix' -and -not $doc.variables.nameSuffix) {
        Add-Failure "$($file.Name): vmNamePrefix reads nameSuffix but the module does not declare it"
    }
}

$distinctPrefixes = $prefixExpressions.Values | Sort-Object -Unique
if ($distinctPrefixes.Count -gt 1) {
    $detail = ($prefixExpressions.GetEnumerator() | Sort-Object Name |
        ForEach-Object { "$($_.Key) -> $($_.Value)" }) -join '; '
    Add-Failure "the modules do not agree on vmNamePrefix, so resources would be created under one name and looked up under another: $detail"
}

# the host name budget
$mainForNames = Get-Json (Join-Path $root 'main.json')
if ($mainForNames) {
    $nameMax     = $mainForNames.parameters.vmName.maxLength
    $initialsMax = $mainForNames.parameters.deliveringCoachInitials.maxLength
    $countMax    = $mainForNames.parameters.vmCount.maxValue

    if (-not $nameMax) {
        Add-Failure "main.json: vmName has no maxLength, so nothing stops a name that exceeds the 15 character Windows host name limit"
    }
    elseif (-not $initialsMax) {
        Add-Failure "main.json: deliveringCoachInitials has no maxLength, so the host name budget cannot be checked"
    }
    else {
        $suffixLength = 0
        $anyPrefix = $prefixExpressions.Values | Select-Object -First 1
        if ($anyPrefix -match 'nameSuffix') {
            $suffixDoc = $jsonFiles | Where-Object { $_.Name -eq 'windowsVm.json' } |
                ForEach-Object { Get-Json $_.FullName }
            if ($suffixDoc.variables.nameSuffix -match "uniqueString\(resourceGroup\(\)\.id\), 0, (\d+)\)") {
                $suffixLength = [int]$Matches[1]
            }
            else {
                Add-Failure "modules/windowsVm.json: cannot read the suffix length out of nameSuffix, so the host name budget cannot be checked"
            }
        }

        $indexDigits = "$countMax".Length
        $worstCase   = $nameMax + $initialsMax + $suffixLength + $indexDigits
        if ($worstCase -gt 15) {
            Add-Failure "the longest host name the parameters allow is $worstCase characters (vmName $nameMax + initials $initialsMax + suffix $suffixLength + index $indexDigits), over the 15 character Windows limit - Azure rejects the deployment"
        }

        $uiFileObj = $jsonFiles | Where-Object { $_.Name -like 'ui*' } | Select-Object -First 1
        if ($uiFileObj) {
            $uiJson = Get-Content -LiteralPath $uiFileObj.FullName -Raw
            if ($uiJson -match '\^\[a-z0-9A-Z\]\{(\d+),(\d+)\}\$') {
                $uiMax = [int]$Matches[2]
                if ($uiMax -gt $nameMax) {
                    Add-Failure "the UI lets a coach type a $uiMax character VM name but main.json allows $nameMax - the portal would accept a name the deployment then rejects"
                }
            }
        }
    }
}

# ------------------- 14. the managed identity gate holds together
# A role assignment is useless without an identity to assign it to, and an identity
# the module never receives a role definition id for is a silent no-op. The three
# halves - the roleAssignments resource, identity.type on the VM, and the parameter
# arriving from main.json - have to move together or the self-hibernate feature is
# quietly dead.
$vmModule = $jsonFiles | Where-Object { $_.Name -eq 'windowsVm.json' } | Select-Object -First 1
if ($vmModule) {
    $vmDoc = Get-Json $vmModule.FullName
    $roleRes = $vmDoc.resources |
        Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' }
    $vmRes = $vmDoc.resources |
        Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' } | Select-Object -First 1

    if ($roleRes) {
        if (-not $vmRes.identity -or $vmRes.identity.type -ne 'SystemAssigned') {
            Add-Failure "modules/windowsVm.json: a role assignment is declared but the virtual machine has no SystemAssigned identity, so there is no principal to assign the role to"
        }
        if (-not $vmDoc.parameters.idleHibernateRoleDefinitionId) {
            Add-Failure "modules/windowsVm.json: the role assignment reads idleHibernateRoleDefinitionId but the module does not declare it as a parameter"
        }
        foreach ($r in @($roleRes)) {
            if (-not $r.scope) {
                Add-Failure "modules/windowsVm.json: the role assignment has no scope, so it would be assigned at the resource group instead of the one machine it is meant for"
            }
            if ($r.properties.principalId -notmatch 'identity\.principalId') {
                Add-Failure "modules/windowsVm.json: the role assignment principalId does not read the machine identity.principalId"
            }
        }
    }
    elseif ($vmRes.identity) {
        Add-Warning "modules/windowsVm.json: the virtual machine has a managed identity but nothing assigns it a role, so the identity can do nothing"
    }

    $mainForIdentity = Get-Json (Join-Path $root 'main.json')
    if ($roleRes -and $mainForIdentity) {
        if (-not $mainForIdentity.parameters.idleHibernateRoleDefinitionId) {
            Add-Failure "main.json: windowsVm.json needs idleHibernateRoleDefinitionId but main.json does not declare it, so the module would fall back to its own default and assign nothing"
        }
        $vmDeployment = $mainForIdentity.resources |
            Where-Object { $_.name -eq 'DeployVm' } | Select-Object -First 1
        if ($vmDeployment -and -not $vmDeployment.properties.parameters.idleHibernateRoleDefinitionId) {
            Add-Failure "main.json: DeployVm does not pass idleHibernateRoleDefinitionId to windowsVm.json, so no role is ever assigned"
        }
        if (-not $mainForIdentity.parameters.idleHibernateRoleDefinitionId.defaultValue) {
            Add-Warning "main.json: idleHibernateRoleDefinitionId has an empty default, so a portal deployment builds the machines with an identity but no self-hibernate role - paste the custom role GUID as the default"
        }
    }
}

# ------------------- 15. the idle hibernation gate holds together
# Four things have to agree: the UI dropdown, main.json's allowedValues, the tag the
# external automation filters on, and the condition that installs the VM application.
# The failure mode is silent - a coach picks Enabled, the tag says Enabled, and no
# application is ever installed, so nothing hibernates and nothing complains.
$vmModule = $jsonFiles | Where-Object { $_.Name -eq 'windowsVm.json' } | Select-Object -First 1
$mainForIdle = Get-Json (Join-Path $root 'main.json')
$uiForIdle = $jsonFiles | Where-Object { $_.Name -like 'ui*' } | Select-Object -First 1

if ($vmModule -and $mainForIdle) {
    $vmIdleDoc = Get-Json $vmModule.FullName
    $idleParam = $mainForIdle.parameters.idleHibernate

    if (-not $idleParam) {
        Add-Failure "main.json: no idleHibernate parameter - the idle hibernation option has gone missing"
    }
    else {
        $allowed = @($idleParam.allowedValues)
        foreach ($v in @('Enabled', 'Disabled')) {
            if ($allowed -notcontains $v) {
                Add-Failure "main.json: idleHibernate does not allow '$v' - the UI offers Enabled and Disabled, so the deployment would reject what a coach picked"
            }
        }
        if ($idleParam.defaultValue -ne 'Disabled') {
            Add-Failure "main.json: idleHibernate defaults to '$($idleParam.defaultValue)' rather than Disabled, so a CLI deployment would turn idle hibernation on without being asked"
        }
    }

    # the tag the automation reads
    $vmTags = $vmIdleDoc.variables.vmTags
    if ($vmTags -and -not $vmTags.IdleHibernate) {
        Add-Failure "modules/windowsVm.json: the virtual machine tags no longer include IdleHibernate, which is what the idle hibernation automation filters on"
    }

    # the VM application
    $vmRes = $vmIdleDoc.resources |
        Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' } | Select-Object -First 1
    if ($vmRes.properties.applicationProfile) {
        $profileExpr = [string]$vmRes.properties.applicationProfile
        if ($profileExpr -notmatch 'installIdleHibernateApp') {
        Add-Failure "modules/windowsVm.json: applicationProfile does not read installIdleHibernateApp, so the VM application is not gated on the idle hibernation option"
        }
        $gate = [string]$vmIdleDoc.variables.installIdleHibernateApp
        if ($gate -notmatch "idleHibernate'\), 'Enabled'") {
            Add-Failure "modules/windowsVm.json: installIdleHibernateApp does not test idleHibernate against Enabled, so the application would install whatever a coach picked"
        }
        if ($gate -notmatch 'idleHibernateAppName') {
            Add-Failure "modules/windowsVm.json: installIdleHibernateApp does not check idleHibernateAppName, so an empty application name would be composed into a malformed package reference"
        }
        # the package id is composed, not literal, so the subscription is never hardcoded
        $packageId = [string]$vmIdleDoc.variables.idleHibernateAppPackageId
        if (-not $packageId) {
            Add-Failure "modules/windowsVm.json: no idleHibernateAppPackageId variable - the VM application package id has to be composed from the subscription id read from the Key Vault"
        }
        elseif ($packageId -notmatch "parameters\('subscriptionId'\)") {
            Add-Failure "modules/windowsVm.json: idleHibernateAppPackageId does not read the subscriptionId parameter, so the subscription is coming from somewhere other than the routeway Key Vault"
        }
        foreach ($n in @('idleHibernateAppName', 'idleHibernateAppVersion')) {
            if (-not $vmIdleDoc.parameters.$n) {
                Add-Failure "modules/windowsVm.json: the VM application needs $n but the module does not declare it as a parameter"
            }
            if (-not $mainForIdle.parameters.$n) {
                Add-Failure "main.json: windowsVm.json needs $n but main.json does not declare it"
            }
        }
        $vmDeploy = $mainForIdle.resources |
            Where-Object { $_.name -eq 'DeployVm' } | Select-Object -First 1
        if ($vmDeploy) {
            foreach ($n in @('idleHibernateAppName', 'idleHibernateAppVersion')) {
                if (-not $vmDeploy.properties.parameters.$n) {
                    Add-Failure "main.json: DeployVm does not pass $n to windowsVm.json, so the application package id would be built from the module defaults"
                }
            }
        }
        if (-not $mainForIdle.parameters.idleHibernateAppName.defaultValue) {
            Add-Warning "main.json: idleHibernateAppName has an empty default, so picking Enabled tags the machines for idle hibernation without installing the application that performs it"
        }
    }
    elseif ($vmIdleDoc.parameters.idleHibernateAppName) {
        Add-Failure "modules/windowsVm.json: idleHibernateAppName is declared but no applicationProfile uses it, so picking Enabled installs nothing"
    }

    # and the UI has to offer the same two values, by the same name
    if ($uiForIdle) {
        $uiIdleJson = Get-Content -LiteralPath $uiForIdle.FullName -Raw
        if ($uiIdleJson -notmatch '"idleHibernate"') {
            Add-Failure "$($uiForIdle.Name): no idleHibernate control or output, so main.json would fall back to its own default and a coach could never turn idle hibernation on"
        }
        $uiDoc = Get-Json $uiForIdle.FullName
        $uiOutputs = $uiDoc.parameters.outputs
        if ($uiOutputs -and -not $uiOutputs.idleHibernate) {
            Add-Failure "$($uiForIdle.Name): the outputs section does not map idleHibernate, so the coach's choice never reaches main.json"
        }
        $uiIdleControl = [regex]::Match($uiIdleJson,
            '"name"\s*:\s*"idleHibernate".*?"toolTip"', 'Singleline')
        if ($uiIdleControl.Success) {
            if ($uiIdleControl.Value -match '"visible"\s*:\s*false') {
                Add-Failure "$($uiForIdle.Name): the idleHibernate control is hidden, so the option a coach is meant to configure is invisible"
            }
            foreach ($v in @('Enabled', 'Disabled')) {
                if ($uiIdleControl.Value -notmatch "\`"value\`"\s*:\s*\`"$v\`"") {
                    Add-Failure "$($uiForIdle.Name): the idleHibernate dropdown does not offer the value '$v', which main.json allows"
                }
            }
            if ($uiIdleControl.Value -notmatch '"defaultValue"\s*:\s*"Disabled"') {
                Add-Failure "$($uiForIdle.Name): the idleHibernate dropdown does not default to Disabled"
            }
        }
    }
}

# ------------------- 16. no file hardcodes a subscription id
# Every subscription reference in this folder is read from the routeway Key Vault, and
# these templates are served unauthenticated from a public repository. A literal
# subscription GUID in a resource id is both an inconsistency and a tenant move that
# needs a template edit rather than a Key Vault edit.
foreach ($file in $jsonFiles) {
    $raw = Get-Content -LiteralPath $file.FullName -Raw
    $hits = [regex]::Matches($raw, '/subscriptions/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    foreach ($hit in $hits) {
        Add-Failure "$($file.Name): hardcodes a subscription id ($($hit.Value)) - read it from the routeway Key Vault and compose the resource id, the way windowsVm.json builds imageReference and idleHibernateAppPackageId"
    }
}

# ------------------- 17. the coach email domain is consistent
# The UI asks for a name and appends the domain, so the domain exists in two places at
# once: the output expression and the wording a coach reads. Editing one and not the
# other produces an address that is wrong in a way nobody notices until the tag is read.
$uiEmailFile = $jsonFiles | Where-Object { $_.Name -like 'ui*' } | Select-Object -First 1
if ($uiEmailFile) {
    $uiEmailDoc = Get-Json $uiEmailFile.FullName
    $emailOutput = [string]$uiEmailDoc.parameters.outputs.deliveringCoachEmail

    if (-not $emailOutput) {
        Add-Failure "$($uiEmailFile.Name): no deliveringCoachEmail output, so the coach email never reaches main.json"
    }
    elseif ($emailOutput -notmatch 'concat\(') {
        # the box may refuse an @, in which case something has to add the domain
        $plainRaw = Get-Content -LiteralPath $uiEmailFile.FullName -Raw
        $plainControl = [regex]::Match($plainRaw,
            '"name"\s*:\s*"coachEmail".*?"toolTip"\s*:\s*"[^"]*"', 'Singleline')
        $plainRegex = [regex]::Match($plainControl.Value, '"regex"\s*:\s*"([^"]*)"')
        if ($plainRegex.Success -and $plainRegex.Groups[1].Value -notmatch '@') {
            Add-Failure "$($uiEmailFile.Name): the coachEmail box refuses an @ but the deliveringCoachEmail output appends no domain, so every coach would be tagged with a bare name instead of an email address"
        }
    }
    else {
        $domainMatch = [regex]::Match($emailOutput, "'(@[A-Za-z0-9.-]+\.[A-Za-z]{2,})'")
        if (-not $domainMatch.Success) {
            Add-Failure "$($uiEmailFile.Name): the deliveringCoachEmail output concatenates something that is not a domain literal - a coach would get a malformed address"
        }
        else {
            $domain = $domainMatch.Groups[1].Value

            # find the control the output reads
            $uiEmailRaw = Get-Content -LiteralPath $uiEmailFile.FullName -Raw
            $control = [regex]::Match($uiEmailRaw,
                '"name"\s*:\s*"coachEmail".*?"toolTip"\s*:\s*"[^"]*"', 'Singleline')
            if (-not $control.Success) {
                Add-Failure "$($uiEmailFile.Name): the deliveringCoachEmail output appends $domain but there is no coachEmail control to read from"
            }
            else {
                $block = $control.Value

                $regexMatch = [regex]::Match($block, '"regex"\s*:\s*"([^"]*)"')
                if ($regexMatch.Success -and $regexMatch.Groups[1].Value -match '@') {
                    Add-Failure "$($uiEmailFile.Name): the coachEmail box accepts an @ but the output appends $domain, so a coach typing their full address would get it twice"
                }

                $placeholder = [regex]::Match($block, '"placeholder"\s*:\s*"([^"]*)"')
                if ($placeholder.Success -and $placeholder.Groups[1].Value -match '@') {
                    Add-Failure "$($uiEmailFile.Name): the coachEmail placeholder shows an address with an @, which tells a coach to type what the box now rejects"
                }

                # every domain a coach reads has to be the one that gets appended
                foreach ($m in [regex]::Matches($block, '@[A-Za-z0-9.-]+\.[A-Za-z]{2,}')) {
                    if ($m.Value -ne $domain) {
                        Add-Failure "$($uiEmailFile.Name): the coachEmail control names $($m.Value) but the output appends $domain - a coach would be told one domain and tagged with another"
                    }
                }
                if ($block -notmatch [regex]::Escape($domain)) {
                    Add-Failure "$($uiEmailFile.Name): the coachEmail control never names $domain, so a coach cannot see what is appended to what they type"
                }
            }
        }
    }
}

# ------------------- 18. the Guest Configuration extension is not deployed from here
# Removed 9.11.2026 after it failed a multi machine deployment. The handler upgrade and
# the install raced each other inside the VM, each unzipping over the other, and one
# machine failing fails the whole DeployVm. It is now deployed by the built-in initiative
# "Deploy prerequisites to enable Guest Configuration policies on virtual machines",
# which also handles the managed identity it requires. Re-adding it here brings the race
# back, so this fails rather than warns - see README.md before deleting this check.
foreach ($file in $jsonFiles) {
    if ($file.Name -like 'ui*') { continue }
    $gcDoc = Get-Json $file.FullName
    if (-not $gcDoc -or -not $gcDoc.resources) { continue }
    foreach ($res in $gcDoc.resources) {
        if ($res.type -ne 'Microsoft.Compute/virtualMachines/extensions') { continue }
        if ($res.properties.publisher -eq 'Microsoft.GuestConfiguration') {
            Add-Failure "$($file.Name): declares a Microsoft.GuestConfiguration extension. It is deployed by the Azure Policy prerequisites initiative instead, because installing it here raced the handler upgrade on the VM and failed whole deployments - see README.md"
        }
    }
}

# ------------------- 19. the extension chain is intact and still per machine
# The extensions install one at a time on each machine. Two things can quietly break
# that, and neither shows up until a deployment misbehaves:
#
#  - a chain written A -> B -> C severs when B is skipped. ARM removes a skipped
#    conditional resource from the dependencies rather than inheriting its own, so C
#    would fall back to depending on the machine alone and run beside A. Three of the
#    four extensions are conditional, so every extension has to depend on EVERY earlier
#    one, not just the previous one.
#  - a dependency that uses another loop's copyIndex chains across machines instead of
#    within one, which would serialise twenty machines into one queue.
$extensionOrder = @('NvidiaGPUDriver', 'AMDGpuDriver', 'GuestAttestation', 'Microsoft.PowerShell.DSC')

$chainModule = $jsonFiles | Where-Object { $_.Name -eq 'windowsVm.json' } | Select-Object -First 1
if ($chainModule) {
    $chainDoc = Get-Json $chainModule.FullName
    $extensions = @($chainDoc.resources |
        Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines/extensions' })

    $declared = @()
    foreach ($ext in $extensions) {
        $declared += ($ext.name -split '/')[-1] -replace "'.*$", ''
    }
    foreach ($name in $declared) {
        if ($extensionOrder -notcontains $name) {
            Add-Failure "modules/windowsVm.json: extension '$name' is not in the chain order this check knows about - add it to `$extensionOrder in the right position, or it will install beside the others"
        }
    }

    foreach ($ext in $extensions) {
        $name = ($ext.name -split '/')[-1] -replace "'.*$", ''
        if ($extensionOrder -notcontains $name) { continue }
        $loop = $ext.copy.name
        $deps = @($ext.dependsOn)

        # it has to wait for its own machine
        if (-not ($deps | Where-Object { $_ -match "Microsoft.Compute/virtualMachines'" })) {
            Add-Failure "modules/windowsVm.json: extension $name does not depend on the virtual machine"
        }

        # every dependency must be scoped to this resource's own copy loop
        foreach ($dep in $deps) {
            $loopsUsed = [regex]::Matches($dep, "copyIndex\('([^']+)'") |
                ForEach-Object { $_.Groups[1].Value }
            foreach ($used in $loopsUsed) {
                if ($used -ne $loop) {
                    Add-Failure "modules/windowsVm.json: extension $name has a dependency using copyIndex('$used') but its own loop is '$loop' - that chains across machines and would build them one at a time instead of in parallel"
                }
            }
        }

        # and for every extension ahead of it in the order
        $position = $extensionOrder.IndexOf($name)
        for ($i = 0; $i -lt $position; $i++) {
            $earlier = $extensionOrder[$i]
            if ($declared -notcontains $earlier) { continue }
            $wanted = "'$earlier')]"
            if (-not ($deps | Where-Object { $_ -like "*$wanted" })) {
                Add-Failure "modules/windowsVm.json: extension $name does not depend on $earlier, which runs before it. A chain that only names the previous extension severs when an intermediate one is skipped, and three of these are conditional"
            }
        }

        # nothing may wait for something that comes after it
        for ($i = $position + 1; $i -lt $extensionOrder.Count; $i++) {
            $later = $extensionOrder[$i]
            if ($deps | Where-Object { $_ -like "*'$later')]" }) {
                Add-Failure "modules/windowsVm.json: extension $name depends on $later, which is meant to run after it - that is a cycle or a reversed chain"
            }
        }
    }
}

# ----------------------------------------------------------------------- report
Write-Host ''
if ($warnings.Count -gt 0) {
    Write-Host "Warnings ($($warnings.Count)) - not deployment-breaking today:" -ForegroundColor Yellow
    foreach ($warning in $warnings) { Write-Host "  - $warning" -ForegroundColor Yellow }
    Write-Host ''
}

if ($failures.Count -eq 0) {
    Write-Host 'Template checks passed.' -ForegroundColor Green
    exit 0
}

Write-Host "Template checks failed ($($failures.Count)):" -ForegroundColor Red
foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
Write-Host ''
exit 1
