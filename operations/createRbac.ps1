<#
.VERSION 2.0.0
.AUTHOR Chris Langford
.COPYRIGHT (c) 2026 Chris Langford. All rights reserved.
.TGAS Network Automation, Azure Automation
.SYNOPSIS
Generic RBAC assignment framework for Automation Account Managed Identities.

.DESCRIPTION
- Discovers Automation Accounts across subscriptions
- Ensures Managed Identity exists
- Assigns one or more roles at a configurable scope
- Supports subscription, resource group, or resource-level scopes

.NOTES
- Requires Az PowerShell module
- Run with appropriate permissions to assign RBAC
- LASTEDIT 09.04.2026

#>

# ----------------------------
# CONFIGURATION
# ----------------------------

$config = @{
    # Where to FIND Automation Accounts
    SourceSubscriptions = @(
        "7407a924-658f-4c31-80d7-94a179f00eb5",
        "c371fde2-8407-4d1b-ba6b-952c89f39dbe",
        "237543eb-bc57-442b-809d-4054c62cfa97",
        "022ddf75-71d6-4547-bf64-944b57027f62",
        "42ae00f5-c447-4ade-bb2a-55b2a5d7480d",
        "f0517680-7d83-43b4-a9db-0ff64551716a"
    )

    AutomationAccountFilter = "*AutomationAccount"

    # RBAC TARGET CONFIG
    Target = @{
        SubscriptionId = "c4790cb5-6d79-4f3b-914e-3307eb65c9d3"

        # ScopeType: "Subscription" | "ResourceGroup" | "Resource"
        ScopeType = "Subscription"

        # Required if ScopeType = ResourceGroup or Resource
        ResourceGroupName = "NetworkAutomationRg"

        # Required if ScopeType = Resource
        ResourceId = "/subscriptions/<subId>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/cidrstoresa"
    }

    # Roles to assign (can be multiple)
    Roles = @(
        "Network Contributor"
        # "Storage Table Data Contributor"
    )
}

# ----------------------------
# FUNCTIONS
# ----------------------------

function Get-Scope {
    param ($Target)

    switch ($Target.ScopeType) {

        "Subscription" {
            return "/subscriptions/$($Target.SubscriptionId)"
        }

        "ResourceGroup" {
            return "/subscriptions/$($Target.SubscriptionId)/resourceGroups/$($Target.ResourceGroupName)"
        }

        "Resource" {
            return $Target.ResourceId
        }

        default {
            throw "Invalid ScopeType: $($Target.ScopeType)"
        }
    }
}

function Test-ManagedIdentity {
    param ($AutomationAccount)

    if ($AutomationAccount.Identity.PrincipalId) {
        return $AutomationAccount
    }

    Write-Output "Enabling MI: $($AutomationAccount.AutomationAccountName)"

    $updated = Set-AzAutomationAccount `
        -ResourceGroupName $AutomationAccount.ResourceGroupName `
        -Name $AutomationAccount.AutomationAccountName `
        -AssignSystemIdentity `
        -ErrorAction Stop

    # Retry for propagation
    for ($i = 0; $i -lt 5; $i++) {
        Start-Sleep -Seconds 5

        $updated = Get-AzAutomationAccount `
            -ResourceGroupName $AutomationAccount.ResourceGroupName `
            -Name $AutomationAccount.AutomationAccountName

        if ($updated.Identity.PrincipalId) {
            return $updated
        }
    }

    throw "MI enablement failed: $($AutomationAccount.AutomationAccountName)"
}

function Test-RoleAssignment {
    param (
        [string]$PrincipalId,
        [string]$Scope,
        [string]$RoleName
    )

    $existing = Get-AzRoleAssignment `
        -ObjectId $PrincipalId `
        -Scope $Scope `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.RoleDefinitionName -eq $RoleName }

    if ($existing) {
        Write-Output "✔ Role '$RoleName' already assigned"
        return
    }

    Write-Output "➜ Assigning '$RoleName'"

    New-AzRoleAssignment `
        -ObjectId $PrincipalId `
        -RoleDefinitionName $RoleName `
        -Scope $Scope `
        -ErrorAction Stop
}

# ----------------------------
# MAIN
# ----------------------------

$scope = Get-Scope -Target $config.Target
Write-Output "Target Scope: $scope"

foreach ($sub in $config.SourceSubscriptions) {

    Write-Output "`n--- Source Subscription: $sub ---"

    try {
        Set-AzContext -SubscriptionId $sub -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warning "Context switch failed: $sub"
        continue
    }

    $automationAccounts = Get-AzAutomationAccount -ErrorAction SilentlyContinue |
        Where-Object { $_.AutomationAccountName -like $config.AutomationAccountFilter }

    foreach ($aa in $automationAccounts) {

        Write-Output "Processing: $($aa.AutomationAccountName)"

        try {
            $aa = Test-ManagedIdentity -AutomationAccount $aa
            $principalId = $aa.Identity.PrincipalId

            if (-not $principalId) {
                throw "Missing PrincipalId"
            }

            # Switch to target subscription for RBAC
            Set-AzContext -SubscriptionId $config.Target.SubscriptionId -ErrorAction Stop | Out-Null

            foreach ($role in $config.Roles) {
                Test-RoleAssignment `
                    -PrincipalId $principalId `
                    -Scope $scope `
                    -RoleName $role
            }
        }
        catch {
            Write-Warning "Failed: $($aa.AutomationAccountName) | $_"
        }
    }
}

Write-Output "`nRBAC assignment complete."