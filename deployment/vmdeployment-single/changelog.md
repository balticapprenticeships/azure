# Change Log
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

This folder is the single-template implementation. It starts at 1.0.0.0 rather than continuing
the 4.x line of `vmdeployment`, because every file here is new even where the content is carried
over. See `DESIGN.md` for what was merged and why.

# User Interface

## [1.4.0.0] 6.11.2026
[ui]
### Change
  the idle virtual machine dropdown is now visible and configurable. It was hidden, labelled
  "Currently Not in Use" and offered Yes/No; it is now "Hibernate Idle Virtual Machines",
  offering Disabled and Enabled, defaulting to Disabled.
  renamed the control and the output from idleVm to idleHibernate.
  Updated currentVersion to 1.4.0.0
### Note
  the tooltip says the VM size has to support hibernation, because this option does not
  change hibernationEnabled and cannot make an unsupported size hibernate.

## [1.3.0.0] 6.11.2026
[ui]
### Change
  the VM name box now allows 3 to 8 characters rather than 3 to 10, with the validation
  message and tooltip saying why. The full machine name is vmName + coach initials + a 3
  character uniqueness suffix + the machine number, and Windows host names stop at 15
  characters: 8 + 2 + 3 + 2 = 15 exactly.
  the placeholder example changed from 306Client, which is 9 characters and would no longer
  validate, to 306Clnt. Pick a different example if there is a better short form.
  Updated currentVersion to 1.3.0.0
### Note
  this is the coach-facing cost of the DNS collision fix - see main 1.4.0.0. A coach who
  used the full 10 characters will have to shorten the name.

## [1.2.0.0] 6.11.2026
[ui]
### Change
  the RDP publish dropdown now says what it does to the public IP address. Yes hands the
  machines to the RDP publishing automation and builds them with no public IP of their own,
  so there is no DNS name to connect to directly; No gives each machine a public IP and a
  DNS name. The option values are unchanged - this is the label, the two option descriptions
  and the tooltip.
  Updated currentVersion to 1.2.0.0
### Note
  the dropdown is not new and neither are its values. What changed is in main.json 1.3.0.0:
  rdpPublish now decides whether the public IP is deployed at all, not just the tag value.

## [1.1.2.0] 4.11.2026
[ui]
### Fix
  the hibernationEnabled output called false(), which is not a createUiDefinition function -
  the function list has no false() or true(). The portal and the sandbox refuse to render a
  form containing an unknown function, which is why ui.json 1.1.0.0 and 1.1.1.0 would not
  preview while the two live UIs did. Replaced with the bare literal false, which is how the
  existing UIs write booleans, for example equals(..., true).
  Updated currentVersion to 1.1.2.0
### Note
  tools/Test-Templates.ps1 gained a check for this - every function used in a UI expression is
  now compared against the published createUiDefinition function list. Prose properties such as
  toolTip are skipped so that "virtual machine(s)" is not read as a call. The same check was
  added to ..\vmdeployment.

## [1.1.1.0] 4.11.2026
[ui]
### Change
  simplified the hibernation checkbox visible expression from 868 to 488 characters. It used to
  nest the platform if() inside every size comparison; it now compares each platform's own size
  element. The set of sizes it allows is unchanged and still verified against hibernationBySize.
  Updated currentVersion to 1.1.1.0
### Note
  this was tidying, not a fix. The createUiDefinition sandbox reports schema errors for this
  file, but it reports the same five errors for the two live UIs in ..\vmdeployment as well -
  the published 0.1.2-preview schema predates isWizard and Microsoft.Common.Section, and its
  sibling $refs are relative and often fail to resolve in the editor. See README.md.

## [1.1.0.0] 4.11.2026
[ui]
### Add
  new "Enable hibernation" checkbox in the Virtual Machine Configuration step, for both
  platforms. It is visible only when the selected VM size supports hibernation - Standard_D2s_v5,
  Standard_D4s_v5, Standard_D2as_v5, Standard_D4as_v5 and Standard_NV4as_v4 - so a coach cannot
  tick something Azure will refuse. The output falls back to false when the checkbox is hidden.
### Change
  the RDP publish dropdown is now visible for both platforms, not just Windows Server.
  relabelled it from "Allow RDP Access to VMs. DO NOT USE, DEV ONLY" to "Publish RDP access for
  these VMs", with option labels No and Yes rather than "For Development Use ONLY". It sets the
  RdpPublish tag that other automation reads; it has never changed the network security group,
  which allows RDP from any address by design.
  removed the platform guard from the rdpPublish output - it no longer needs to resolve to No
  for client builds.

## [1.0.0.0] 4.11.2026
[ui]
### Add
  single createUiDefinition serving both platforms, merged from uiSvrDefinition 4.2.0.0 and
  uiWcDefinition 4.6.1.0.
  new vmPlatform dropdown as the first element of the OS Details step - Windows Server or
  Windows 11 Client. Everything platform-specific keys off it.
  paired, platform-gated elements where the options differ: serverProgramme/clientProgramme,
  serverImageVersion/clientImageVersion, serverVmSize/clientVmSize and
  serverBootcampCourse/clientBootcampCourse. Each pair resolves to one output with if().
  the course dropdowns keep their own visible conditions, now gated on platform as well as
  programme, and point at the right programme element.
  rdpPublish is visible only for Windows Server.
  every course output is wrapped in coalesce(..., 'NoValue') so a hidden dropdown cannot pass
  null to a string parameter.
### Note
  carried over from both source UIs: the vmCount Slider, the corrected createdBy regex, the
  validation messages, the tooltips, the guarded existingVnet output, and one option per course
  even where several courses share an image.
  the server UI used to hide imageVersion until a programme was chosen while the client UI
  always showed it. The merged UI follows the client behaviour - visible as soon as the platform
  is chosen.

# Main Template

## [1.7.0.0] 6.11.2026
[main]
### Change
  the VM application is no longer identified by a whole resource id. idleHibernateAppVersionId
  is replaced by idleHibernateAppName, defaulting to IdleHibernation, and
  idleHibernateAppVersion, defaulting to latest. windowsVm.json composes the package id from
  the subscription id it already reads from the routeway Key Vault.
  Updated contentVersion to 1.7.0.0
  Updated contentVersion for windowsVm to 1.5.0.0
### Note
  this removes the only hardcoded subscription GUID in the folder, added in 1.6.0.0. These
  templates are served unauthenticated from a public repository, and every other subscription
  reference comes from the Key Vault. tools/Test-Templates.ps1 check 16 now fails on any
  literal subscription id in any file.
  the cost is a constraint: the application has to live in the same gallery and resource group
  as the course images, because the package id reuses acgRG and galleryImageName. Moving it
  elsewhere means composing from its own variables.

## [1.6.0.0] 6.11.2026
[main]
### Change
  renamed the idleVM parameter to idleHibernate, with allowed values Enabled and Disabled
  in place of Yes and No, defaulting to Disabled.
  renamed the idleVm output to idleHibernate.
  new parameter idleHibernateAppVersionId, the gallery application version installed when
  idleHibernate is Enabled. Not on the UI - it is not a coach decision.
  Updated contentVersion to 1.6.0.0
  Updated contentVersion for windowsVm to 1.4.0.0
### Note
  BREAKING for anything outside this repository. The IdleShutdown tag is now IdleHibernate,
  its values are Enabled/Disabled rather than Yes/No, and the idleVm output is now
  idleHibernate. Automation that filters on the old key, the old values or the old output
  name stops matching the moment this is published. TAGS.md records who reads what.
  idleHibernateAppVersionId defaults to the IdleHibernation application in the trainingacg
  gallery, at versions/latest. Setting it to an empty string installs nothing, and check 15
  warns if the default is ever emptied.
  two things about that default are worth knowing. The Microsoft documentation for
  packageReferenceId only ever specifies {version}; "latest" is documented for gallery
  IMAGE versions, not for application versions, so it is unverified here - the first
  deployment will say. And the subscription GUID is now written into a template published
  to a public repository, where every other subscription reference in this folder is read
  from the routeway Key Vault instead.

## [1.5.0.0] 6.11.2026
[main]
### Change
  every virtual machine now gets a system-assigned managed identity, and the VM Idle Self
  Hibernate custom role is assigned to that identity on the machine itself - so a machine
  can hibernate itself when idle and can do nothing else.
  new parameter idleHibernateRoleDefinitionId, the GUID of that custom role, passed through
  to windowsVm.json. It is deliberately not on the UI: it is not a coach decision.
  new output vmPrincipalId, the array of machine identity principal ids, for automation
  that needs to find them.
  Updated contentVersion to 1.5.0.0
  Updated contentVersion for windowsVm to 1.3.0.0
### Note
  the default is the role GUID a23c0eed-355e-417d-9759-144c48a84c68, resolved through
  subscriptionResourceId. Setting the parameter to an empty string skips the assignment,
  and check 14 warns if the default is ever emptied.
  the assignment needs Microsoft.Authorization/roleAssignments/write on the resource group,
  which means Owner or User Access Administrator. A coach without it cannot deploy at all
  unless the parameter is empty - that is what the empty escape hatch is for.
  the identity is created either way. Only the role assignment is conditional.

## [1.4.0.0] 6.11.2026
[main]
### Change
  the DNS collision fix now applies to the machine name, not just the public IP DNS label.
  A VM with no public IP still gets a DNS record, created from its host name, so two courses
  with the same VM name and coach initials collided there even after the public IP label was
  fixed. Every machine name now carries a 3 character suffix from
  uniqueString(resourceGroup().id) - see the four module entries below.
  vmName gained minLength 3 and maxLength 8, and deliveringCoachInitials minLength and
  maxLength 2. The 15 character Windows host name limit is only safe if both are bounded,
  and a template deployed from the CLI does not go through the UI regex.
  Updated contentVersion to 1.4.0.0
  Updated contentVersion for windowsVm to 1.2.0.0, networkInterface to 1.2.0.0, publicIP to
  1.1.0.0 and shutdownSchedule to 1.1.0.0
### Note
  the budget is exact: vmName 8 + initials 2 + suffix 3 + machine number 2 = 15. Raising any
  of the four means lowering another. tools/Test-Templates.ps1 check 13 does that arithmetic
  from the parameters themselves and fails if it comes to more than 15, and also fails if the
  UI regex allows a longer name than the template does.
  the vmNamePrefix output still returns the bare vmName, unchanged, because other automation
  reads it. It does not reflect the suffix.
  existing machines are untouched. Redeploying an existing course with the same parameters
  will now produce differently named machines, because the name itself has changed - it is a
  new VM, not an update to the old one.

## [1.3.0.0] 6.11.2026
[main]
### Change
  rdpPublish now controls whether a public IP address is deployed. Yes means the RDP
  publishing automation reaches these machines, so they are built with no public IP of
  their own; No keeps the previous behaviour, one public IP and DNS label per machine.
  new deployPublicIp variable, equals(rdpPublish, 'No'), read in all three places that
  need it so they cannot drift apart.
  DeployPublicIPAddress is now conditional on it.
  DeployNetworkInterface is passed publicIpEnabled, so the NIC leaves the public IP off
  its ip configuration rather than pointing at one that was never created.
  the virtualMachineFQDN output is now conditional on it - there is no FQDN to return, and
  referencing the outputs of a deployment that was skipped fails the deployment.
  rdpPublish description rewritten to say what each value now does.
  Updated contentVersion to 1.3.0.0
  Updated contentVersion for networkInterface module to 1.1.0.0
### Note
  DeployNetworkInterface still dependsOn DeployPublicIPAddress. A dependency on a skipped
  conditional deployment is satisfied rather than failing, so this is left as it is.
  tools/Test-Templates.ps1 gained a check that the three halves of the gate agree - a
  conditional public IP deployment, the publicIpEnabled pass, and the FQDN output
  condition, all reading the same expression. Removing one of the three is the way this
  breaks, and two of those three only fail at deployment time.
  outbound internet is unaffected on a machine with no public IP. The vnet and subnet are
  pre-created with the resource group and the subnet's route table sends internet traffic to
  the firewall, which is an explicit outbound method - so default outbound access, and its
  retirement, never applied to these machines. What the firewall must allow is
  raw.githubusercontent.com, for the DSC archive and the NVIDIA driver script. See README.md.

## [1.2.0.0] 4.11.2026
[main]
### Fix
  _moduleRepo still read /deployment/vmdeployment/modules - inherited from serverMain when this
  folder was created, and missed because the path rewrite only covered files under modules/.
  Every module would have been fetched from the other folder and 404'd, since windowsVm.json
  and shutdownSchedule.json do not exist there. Now /deployment/vmdeployment-single/modules.
  tools/Test-Templates.ps1 gained a check for this: any _moduleRepo path must name the folder
  the templates are actually in. The templateLink version check could not catch it, because it
  finds the module by filename locally and never looks at the rest of the URL.
### Change
  the four network deployments - DeployNetworkSecurityGroup, DeployVirtualNetwork,
  DeployPublicIPAddress and DeployNetworkInterface - are now declared here directly instead of
  going through the network module. Names, conditions, dependsOn and parameter values are
  unchanged; every parameter the wrapper took was a straight pass-through of a same-named
  parameter, so the blocks moved verbatim.
  DeployVm now depends on DeployNetworkInterface rather than DeployNetwork.
  virtualMachineFQDN reads reference('DeployPublicIPAddress').outputs.FQDN.value directly,
  one hop shorter.
  Updated contentVersion to 1.2.0.0
### Note
  the wrapper existed to stop the four blocks being written twice, once in serverMain and once
  in desktopMain. With one main template there was no duplication left for it to prevent, so it
  was pure indirection. It would earn its place again if a second main template ever returns.
  a side effect worth having: check 2 only follows templateLinks from the main template, so the
  four leaf module versions were never being checked while they sat behind the wrapper. They
  are now.

## [1.1.0.0] 4.11.2026
[main]
### Add
  new hibernationEnabled parameter, type bool, default false, passed to the windowsVm module.
  Hibernation is now a per-deployment choice for both platforms rather than being hard-coded
  per platform.
  Updated contentVersion to 1.1.0.0
  Updated contentVersion for windowsVm module to 1.1.0.0
### Change
  the rdpPublish description no longer says it is server-only

## [1.0.0.0] 4.11.2026
[main]
### Add
  single main template serving both platforms, merged from serverMain 4.4.0.0 and
  desktopMain 4.5.0.0.
  new vmPlatform parameter, passed to the windowsVm module.
  one rwkeyVault map, one courseImageValue map covering all nine programmes, one set of
  outputs, one copy of the four network deployments and the shutdown schedule.
  merged allowedValues where the two templates differed: vmSize now lists all 14 sizes,
  apprenticeshipProgramme all nine programmes, bootcampCourse all three bootcamp images.
  patchMode keeps both dimensions - ImageDefault for a non-Windows osPlatform, otherwise
  Manual for server and AutomaticByOS for client.
  new vmPlatform output so the deployment's Outputs blade records which platform was built.
### Note
  three deployments: DeployNetwork, DeployVm, DeployShutdownSchedule.
  the postgresPassword Key Vault reference is now on the single VM deployment, so it is read
  for both platforms. See DESIGN.md for why that is preferred over two conditional deployments.

# Modules

## [1.5.0.0] 6.11.2026
[windowsVm]
### Change
  replaced the idleHibernateAppVersionId parameter with idleHibernateAppName and
  idleHibernateAppVersion, and added the idleHibernateAppPackageId variable, which composes
  the package id from parameters('subscriptionId'), variables('acgRG') and
  variables('galleryImageName') - the same three pieces imageReference is built from.
  the install gate now tests idleHibernateAppName rather than the old resource id.
  Updated contentVersion to 1.5.0.0
### Note
  reusing acgRG and galleryImageName is the point: the application and the images come from
  the same gallery, so they stay in step through one variable rather than two. It does mean
  the application cannot live anywhere else without new variables.

## [1.4.0.0] 6.11.2026
[windowsVm]
### Change
  the IdleShutdown tag is now IdleHibernate, and its value comes from the renamed
  idleHibernate parameter - Enabled or Disabled rather than Yes or No.
  new parameter idleHibernateAppVersionId and a new applicationProfile on the virtual
  machine, which installs that gallery application when idleHibernate is Enabled and the
  id is not empty. Built with if(...) and json('null'), the same idiom securityProfile
  and licenseType already use, so the property is absent rather than empty when off.
  Updated contentVersion to 1.4.0.0
### Note
  treatFailureAsDeploymentFailure is false, so a bad application package degrades the
  course rather than failing the whole deployment. The trade is that a failed install is
  silent - it shows on the VM extension status, not in the deployment result.
  order is 1 because there is only one application. It is set explicitly so adding a
  second one later is an addition rather than a rewrite.

## [1.3.0.0] 6.11.2026
[windowsVm]
### Change
  the virtual machine now declares identity type SystemAssigned.
  new resource, a copy-looped Microsoft.Authorization/roleAssignments scoped to each
  machine, granting the VM Idle Self Hibernate role to that machine's own identity. The
  assignment name is guid(vm resource id, role definition id), so a redeployment of the
  same machine reuses the same assignment rather than creating a second one.
  new parameter idleHibernateRoleDefinitionId. Empty skips the assignment.
  new output vmPrincipalId.
  Updated contentVersion to 1.3.0.0
### Note
  the scope is the single machine, not the resource group, so one machine's identity
  cannot hibernate another. principalType is ServicePrincipal, which is what a
  system-assigned identity is, and setting it avoids the replication delay error that
  comes of Azure not yet seeing a brand new principal.

## [1.2.0.0] 6.11.2026
[windowsVm]
### Change
  vmNamePrefix is now vmName + coach initials + a 3 character nameSuffix taken from
  uniqueString(resourceGroup().id). This changes the VM name, the OS disk name, the NIC
  it looks up, every extension name and osProfile.computerName - which is the one that
  matters, because that is the name DNS registers.
  Updated contentVersion to 1.2.0.0
### Note
  the suffix is derived from the resource group id, so every module computes the same
  value and the VM still finds its own NIC. Check 13 fails if the four modules that build
  this prefix ever disagree.

## [1.1.0.0] 4.11.2026
[windowsVm]
### Add
  new hibernationEnabled parameter, and a hibernationBySize map covering every size the template
  allows. additionalCapabilities.hibernationEnabled now reads
  if(hibernationEnabled, hibernationBySize[vmSize].supported, false()) - so hibernation is only
  ever requested on a size that supports it. A size missing from the map fails the deployment
  loudly, which is deliberate: adding a VM size means deciding its hibernation support.
  Supported per Microsoft's hibernation overview: Dsv5, Dasv5 and NVv4. Not supported: all
  B-series, all v3 sizes, NV12s_v3 and NC4as_T4_v3.
### Change
  hibernation is no longer derived from the platform, and no longer tied to the Trusted Launch
  condition. It was previously false for server and true for client, but only applied when
  securityType was TrustedLaunch - which is unreachable, so it had never taken effect on any
  machine.
  the RdpPublish and Hiberbation tags now go on both platforms. The Hiberbation tag carries the
  real value, string(hibernationEnabled), instead of the literal False.
  VM tags are a single vmTags object again - the union() and serverOnlyVmTags that existed to
  keep those two tags off client builds are gone.
  Updated contentVersion to 1.1.0.0
### Note
  the Hiberbation tag key is still misspelled. Renaming it is still the open question in
  TAGS.md, because other automation may filter on it.
  the DSC ResourceType tag is still server-only, and still uses union() for that reason.

## [1.0.0.0] 4.11.2026
[windowsVm]
### Add
  single VM module serving both platforms, merged from windowsServer 4.1.0.0 and
  windowsDesktop 4.2.0.0. The seventeen differences between them are now if() expressions on
  vmPlatform: image map, DSC archive, script and function prefix, licence type, hibernation,
  automatic updates, and the platform-specific tags.
  the two operatingSystemValues maps are merged into one. Their keys do not overlap, so the
  lookup is unambiguous - 20 course keys in all.
  VM and DSC tags are assembled with union(), so RdpPublish, Hiberbation and the DSC
  ResourceType tag appear on server builds only, exactly as before.
  the Nvidia and AMD GPU driver extensions keep a platform clause as well as their vmSize
  condition, so they still only run for client builds. Dropping the clause would close the
  server GPU gap - see DESIGN.md.
### Note
  postgresPassword is declared and unused, as in windowsDesktop. It is read by other
  automation.

## [1.1.0.0] 4.11.2026
[network]
### Remove
  deleted. Its four deployments moved into main.json - see main 1.2.0.0. The module only ever
  grouped four templateLinks; it declared no Azure resources of its own.

## [1.0.0.0] 4.11.2026
[network]
### Add
  copied unchanged from vmdeployment/modules/network.json 4.0.1.0, with the module repository
  path pointed at deployment/vmdeployment-single/modules.

## [1.2.0.0] 6.11.2026
[networkInterface]
### Change
  vmNamePrefix now carries the 3 character nameSuffix, so the NIC and the public IP it
  attaches are named in step with the VM. See main 1.4.0.0.
  Updated contentVersion to 1.2.0.0

## [1.1.0.0] 6.11.2026
[networkInterface]
### Add
  new publicIpEnabled parameter, type bool, default true. False leaves the network
  interface with a private address only, for when RDP is published through the external
  automation and no public IP is deployed. See main 1.3.0.0.
### Change
  the ip configuration is now assembled with union() - a constant ipConfigCommon half, and
  a per-machine publicIPAddress half built by a variable copy loop and included only when
  publicIpEnabled is true. This is the same union() idiom the VM module uses for its
  conditional tags, and it avoids relying on a null property being dropped.
  pipDeleteOption description notes that it is ignored when publicIpEnabled is false.
  Updated contentVersion to 1.1.0.0

## [1.0.0.0] 4.11.2026
[networkInterface]
### Add
  copied unchanged from vmdeployment/modules/networkInterface.json 4.1.0.0.

## [1.0.0.0] 4.11.2026
[networkSecurityGroup]
### Add
  copied unchanged from vmdeployment/modules/networkSecurityGroup.json 4.1.0.0.
### Note
  RDP remains open to the internet by design.

## [1.1.0.0] 6.11.2026
[publicIP]
### Change
  vmNamePrefix now carries the 3 character nameSuffix, so the public IP is named in step
  with the VM. See main 1.4.0.0.
  the separate 4 character dnsSuffix variable is gone, and domainNameLabel no longer
  appends it. The prefix now carries a suffix from the same uniqueString, so the label
  had two of them. The DNS label is still unique per resource group; the uniqueness is
  3 characters rather than 4, from one source instead of two.
  the parameter reference spelled deliveringCoachinitials, which ARM resolved anyway,
  now matches the declared name.
  Updated contentVersion to 1.1.0.0

## [1.0.0.0] 4.11.2026
[publicIP]
### Add
  copied unchanged from vmdeployment/modules/publicIP.json 4.1.0.0, including the 4 character
  uniqueString DNS suffix.

## [1.0.0.0] 4.11.2026
[virtualNetwork]
### Add
  copied unchanged from vmdeployment/modules/virtualNetwork.json 4.1.0.0.

## [1.1.0.0] 6.11.2026
[shutdownSchedule]
### Change
  vmNamePrefix now carries the 3 character nameSuffix, so the schedule name and its
  targetResourceId still point at the VM. See main 1.4.0.0.
  Updated contentVersion to 1.1.0.0

## [1.0.0.0] 4.11.2026
[shutdownSchedule]
### Add
  copied unchanged from vmdeployment/modules/shutdownSchedule.json 4.0.1.0.
