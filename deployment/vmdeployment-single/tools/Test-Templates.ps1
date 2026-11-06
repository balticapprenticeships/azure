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
