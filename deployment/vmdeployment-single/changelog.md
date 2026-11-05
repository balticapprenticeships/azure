# Change Log
All notable changes to this project will be documented in this file.
 
The format is based on [Keep a Changelog](http://keepachangelog.com/)
and this project adheres to [Semantic Versioning](http://semver.org/).

This folder is the single-template implementation. It starts at 1.0.0.0 rather than continuing
the 4.x line of `vmdeployment`, because every file here is new even where the content is carried
over. See `DESIGN.md` for what was merged and why.

# User Interface

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

## [1.0.0.0] 4.11.2026
[publicIP]
### Add
  copied unchanged from vmdeployment/modules/publicIP.json 4.1.0.0, including the 4 character
  uniqueString DNS suffix.

## [1.0.0.0] 4.11.2026
[virtualNetwork]
### Add
  copied unchanged from vmdeployment/modules/virtualNetwork.json 4.1.0.0.

## [1.0.0.0] 4.11.2026
[shutdownSchedule]
### Add
  copied unchanged from vmdeployment/modules/shutdownSchedule.json 4.0.1.0.
