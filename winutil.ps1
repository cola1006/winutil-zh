<#
.NOTES
    Author         : Chris Titus @christitustech
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/ChrisTitusTech
    Version        : 26.07.11
#>

param (
    [string]$Config,
    [ValidateSet("Standard", "Minimal", "Advanced", "")]
    [string]$Preset,
    [switch]$Offline
)

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinUtil is unable to run on your system. PowerShell execution is restricted by security policies." -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinUtil needs to be run as Administrator. Attempting to relaunch."
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.version = "26.07.11"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$winutildir = "$env:LocalAppData\winutil"
$sync.winutildir = $winutildir

$logdir = "$winutildir\logs"
$sync.logPath = "$logdir\winutil_$dateTime.log"
$sync.transcriptPath = $sync.logPath
Start-Transcript -Path $sync.logPath -Append -NoClobber | Out-Null

$Host.UI.RawUI.WindowTitle = "WinUtil"
Clear-Host
function Add-SelectedAppsMenuItem {
    <#
    .SYNOPSIS
        This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

    .Parameter name
        The actual Name of an App like "Chrome" or "Brave"
        This name is contained in the "Content" property inside the applications.json
    .PARAMETER key
        The key which identifies an app object in applications.json
        For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
    #>

    param ([string]$name, [string]$key)

    $selectedAppGrid = New-Object Windows.Controls.Grid

    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

    # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
    # With the tooltip, you can still read the whole entry on hover
    $selectedAppLabel = New-Object Windows.Controls.Label
    $selectedAppLabel.Content = $name
    $selectedAppLabel.ToolTip = $name
    $selectedAppLabel.HorizontalAlignment = "Left"
    $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
    $selectedAppGrid.Children.Add($selectedAppLabel)

    $selectedAppRemoveButton = New-Object Windows.Controls.Button
    $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
    $selectedAppRemoveButton.Content = [string]([char]0xE711)
    $selectedAppRemoveButton.HorizontalAlignment = "Center"
    $selectedAppRemoveButton.Tag = $key
    $selectedAppRemoveButton.ToolTip = "從選擇中移除此軟體"
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

    # Highlight the Remove icon on Hover
    $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
    $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
    $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
    })
    [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
    $selectedAppGrid.Children.Add($selectedAppRemoveButton)
    # Add new Element to Popup
    $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
}

function Close-WinUtilRunspacePool {
    if ($null -eq $sync -or -not $sync.ContainsKey("runspace") -or $null -eq $sync.runspace) {
        return
    }

    try {
        if ($sync.runspace.RunspacePoolStateInfo.State -notin @(
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closing,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Broken
        )) {
            $sync.runspace.Close()
        }
    } finally {
        $sync.runspace.Dispose()
        $sync.Remove("runspace")
    }
}

function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .DESCRIPTION
            Filters application entries by name or description using literal string matching.
            Respects collapsed category state and handles null $sync gracefully.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (no parameter needed; inherits from caller's scope)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing hashtable keys and null UI elements
            - Protected by try/catch to prevent UI thread crashes
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # Validate that $sync exists and has required structure
    if ($null -eq $sync) {
        Write-Warning "Find-AppsByNameOrDescription: Global `$sync not found. Aborting search."
        return
    }

    if ($null -eq $sync.ItemsControl) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.ItemsControl not initialized. Aborting search."
        return
    }

    if ($null -eq $sync.configs -or $null -eq $sync.configs.applicationsHashtable) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.configs.applicationsHashtable not initialized. Aborting search."
        return
    }

    try {
        # Reset the visibility if the search string is empty or the search is cleared
        if ([string]::IsNullOrWhiteSpace($SearchString)) {
            $sync.ItemsControl.Items | ForEach-Object {
                # Each item is a StackPanel container
                $_.Visibility = [Windows.Visibility]::Visible

                if ($_.Children.Count -ge 2) {
                    $categoryLabel = $_.Children[0]
                    $wrapPanel = $_.Children[1]

                    # Keep category label visible
                    $categoryLabel.Visibility = [Windows.Visibility]::Visible

                    # Respect the collapsed state of categories (indicated by + prefix)
                    if ($categoryLabel.Content -like "+*") {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                    }
                    else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    }

                    # Show all apps within the category
                    $wrapPanel.Children | ForEach-Object {
                        $_.Visibility = [Windows.Visibility]::Visible
                    }
                }
            }
            return
        }

        # Escape wildcard characters for literal matching
        $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

        # Perform search
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]
                $categoryHasMatch = $false

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # Search through apps in this category
                foreach ($appControl in $wrapPanel.Children) {
                    # Safely retrieve app entry from hashtable
                    $appTag = $appControl.Tag
                    $appEntry = $null

                    if (-not [string]::IsNullOrWhiteSpace($appTag) -and $sync.configs.applicationsHashtable.ContainsKey($appTag)) {
                        $appEntry = $sync.configs.applicationsHashtable[$appTag]
                    }

                    # Check if app matches search criteria
                    if ($null -ne $appEntry) {
                        $contentMatch = $appEntry.Content -like "*$escapedSearchString*"
                        $descriptionMatch = $appEntry.Description -like "*$escapedSearchString*"

                        if ($contentMatch -or $descriptionMatch) {
                            # Show the App and mark that this category has a match
                            $appControl.Visibility = [Windows.Visibility]::Visible
                            $categoryHasMatch = $true
                        }
                        else {
                            $appControl.Visibility = [Windows.Visibility]::Collapsed
                        }
                    }
                    else {
                        # Hide app if no entry found (data integrity issue)
                        $appControl.Visibility = [Windows.Visibility]::Collapsed
                    }
                }

                # If category has matches, show the WrapPanel and update the category label to expanded state
                if ($categoryHasMatch) {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    $_.Visibility = [Windows.Visibility]::Visible
                    # Update category label to show expanded state (-)
                    if ($categoryLabel.Content -like "+*") {
                        $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                    }
                }
                else {
                    # Hide the entire category container if no matches
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        Write-Warning "Find-AppsByNameOrDescription: An error occurred during search: $_"
        # Fail gracefully - do not crash the UI thread
        return
    }
}

function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .DESCRIPTION
            Filters tweak entries by name or description using literal string matching (no wildcard expansion).
            Respects collapsed category state and handles null $sync gracefully.
            Safe for rapid keystroke events; no terminal spam on error conditions.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (resolved via global/script fallback if needed)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing UI elements and null properties
            - Protected by try/catch to prevent UI thread crashes
            - PowerShell 5.1 compatible (no ternary operators, no advanced language features)
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # ------------------------------------------------------------------------------
    # 1. RESOLVE $SYNC WITH MULTI-LEVEL FALLBACK
    # ------------------------------------------------------------------------------

    if ($null -eq $Sync) {
        $Sync = $global:sync
        if ($null -eq $Sync) {
            $Sync = $script:sync
        }
    }

    # Validate that $Sync exists and has required structure
    if ($null -eq $Sync) {
        # Silent return - function called on every keystroke; no warning spam
        return
    }

    if ($null -eq $Sync.Form) {
        # Silent return - form not yet initialized
        return
    }

    # ------------------------------------------------------------------------------
    # 2. GET REFERENCE TO TWEAKS OR APPX PANEL
    # ------------------------------------------------------------------------------

    $panelName = "tweakspanel"
    if ($null -ne $Sync.currentTab -and $Sync.currentTab -eq "AppX") {
        $panelName = "appxpanel"
    }

    $tweaksPanel = $null
    try {
        $tweaksPanel = $Sync.Form.FindName($panelName)
    }
    catch {
        # Silent return - panel not found or disposed
        return
    }

    if ($null -eq $tweaksPanel) {
        # Silent return - panel doesn't exist
        return
    }

    # ------------------------------------------------------------------------------
    # 3. HANDLE EMPTY/WHITESPACE SEARCH STRING - RESET TO DEFAULT STATE
    # ------------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        try {
            $tweaksPanel.Children | ForEach-Object {
                $categoryBorder = $_

                # Safely set visibility
                if ($null -ne $categoryBorder) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }

                # Process each category
                if ($categoryBorder -is [Windows.Controls.Border]) {
                    $dockPanel = $null
                    if ($null -ne $categoryBorder.Child) {
                        $dockPanel = $categoryBorder.Child
                    }

                    if ($dockPanel -is [Windows.Controls.DockPanel]) {
                        $itemsControl = $null
                        $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                        if ($null -ne $itemsControl) {
                            # Show all items in the category
                            foreach ($item in $itemsControl.Items) {
                                if ($null -ne $item) {
                                    # Check if it's a category label (first Label in the ItemsControl)
                                    if ($item -is [Windows.Controls.Label]) {
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                    elseif ($item -is [Windows.Controls.DockPanel] -or $item -is [Windows.Controls.StackPanel]) {
                                        # Show all checkbox containers
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Silent catch - UI element may be disposed
            $null = $_
        }

        return
    }

    # ------------------------------------------------------------------------------
    # 4. PERFORM LITERAL SEARCH (NO WILDCARD EXPANSION)
    # ------------------------------------------------------------------------------

    try {
        # Normalize search term once for the entire operation
        $searchTerm = $SearchString
        if ($null -eq $searchTerm) {
            $searchTerm = ""
        }

        # Iterate through all categories
        $tweaksPanel.Children | ForEach-Object {
            $categoryBorder = $_
            $categoryHasMatch = $false

            if ($categoryBorder -is [Windows.Controls.Border]) {
                $dockPanel = $null
                if ($null -ne $categoryBorder.Child) {
                    $dockPanel = $categoryBorder.Child
                }

                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $null
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                    if ($null -ne $itemsControl) {
                        $categoryLabel = $null

                        # Process all items (checkboxes, labels, panels) in the ItemsControl
                        for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                            $item = $itemsControl.Items[$i]

                            if ($null -eq $item) {
                                continue
                            }

                            # ------------------------------------------------------------
                            # Check if this is a category label (usually first Label)
                            # ------------------------------------------------------------

                            if ($item -is [Windows.Controls.Label]) {
                                $categoryLabel = $item
                                # Initially hide category label; show it only if matches found
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # ------------------------------------------------------------
                            # Check if this is a DockPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.DockPanel]) {
                                $checkbox = $null
                                $label = $null

                                # Safely extract checkbox and label
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                                $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                                # Check if tweak matches search criteria
                                $itemMatches = $false

                                if ($null -ne $label) {
                                    $labelContent = $label.Content
                                    $labelToolTip = $label.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $labelContent) {
                                        $labelContent = ""
                                    }
                                    if ($null -eq $labelToolTip) {
                                        $labelToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $labelContentStr = [string]$labelContent
                                    $labelToolTipStr = [string]$labelToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $labelContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $labelToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }

                            # ------------------------------------------------------------
                            # Check if this is a StackPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.StackPanel]) {
                                $checkbox = $null
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                                $itemMatches = $false

                                if ($null -ne $checkbox) {
                                    $checkboxContent = $checkbox.Content
                                    $checkboxToolTip = $checkbox.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $checkboxContent) {
                                        $checkboxContent = ""
                                    }
                                    if ($null -eq $checkboxToolTip) {
                                        $checkboxToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $checkboxContentStr = [string]$checkboxContent
                                    $checkboxToolTipStr = [string]$checkboxToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $checkboxContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $checkboxToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }
                        }

                        # ------------------------------------------------------------
                        # Update category label visibility and expanded/collapsed state
                        # ------------------------------------------------------------

                        if ($categoryHasMatch) {
                            # Show category label
                            if ($null -ne $categoryLabel) {
                                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                                # Update category label to expanded state (change "+" to "-")
                                $labelContent = $categoryLabel.Content
                                if ($null -ne $labelContent) {
                                    $labelStr = [string]$labelContent

                                    # Safe string replacement without -replace regex
                                    if ($labelStr.StartsWith("+ ")) {
                                        $expandedLabel = "- " + $labelStr.Substring(2)
                                        $categoryLabel.Content = $expandedLabel
                                    }
                                }
                            }
                        }
                    }
                }

                # ----------------------------------------------------------------
                # Set category border visibility based on whether it has matches
                # ----------------------------------------------------------------

                if ($categoryHasMatch) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $categoryBorder.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        # Silent catch - UI elements may be disposed or in unexpected state
        # Do not log to terminal as this function is called on every keystroke
        $null = $_
    }
}

function Get-WinUtilPackageLogSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    @($Packages | ForEach-Object {
        $package = $_
        $packageName = @($package.Name, $package.Description, $package.winget, $package.choco) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -ne "na" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            $packageName = "Unknown package"
        }

        if ($Preference -eq "Choco" -and -not [string]::IsNullOrWhiteSpace([string]$package.choco) -and $package.choco -ne "na") {
            "$packageName (choco: $($package.choco))"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.winget) -and $package.winget -ne "na") {
            "$packageName (winget: $($package.winget))"
        } else {
            "$packageName (no package id)"
        }
    })
}

function Get-WinUtilSelectedPackages {

     param(
         [Parameter(Mandatory = $true)]
         [object] $PackageList,

         [Parameter(Mandatory = $true)]
         [string] $Preference
     )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId
        )

        if ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na") {
            return
        }

        if (-not $Target.Contains($PackageId)) {
            $null = $Target.Add($PackageId)
        }
    }

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Winget" {
                Add-PackageId -Target $packagesWinget -PackageId $package.winget
            }
        }
    }

    return $packages
}

Function Get-WinUtilToggleStatus ($ToggleSwitch) {

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    if ($null -eq $sync.ToggleStatusCache) {
        $sync.ToggleStatusCache = @{}
    }

    if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
        return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            $sync.ToggleStatusCache[$ToggleSwitch] = $false
            return $false
        }
    }

    $sync.ToggleStatusCache[$ToggleSwitch] = $true
    return $true
}

function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            }
            catch {
                $null = $_
            }
        }
        return $output
    }
    return $keys
}

function Hide-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Hides the busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall has finished.
    #>
    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Collapsed
        $sync.InstallAppAreaBorder.IsEnabled = $true
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 0
    }
}

    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

                Also creates an overlay with a progress bar and text to indicate that an install or uninstall is in progress

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        $sync.InstallAppAreaBorder = $Border

        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $sync.InstallAppAreaScrollViewer = $scrollViewer
        $Border.Child = $scrollViewer

        # Initialize the Blur Effect for the ScrollViewer, which will be used to indicate that an install/uninstall is in progress
        $blurEffect = New-Object Windows.Media.Effects.BlurEffect
        $blurEffect.Radius = 0
        $scrollViewer.Effect = $blurEffect

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        $overlay = New-Object Windows.Controls.Border
        $overlay.CornerRadius = New-Object Windows.CornerRadius(10)
        $overlay.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallOverlayBackgroundColor")
        $overlay.Visibility = [Windows.Visibility]::Collapsed

        # Also add the overlay to the target Grid on top of the App Area
        $targetGrid.Children.Add($overlay) | Out-Null
        $sync.InstallAppAreaOverlay = $overlay

        $overlayText = New-Object Windows.Controls.TextBlock
        $overlayText.Text = "Installing apps..."
        $overlayText.HorizontalAlignment = 'Center'
        $overlayText.VerticalAlignment = 'Center'
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "MainForegroundColor")
        $overlayText.Background = "Transparent"
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "HeaderFontSize")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontFamilyProperty, "MainFontFamily")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::FontWeightProperty, "MainFontWeight")
        $overlayText.SetResourceReference([Windows.Controls.TextBlock]::MarginProperty, "MainMargin")
        $sync.InstallAppAreaOverlayText = $overlayText

        $progressbar = New-Object Windows.Controls.ProgressBar
        $progressbar.Name = "ProgressBar"
        $progressbar.Width = 250
        $progressbar.Height = 50
        $sync.ProgressBar = $progressbar

        # Add a TextBlock overlay for the progress bar text
        $progressBarTextBlock = New-Object Windows.Controls.TextBlock
        $progressBarTextBlock.Name = "progressBarTextBlock"
        $progressBarTextBlock.FontWeight = [Windows.FontWeights]::Bold
        $progressBarTextBlock.FontSize = 16
        $progressBarTextBlock.Width = $progressbar.Width
        $progressBarTextBlock.Height = $progressbar.Height
        $progressBarTextBlock.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ProgressBarTextColor")
        $progressBarTextBlock.TextTrimming = "CharacterEllipsis"
        $progressBarTextBlock.Background = "Transparent"
        $sync.progressBarTextBlock = $progressBarTextBlock

        # Create a Grid to overlay the text on the progress bar
        $progressGrid = New-Object Windows.Controls.Grid
        $progressGrid.Width = $progressbar.Width
        $progressGrid.Height = $progressbar.Height
        $progressGrid.Margin = "0,10,0,10"
        $progressGrid.Children.Add($progressbar) | Out-Null
        $progressGrid.Children.Add($progressBarTextBlock) | Out-Null

        $overlayStackPanel = New-Object Windows.Controls.StackPanel
        $overlayStackPanel.Orientation = "Vertical"
        $overlayStackPanel.HorizontalAlignment = 'Center'
        $overlayStackPanel.VerticalAlignment = 'Center'
        $overlayStackPanel.Children.Add($overlayText) | Out-Null
        $overlayStackPanel.Children.Add($progressGrid) | Out-Null

        $overlay.Child = $overlayStackPanel

        return $itemsControl
    }

function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        $app = $sync.configs.applicationsHashtable.$appKey

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $app.description
        $border.Add_MouseLeftButtonUp({
            $childCheckbox = ($this.Child | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $app.content

        # Add FOSS label after the name if FOSS
        if ($app.foss -eq $true) {
            $fossRun = [System.Windows.Documents.Run]::new(" $([char]0x25CF)")
            $fossRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(110, 255, 114))
            $fossRun.FontSize = 11.5

            [void]$appName.Inlines.Add($fossRun)
        }
        $checkBox.Content = $appName

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        $border.Child = $checkBox
        if ($sync.selectedApps -contains $appKey) {
            $checkBox.IsChecked = $true
        }
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }

function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category before creating WPF controls.
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        $sync.InstallAppRenderQueue = [System.Collections.Queue]::new()

        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($categoryToggle)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $categoryToggle.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $categoryToggle.Content = $categoryToggle.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $categoryToggle.Content = $categoryToggle.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            $sync.InstallAppRenderQueue.Enqueue([pscustomobject]@{
                Category = $category
                TargetElement = $wrapPanel
                AppKeys = @($appsByCategory[$category] | Sort-Object)
            })
        }

        Start-WinUtilInstallAppRendering
    }

function Initialize-WinUtilRunspacePool {
    if ($sync.runspace -and $sync.runspace.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.runspace
    }

    if ($sync.runspace) {
        Close-WinUtilRunspacePool
    }

    # Set the maximum number of threads for the RunspacePool to the number of threads on the machine.
    $maxthreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 1)

    # Create a new session state for parsing variables into our runspace.
    $hashVars = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $offlineVar = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE', $PARAM_OFFLINE, $null
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $initialSessionState.Variables.Add($hashVars)
    $initialSessionState.Variables.Add($offlineVar)

    # Get every WinUtil/WPF function and add it to the session state.
    $functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
    foreach ($function in $functions) {
        $functionDefinition = Get-Content function:\$($function.Name)
        $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $functionDefinition
        $initialSessionState.Commands.Add($functionEntry)
    }

    $sync.runspace = [runspacefactory]::CreateRunspacePool(
        1,                      # Minimum thread count
        $maxthreads,            # Maximum thread count
        $initialSessionState,   # Initial session state
        $Host                   # Machine to create runspaces on
    )

    $sync.runspace.Open()
    return $sync.runspace
}

function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TabName
    )

    if ($null -eq $sync.InitializedTabs) {
        $sync.InitializedTabs = @{}
    }

    if ($sync.InitializedTabs[$TabName]) {
        return
    }

    switch ($TabName) {
        "Install" {
            Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
            Initialize-WPFUI -targetGridName "appscategory"

            Initialize-WPFUI -targetGridName "appspanel"
        }
        "Tweaks" {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
        }
        "Config" {
            Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2
        }
        "AppX" {
            Invoke-WPFUIElements -configVariable $sync.configs.appx -targetGridName "appxpanel" -columncount 2
        }
        "Win11 Creator" {
            if ($sync.Form -and $sync.Form.Dispatcher) {
                $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
            }
        }
    }

    $sync.InitializedTabs[$TabName] = $true
}

function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    if ($IncludeLogo -and -not $sync["logorender"]) {
        $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
        $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
        $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
    }
}

function Install-WinUtilChoco {
    if (-not (Get-Command -Name choco)) {
      Write-Host "Chocolatey is not installed. Installing now..."
      $installScript = Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing
      Invoke-Command -ScriptBlock ([scriptblock]::Create($installScript.Content))
    }
}

function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s) completed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
}

Function Install-WinUtilProgramWinget {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
        if ($program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        if ($Action -eq 'Install') {
            $arguments = @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
        } else {
            $arguments = @("uninstall", "--id", $program, "--source", $source, "--silent")
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"
        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program (exit code: $($process.ExitCode))"
    }
}

function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet is not installed. Installing now..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}

function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  if ($render -and $null -ne $sync) {
      if ($null -eq $sync.RenderedAssetCache) {
          $sync.RenderedAssetCache = @{}
      }

      $cacheKey = "$(([string]$type).ToLowerInvariant())|$Size"
      if ($sync.RenderedAssetCache.ContainsKey($cacheKey)) {
          return $sync.RenderedAssetCache[$cacheKey]
      }
  }

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "Invalid type: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()
      if ($bitmapImage.CanFreeze) {
          $bitmapImage.Freeze()
      }

      if ($null -ne $sync -and $sync.ContainsKey("RenderedAssetCache")) {
          $sync.RenderedAssetCache[$cacheKey] = $bitmapImage
      }

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}

Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).choco -split ";")
            if ($dependencies -in $apps) {
                Write-Output $psitem.name
            }
        }
    }

    if ($checkbox -eq "winget") {

        $originalEncoding = [Console]::OutputEncoding
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        $Sync.InstalledPrograms = @("winget", "msstore") | ForEach-Object {
            winget list -s $psitem | Select-Object -skip 3 | ConvertFrom-String -PropertyNames "Name", "Id", "Version", "Available" -Delimiter '\s{2,}'
        }
        [Console]::OutputEncoding = $originalEncoding

        $filter = Get-WinUtilVariables -Type Checkbox | Where-Object {$psitem -like "WPFInstall*"}
        $sync.GetEnumerator() | Where-Object {$psitem.Key -in $filter} | ForEach-Object {
            $dependencies = @($sync.configs.applications.$($psitem.Key).winget -split ";") | ForEach-Object {
                $psitem -replace "^msstore:", ""
            }

            if ($dependencies[-1] -in $sync.InstalledPrograms.Id) {
                Write-Output $psitem.name
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}

function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}

function Invoke-WinUtilFeatureInstall ($CheckBox) {
    Write-WinUtilLog -Component "Feature" -Message "Applying feature action: $CheckBox"

    if ($sync.configs.feature.$CheckBox.feature) {
        foreach ($feature in $sync.configs.feature.$CheckBox.feature) {
            Write-Host "Installing $feature"
            Write-WinUtilLog -Component "Feature" -Message "Enabling Windows optional feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Enabled Windows optional feature: $feature"
        }
    }

    if ($sync.configs.feature.$CheckBox.InvokeScript) {
        foreach ($script in $sync.configs.feature.$CheckBox.InvokeScript) {
            Write-Host "Running Script for $CheckBox"
            Write-WinUtilLog -Component "Feature" -Message "Running feature script for: $CheckBox"
            Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Completed feature script for: $CheckBox"
        }
    }
    Write-WinUtilLog -Component "Feature" -Message "Feature action completed: $CheckBox"
}

function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Store the scale factor so it can be reapplied after theme changes
    $sync.FontScaleFactor = $ScaleFactor

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }
}

function Invoke-WinUtilInstallPSProfile {
    if (-not (Get-Command wt)) {
        Write-Host "Windows Terminal not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.WindowsTerminal --source winget --silent
    }

    if (-not (Get-Command pwsh)) {
        Write-Host "PowerShell 7 not found. Installing..."
        Install-WinUtilWinget
        winget install Microsoft.PowerShell --source winget --installer-type wix --silent
    }

    wt new-tab pwsh -NoExit -Command "irm https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1 | iex"
}

function Write-Win11ISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$ts] $Message"
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "已就緒。請選擇一個 Windows 11 ISO 以開始。") {
            $sync["WPFWin11ISOStatusLog"].Text = $logLine
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n$logLine"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "選擇 Windows 11 ISO"
    $dlg.Filter           = "ISO 檔案 (*.iso)|*.iso|所有檔案 (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "檔案大小: $fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-Win11ISOLog "ISO selected: $isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "未選擇 ISO...") {
        [System.Windows.MessageBox]::Show("請先選擇一個 ISO 檔案。", "未選擇 ISO", "OK", "Warning")
        return
    }

    Write-Win11ISOLog "Mounting ISO: $isoPath"
    Set-WinUtilProgressBar -Label "Mounting ISO..." -Percent 10

    try {
        Mount-DiskImage -ImagePath $isoPath

        do {
            Start-Sleep -Milliseconds 500
        } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

        $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
        Write-Win11ISOLog "Mounted at drive $driveLetter"

        Set-WinUtilProgressBar -Label "Verifying ISO contents..." -Percent 30

        $wimPath = Join-Path $driveLetter "sources\install.wim"
        $esdPath = Join-Path $driveLetter "sources\install.esd"

        if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: install.wim/install.esd not found - not a valid Windows ISO."
            [System.Windows.MessageBox]::Show(
                "這似乎不是有效的 Windows ISO。`n`n找不到 install.wim / install.esd。",
                "無效的 ISO", "OK", "Error")
            Set-WinUtilProgressBar -Label "" -Percent 0
            return
        }

        $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

        Set-WinUtilProgressBar -Label "Reading image metadata..." -Percent 55
        $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

        if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: No 'Windows 11' edition found in the image."
            [System.Windows.MessageBox]::Show(
                "在此 ISO 中找不到任何 Windows 11 版本。`n`n僅支援官方的 Windows 11 ISO。",
                "並非 Windows 11 ISO", "OK", "Error")
            Set-WinUtilProgressBar -Label "" -Percent 0
            return
        }

        $sync["Win11ISOImageInfo"] = $imageInfo

        $sync["WPFWin11ISOMountDriveLetter"].Text = "掛載於: $driveLetter   |   映像檔: $(Split-Path $activeWim -Leaf)"
        $sync["WPFWin11ISOEditionComboBox"].Dispatcher.Invoke([action]{
            $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
            foreach ($img in $imageInfo) {
                [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
            }
            if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                $proIndex = -1
                for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                    if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                        $proIndex = $i; break
                    }
                }
                $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
            }
        })
        $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"

        $sync["Win11ISODriveLetter"] = $driveLetter
        $sync["Win11ISOWimPath"]     = $activeWim
        $sync["Win11ISOImagePath"]   = $isoPath
        $sync["WPFWin11ISOModifySection"].Visibility = "Visible"

        Set-WinUtilProgressBar -Label "ISO verified" -Percent 100
        Write-Win11ISOLog "ISO verified OK.  Editions found: $($imageInfo.Count)"
    } catch {
        Write-Win11ISOLog "ERROR during mount/verify: $_"
        [System.Windows.MessageBox]::Show(
            "掛載或驗證 ISO 時發生錯誤：`n`n$_",
            "錯誤", "OK", "Error")
    } finally {
        Start-Sleep -Milliseconds 800
        Set-WinUtilProgressBar -Label "" -Percent 0
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "找不到已驗證的 ISO。請先完成步驟 1 和步驟 2。",
            "尚未就緒", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "Unknown" }
    Write-Win11ISOLog "Selected edition: $selectedEditionName (Index $selectedWimIndex)"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true

    $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $workDir) {
        $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true

    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n"       + ${function:Write-Win11ISOLog}.ToString()       + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        function Get-WinUtilEditionIdFromName {
            param([string]$EditionName)

            $normalizedName = ($EditionName -replace '^Windows\s+11\s+', '').Trim()
            switch -Regex ($normalizedName) {
                '^Home Single Language$'      { return 'CoreSingleLanguage' }
                '^Home N$'                    { return 'CoreN' }
                '^Home$'                      { return 'Core' }
                '^Pro for Workstations N$'    { return 'ProfessionalWorkstationN' }
                '^Pro for Workstations$'      { return 'ProfessionalWorkstation' }
                '^Pro Education N$'           { return 'ProfessionalEducationN' }
                '^Pro Education$'             { return 'ProfessionalEducation' }
                '^Pro N$'                     { return 'ProfessionalN' }
                '^Pro$'                       { return 'Professional' }
                '^Education N$'               { return 'EducationN' }
                '^Education$'                 { return 'Education' }
                '^Enterprise LTSC N$'         { return 'EnterpriseSN' }
                '^Enterprise LTSC$'           { return 'EnterpriseS' }
                '^Enterprise N$'              { return 'EnterpriseN' }
                '^Enterprise$'                { return 'Enterprise' }
                default                       { return '' }
            }
        }

        function Get-WinUtilMountedImageEditionId {
            param(
                [Parameter(Mandatory)][string]$MountDir,
                [string]$EditionName,
                [scriptblock]$Logger
            )

            try {
                $dismOutput = & dism /English "/Image:$MountDir" /Get-CurrentEdition 2>&1
                foreach ($line in $dismOutput) {
                    if ($line -match '^\s*Current Edition\s*:\s*(.+?)\s*$') {
                        $editionId = $Matches[1].Trim()
                        if ($editionId) {
                            if ($Logger) { $null = $Logger.Invoke("Detected mounted image EditionID: $editionId") }
                            return $editionId
                        }
                    }
                }
            } catch {
                if ($Logger) { $null = $Logger.Invoke("Warning: could not detect mounted image EditionID with DISM: $_") }
            }

            $fallbackEditionId = Get-WinUtilEditionIdFromName -EditionName $EditionName
            if ($fallbackEditionId -and $Logger) {
                $null = $Logger.Invoke("Using fallback EditionID '$fallbackEditionId' from selected edition name.")
            }
            return $fallbackEditionId
        }

        function Get-DismImageInfoMap {
            param(
                [Parameter(Mandatory)][string]$ImagePath,
                [int]$Index = 1
            )

            $map = @{}
            $lines = & dism /English "/Get-ImageInfo" "/ImageFile:$ImagePath" "/Index:$Index"
            foreach ($line in $lines) {
                if ($line -match '^\s*([^:]+?)\s*:\s*(.*)$') {
                    $key = $Matches[1].Trim()
                    $val = $Matches[2].Trim()
                    if (-not $map.ContainsKey($key)) {
                        $map[$key] = $val
                    }
                }
            }
            return $map
        }

        function Invoke-WinUtilWimMetadataHydration {
            param(
                [Parameter(Mandatory)][string]$ImagePath,
                [Parameter(Mandatory)][string]$EditionName,
                [scriptblock]$Logger
            )

            $metadataLogger = $Logger

            function LogMeta([string]$Message) {
                if ($metadataLogger) {
                    $null = $metadataLogger.Invoke($Message)
                }
            }

            $before = Get-DismImageInfoMap -ImagePath $ImagePath -Index 1
            $undefinedBefore = @($before.GetEnumerator() | Where-Object { $_.Value -eq '<undefined>' } | ForEach-Object { $_.Key })

            if ($undefinedBefore.Count -eq 0) {
                LogMeta "Metadata check: no undefined DISM fields detected."
                return
            }

            LogMeta "Metadata check: undefined DISM fields detected: $($undefinedBefore -join ', ')"
            LogMeta "Attempting best-effort metadata hydration for install.wim..."

            $setImage = Get-Command Set-WindowsImage -ErrorAction SilentlyContinue
            if (-not $setImage) {
                LogMeta "Set-WindowsImage is unavailable on this host; cannot write additional WIM metadata fields."
                return
            }

            $targetName = if ($EditionName -and $EditionName -ne 'Unknown') { $EditionName } else { $before['Name'] }
            if (-not $targetName) { $targetName = 'Windows 11' }

            $targetDescription = if ($before['Description'] -and $before['Description'] -ne '<undefined>') {
                $before['Description']
            } else {
                $targetName
            }

            $setArgs = @{
                ImagePath   = $ImagePath
                Index       = 1
                Name        = $targetName
                Description = $targetDescription
                ErrorAction = 'Stop'
            }

            try {
                Set-WindowsImage @setArgs | Out-Null
                LogMeta "Applied Set-WindowsImage metadata updates (Name/Description)."
            } catch {
                LogMeta "Warning: Set-WindowsImage metadata update failed: $_"
            }

            $after = Get-DismImageInfoMap -ImagePath $ImagePath -Index 1
            $undefinedAfter = @($after.GetEnumerator() | Where-Object { $_.Value -eq '<undefined>' } | ForEach-Object { $_.Key })
            if ($undefinedAfter.Count -eq 0) {
                LogMeta "Metadata hydration complete: no undefined DISM fields remain."
            } else {
                LogMeta "Metadata hydration complete. Remaining undefined DISM fields: $($undefinedAfter -join ', ')"
                LogMeta "Note: some DISM metadata fields are read-only and come from Microsoft image internals."
            }
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "Creating working directory: $workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            $mountDir    = Join-Path $workDir "wim_mount"
            New-Item -ItemType Directory -Path $isoContents, $mountDir -Force
            SetProgress "Copying ISO contents..." 10

            Log "Copying ISO contents from $driveLetter to $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO contents copied."
            SetProgress "Mounting install.wim..." 25

            $sourceImageFileName = Split-Path $wimPath -Leaf
            $localWim = Join-Path $isoContents "sources\$sourceImageFileName"
            if (-not (Test-Path $localWim)) {
                throw "Copied ISO image file not found: sources\$sourceImageFileName"
            }
            Set-ItemProperty -Path $localWim -Name IsReadOnly -Value $false

            Log "Mounting install.wim (Index ${selectedWimIndex}: $selectedEditionName) at $mountDir..."
            Mount-WindowsImage -ImagePath $localWim -Index $selectedWimIndex -Path $mountDir
            SetProgress "Modifying install.wim..." 45
            $selectedEditionId = Get-WinUtilMountedImageEditionId -MountDir $mountDir -EditionName $selectedEditionName -Logger ${function:Log}

            Log "Applying WinUtil modifications to install.wim..."
            Invoke-WinUtilISOScript -ScratchDir $mountDir -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -InstallEditionId $selectedEditionId -InstallImageIndex 1 -Log { param($m) Log $m }

            SetProgress "Cleaning up component store (WinSxS)..." 56
            Log "Running DISM component store cleanup (/ResetBase)..."
            & dism /English "/image:$mountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | ForEach-Object { Log $_ }
            Log "Component store cleanup complete."

            SetProgress "Saving modified install.wim..." 65
            Log "Dismounting and saving install.wim. This will take several minutes..."
            Dismount-WindowsImage -Path $mountDir -Save
            Log "install.wim saved."

            SetProgress "Removing unused editions from install.wim..." 70
            Log "Exporting edition '$selectedEditionName' (Index $selectedWimIndex) to a single-edition install.wim..."
            $exportWim = Join-Path $isoContents "sources\install_export.wim"
            Export-WindowsImage -SourceImagePath $localWim -SourceIndex $selectedWimIndex -DestinationImagePath $exportWim
            Remove-Item -Path $localWim -Force
            Rename-Item -Path $exportWim -NewName "install.wim" -Force
            $localWim = Join-Path $isoContents "sources\install.wim"
            Log "Unused editions removed. install.wim now contains only '$selectedEditionName'."

            SetProgress "Hydrating WIM metadata..." 76
            Invoke-WinUtilWimMetadataHydration -ImagePath $localWim -EditionName $selectedEditionName -Logger ${function:Log}

            SetProgress "Dismounting source ISO..." 80
            Log "Dismounting original ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "Modification complete" 100
            Log "install.wim modification complete. Choose an output option in Step 4."

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "ERROR during modification: $_"

            try {
                if (Test-Path $mountDir) {
                    $mountedImages = Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir }
                    if ($mountedImages) {
                        Log "Cleaning up: dismounting install.wim (discarding changes)..."
                        Dismount-WindowsImage -Path $mountDir -Discard
                    }
                }
            } catch { Log "Warning: could not dismount install.wim during cleanup: $_" }

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "修改 install.wim 時發生錯誤：`n`n$_",
                    "修改錯誤", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-Win11ISOLog "Existing working directory found: $($existingWorkDir.FullName)"
    Write-Win11ISOLog "Last modified: $modified - Skipping Steps 1-3 and resuming at Step 4."
    Write-Win11ISOLog "Click 'Clean & Reset' if you want to start over with a new ISO."

    [System.Windows.MessageBox]::Show(
        "找到先前的 WinUtil ISO 工作目錄：`n`n$($existingWorkDir.FullName)`n`n(最後修改時間: $modified)`n`n已還原步驟 4（輸出選項），您可以儲存已修改的映像。`n`n若要重新開始，請點選步驟 4 中的「清除並重設」。",
        "找到既有的工作進度", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "這將刪除暫存工作目錄：`n`n$workDir`n`n並將介面重設回起始狀態。`n`n是否繼續？",
            "清除並重設", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch { Log "WARNING: could not delete $($d.FullName): $_" }
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch { Log "WARNING: could not delete temp directory ${workDir}: $_" }

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found - resetting UI."
            }

            SetProgress "Resetting UI..." 95
            Log "Resetting interface..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "未選擇 ISO..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "已就緒。請選擇一個 Windows 11 ISO 以開始。"
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "找不到已修改的 ISO 內容。請先完成步驟 1 至 3。",
            "尚未就緒", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "儲存已修改的 Windows 11 ISO"
    $dlg.Filter           = "ISO 檔案 (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    # Locate oscdimg.exe (Windows ADK or winget per-user install)
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        Write-Win11ISOLog "oscdimg.exe not found. Attempting to install via winget..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-Win11ISOLog "winget output: $result"
            $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                       Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                       Select-Object -First 1 -ExpandProperty FullName
        } catch {
            Write-Win11ISOLog "winget not available or install failed: $_"
        }

        if (-not $oscdimg) {
            Write-Win11ISOLog "oscdimg.exe still not found after install attempt."
            [System.Windows.MessageBox]::Show(
                "找不到 oscdimg.exe，也無法自動安裝。`n`n請手動安裝：`n  winget install -e --id Microsoft.OSCDIMG`n`n或從以下網址安裝 Windows ADK：`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "找不到 oscdimg", "OK", "Warning")
            return
        }
        Write-Win11ISOLog "oscdimg.exe installed successfully."
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n" + ${function:Write-Win11ISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-Win11ISOLog "Exporting to ISO: $outputISO"
            SetProgress "Building ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-Win11ISOLog "Running oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-Win11ISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-Win11ISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO exported" 100
                Write-Win11ISOLog "ISO exported successfully: $outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO 匯出成功！`n`n$outputISO", "匯出完成", "OK", "Info")
                })
            } else {
                Write-Win11ISOLog "oscdimg exited with code $($proc.ExitCode)."
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg 結束，代碼為 $($proc.ExitCode)。`n請查看狀態記錄以了解詳情。",
                        "匯出錯誤", "OK", "Error")
                })
            }
        } catch {
            Write-Win11ISOLog "ERROR during ISO export: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO 匯出失敗：`n`n$_", "錯誤", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Applies WinUtil modifications to a mounted Windows 11 install.wim image.

    .DESCRIPTION
        Removes AppX bloatware and OneDrive, optionally injects all drivers exported from
        the running system into install.wim and boot.wim (controlled by the
        -InjectCurrentSystemDrivers switch), applies offline registry tweaks (hardware
        bypass, privacy, OOBE, telemetry, update suppression), deletes CEIP/WU
        scheduled-task definition files, and optionally writes autounattend.xml to the ISO
        root and removes the support\ folder from the ISO contents directory.

        All setup scripts embedded in the autounattend.xml <Extensions><File> nodes are
        written directly into the WIM at their target paths under C:\Windows\Setup\Scripts\
        to ensure they survive Windows Setup stripping unrecognised-namespace XML elements
        from the Panther copy of the answer file.

        Mounting/dismounting the WIM is the caller's responsibility (e.g. Invoke-WinUtilISO).

    .PARAMETER ScratchDir
        Mandatory. Full path to the directory where the Windows image is currently mounted.

    .PARAMETER ISOContentsDir
        Optional. Root directory of the extracted ISO contents. When supplied,
        autounattend.xml is written here and the support\ folder is removed.

    .PARAMETER AutoUnattendXml
        Optional. Full XML content for autounattend.xml. If empty, the OOBE bypass
        file is skipped and a warning is logged.

    .PARAMETER InjectCurrentSystemDrivers
        Optional. When $true, exports all drivers from the running system and injects
        them into install.wim and boot.wim index 2 (Windows Setup PE).
        Defaults to $false.

    .PARAMETER InstallEditionId
        Optional. Windows edition ID for the selected image, for example Professional
        or Core. Used to write sources\ei.cfg so setup does not fall back to an
        embedded firmware product key for a different edition.

    .PARAMETER InstallImageIndex
        Optional. Image index that setup should install from the final install.wim.
        Win11 Creator exports the selected edition to a single-image WIM, so this
        defaults to 1.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.

    .EXAMPLE
        Invoke-WinUtilISOScript -ScratchDir "C:\Temp\wim_mount"

    .EXAMPLE
        Invoke-WinUtilISOScript `
            -ScratchDir      $mountDir `
            -ISOContentsDir  $isoRoot `
            -AutoUnattendXml (Get-Content .\tools\autounattend.xml -Raw) `
            -Log             { param($m) Write-Host $m }

    .NOTES
        Author  : Chris Titus @christitustech
        GitHub  : https://github.com/ChrisTitusTech
    #>
    param (
        [Parameter(Mandatory)][string]$ScratchDir,
        [string]$ISOContentsDir = "",
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [string]$InstallEditionId = "",
        [int]$InstallImageIndex = 1,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )
    function Set-ISOScriptReg {
        param ([string]$Path, [string]$Name, [string]$Type, [string]$Value)
        try {
            & reg add $Path /v $Name /t $Type /d $Value /f
            & $Log "Set registry value: $Path\$Name"
        } catch {
            & $Log "Error setting registry value: $_"
        }
    }

    function Remove-ISOScriptReg {
        param ([string]$path)
        try {
            & reg delete $path /f
            & $Log "Removed registry key: $path"
        } catch {
            & $Log "Error removing registry key: $_"
        }
    }

    function Add-DriversToImage {
        param ([string]$MountPath, [string]$DriverDir, [string]$Label = "image", [scriptblock]$Logger)
        & dism /English "/image:$MountPath" /Add-Driver "/Driver:$DriverDir" /Recurse |
            ForEach-Object { & $Logger "  dism[$Label]: $_" }
    }

    function Invoke-BootWimInject {
        param ([string]$BootWimPath, [string]$DriverDir, [scriptblock]$Logger)
        Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false
        $mountDir = Join-Path $env:TEMP "WinUtil_BootMount_$(Get-Random)"
        New-Item -Path $mountDir -ItemType Directory -Force
        try {
            & $Logger "Mounting boot.wim (index 2) for driver injection..."
            Mount-WindowsImage -ImagePath $BootWimPath -Index 2 -Path $mountDir
            Add-DriversToImage -MountPath $mountDir -DriverDir $DriverDir -Label "boot" -Logger $Logger
            & $Logger "Saving boot.wim..."
            Dismount-WindowsImage -Path $mountDir -Save
            & $Logger "boot.wim driver injection complete."
        } catch {
            & $Logger "Warning: boot.wim driver injection failed: $_"
            try { Dismount-WindowsImage -Path $mountDir -Discard } catch { & $Logger "Warning: could not discard boot.wim mount: $_" }
        } finally {
            Remove-Item -Path $mountDir -Recurse -Force
        }
    }

    function Get-WinUtilISOScriptChildElement {
        param (
            [Parameter(Mandatory)][System.Xml.XmlElement]$Parent,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$NamespaceUri
        )

        foreach ($childNode in $Parent.ChildNodes) {
            if ($childNode.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                $childNode.LocalName -eq $Name -and
                $childNode.NamespaceURI -eq $NamespaceUri) {
                return [System.Xml.XmlElement]$childNode
            }
        }

        $childElement = $Parent.OwnerDocument.CreateElement($Name, $NamespaceUri)
        [void]$Parent.AppendChild($childElement)
        return $childElement
    }

    function ConvertTo-WinUtilISOAnswerFile {
        param (
            [Parameter(Mandatory)][string]$XmlContent,
            [int]$ImageIndex = 1
        )

        if ($ImageIndex -lt 1) { $ImageIndex = 1 }

        $unattendNs = "urn:schemas-microsoft-com:unattend"
        $wcmNs = "http://schemas.microsoft.com/WMIConfig/2002/State"

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)

        if ($xmlDoc.DocumentElement.NamespaceURI -ne $unattendNs) {
            throw "Unexpected autounattend.xml namespace: $($xmlDoc.DocumentElement.NamespaceURI)"
        }

        if (-not $xmlDoc.DocumentElement.HasAttribute("xmlns:wcm")) {
            $xmlDoc.DocumentElement.SetAttribute("wcm", "http://www.w3.org/2000/xmlns/", $wcmNs)
        }

        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace("u", $unattendNs)

        $windowsPESettings = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]', $nsMgr)
        if (-not $windowsPESettings) {
            $windowsPESettings = $xmlDoc.CreateElement("settings", $unattendNs)
            $windowsPESettings.SetAttribute("pass", "windowsPE")
            [void]$xmlDoc.DocumentElement.PrependChild($windowsPESettings)
        }

        $setupComponent = $windowsPESettings.SelectSingleNode('u:component[@name="Microsoft-Windows-Setup"]', $nsMgr)
        if (-not $setupComponent) {
            $setupComponent = $xmlDoc.CreateElement("component", $unattendNs)
            $setupComponent.SetAttribute("name", "Microsoft-Windows-Setup")
            $setupComponent.SetAttribute("processorArchitecture", "amd64")
            $setupComponent.SetAttribute("publicKeyToken", "31bf3856ad364e35")
            $setupComponent.SetAttribute("language", "neutral")
            $setupComponent.SetAttribute("versionScope", "nonSxS")
            [void]$windowsPESettings.AppendChild($setupComponent)
        }

        $productKeyNodes = @($setupComponent.SelectNodes("u:UserData/u:ProductKey", $nsMgr))
        foreach ($productKeyNode in $productKeyNodes) {
            $keyNode = $productKeyNode.SelectSingleNode("u:Key", $nsMgr)
            $keyValue = if ($keyNode) { $keyNode.InnerText.Trim() } else { "" }

            if ([string]::IsNullOrWhiteSpace($keyValue) -or $keyValue -eq "00000-00000-00000-00000-00000") {
                [void]$productKeyNode.ParentNode.RemoveChild($productKeyNode)
            }
        }

        $imageInstall = Get-WinUtilISOScriptChildElement -Parent $setupComponent -Name "ImageInstall" -NamespaceUri $unattendNs
        $osImage = Get-WinUtilISOScriptChildElement -Parent $imageInstall -Name "OSImage" -NamespaceUri $unattendNs
        $installFrom = Get-WinUtilISOScriptChildElement -Parent $osImage -Name "InstallFrom" -NamespaceUri $unattendNs

        $existingMetadataNodes = @($installFrom.SelectNodes("u:MetaData", $nsMgr))
        foreach ($metadataNode in $existingMetadataNodes) {
            [void]$installFrom.RemoveChild($metadataNode)
        }

        $metadata = $xmlDoc.CreateElement("MetaData", $unattendNs)
        $actionAttribute = $xmlDoc.CreateAttribute("wcm", "action", $wcmNs)
        $actionAttribute.Value = "add"
        [void]$metadata.Attributes.Append($actionAttribute)

        $keyElement = $xmlDoc.CreateElement("Key", $unattendNs)
        $keyElement.InnerText = "/IMAGE/INDEX"
        [void]$metadata.AppendChild($keyElement)

        $valueElement = $xmlDoc.CreateElement("Value", $unattendNs)
        $valueElement.InnerText = [string]$ImageIndex
        [void]$metadata.AppendChild($valueElement)

        [void]$installFrom.AppendChild($metadata)

        return $xmlDoc.OuterXml
    }

    function Write-WinUtilISOEditionConfig {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [string]$EditionId,
            [scriptblock]$Logger
        )

        if (-not (Test-Path $ContentRoot)) {
            return
        }

        $sourcesDir = Join-Path $ContentRoot "sources"
        New-Item -Path $sourcesDir -ItemType Directory -Force | Out-Null

        $pidPath = Join-Path $sourcesDir "PID.txt"
        if (Test-Path $pidPath) {
            Remove-Item -Path $pidPath -Force
            & $Logger "Removed sources\PID.txt so setup will not force a stale or mismatched product key."
        }

        if ([string]::IsNullOrWhiteSpace($EditionId)) {
            & $Logger "Warning: selected edition ID is unknown - skipping sources\ei.cfg fallback."
            return
        }

        $eiCfgPath = Join-Path $sourcesDir "ei.cfg"
        $eiCfg = @"
[EditionID]
$EditionId
[Channel]
Retail
[VL]
0
"@.Trim()

        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        & $Logger "Written sources\ei.cfg for EditionID '$EditionId'."
    }

    # -- 1. Remove provisioned AppX packages ----------------------------------
    & $Log "Removing provisioned AppX packages..."

    $packages = & dism /English "/image:$ScratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

    $packagePrefixes = @(
        'Clipchamp.Clipchamp',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.ZuneMusic',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams'
    )

    $packages | Where-Object { $pkg = $_; $packagePrefixes | Where-Object { $pkg -like "*$_*" } } |
        ForEach-Object { & dism /English "/image:$ScratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$_" }

    # -- 2. Inject current system drivers (optional) ---------------------------
    if ($InjectCurrentSystemDrivers) {
        & $Log "Exporting all drivers from running system..."
        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Random)"
        New-Item -Path $driverExportRoot -ItemType Directory -Force
        try {
            Export-WindowsDriver -Online -Destination $driverExportRoot

            & $Log "Injecting current system drivers into install.wim..."
            Add-DriversToImage -MountPath $ScratchDir -DriverDir $driverExportRoot -Label "install" -Logger $Log
            & $Log "install.wim driver injection complete."

            if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
                $bootWim = Join-Path $ISOContentsDir "sources\boot.wim"
                if (Test-Path $bootWim) {
                    & $Log "Injecting current system drivers into boot.wim..."
                    Invoke-BootWimInject -BootWimPath $bootWim -DriverDir $driverExportRoot -Logger $Log
                } else {
                    & $Log "Warning: boot.wim not found - skipping boot.wim driver injection."
                }
            }
        } catch {
            & $Log "Error during driver export/injection: $_"
        } finally {
            Remove-Item -Path $driverExportRoot -Recurse -Force
        }
    } else {
        & $Log "Driver injection skipped."
    }

    # -- 3. Registry tweaks ----------------------------------------------------
    & $Log "Loading offline registry hives..."
    reg load HKLM\zCOMPONENTS "$ScratchDir\Windows\System32\config\COMPONENTS"
    reg load HKLM\zDEFAULT    "$ScratchDir\Windows\System32\config\default"
    reg load HKLM\zNTUSER     "$ScratchDir\Users\Default\ntuser.dat"
    reg load HKLM\zSOFTWARE   "$ScratchDir\Windows\System32\config\SOFTWARE"
    reg load HKLM\zSYSTEM     "$ScratchDir\Windows\System32\config\SYSTEM"

    & $Log "Bypassing system requirements..."
    Set-ISOScriptReg -Path 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV1' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV2' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV1' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV2' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassCPUCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassRAMCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassSecureBootCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassStorageCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassTPMCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling sponsored apps..."
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'OemPreInstalledAppsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'ContentDeliveryAllowed' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins' -Type 'REG_SZ' -Value '{"pinnedList": [{}]}'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'FeatureManagementEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEverEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SoftLandingEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContentEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-310093Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338388Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338393Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353694Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353696Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' -Name 'DisablePushToInstall' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' -Name 'DontOfferThroughWUAU' -Type 'REG_DWORD' -Value '1'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent' -Type 'REG_DWORD' -Value '1'

    & $Log "Enabling local accounts on OOBE..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'BypassNRO' -Type 'REG_DWORD' -Value '1'

    if ($AutoUnattendXml) {
        $preparedAutoUnattendXml = $AutoUnattendXml
        try {
            $preparedAutoUnattendXml = ConvertTo-WinUtilISOAnswerFile -XmlContent $AutoUnattendXml -ImageIndex $InstallImageIndex
            & $Log "Prepared autounattend.xml to install image index $InstallImageIndex without forcing a product key."
        } catch {
            & $Log "Warning: could not prepare autounattend.xml image selection: $_"
        }

        try {
            $xmlDoc = [xml]::new()
            $xmlDoc.LoadXml($preparedAutoUnattendXml)

            $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
            $nsMgr.AddNamespace("sg", "https://schneegans.de/windows/unattend-generator/")

            $fileNodes = $xmlDoc.SelectNodes("//sg:File", $nsMgr)
            if ($fileNodes -and $fileNodes.Count -gt 0) {
                foreach ($fileNode in $fileNodes) {
                    $absPath  = $fileNode.GetAttribute("path")
                    $relPath  = $absPath -replace '^[A-Za-z]:[/\\]', ''
                    $destPath = Join-Path $ScratchDir $relPath
                    New-Item -Path (Split-Path $destPath -Parent) -ItemType Directory -Force

                    $ext = [IO.Path]::GetExtension($destPath).ToLower()
                    $encoding = switch ($ext) {
                        { $_ -in '.ps1', '.xml' }        { [System.Text.Encoding]::UTF8 }
                        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true) }
                        default                          { [System.Text.Encoding]::Default }
                    }
                    [System.IO.File]::WriteAllBytes($destPath, ($encoding.GetPreamble() + $encoding.GetBytes($fileNode.InnerText.Trim())))
                    & $Log "Pre-staged setup script: $relPath"
                }
            } else {
                & $Log "Warning: no <Extensions><File> nodes found in autounattend.xml - setup scripts not pre-staged."
            }
        } catch {
            & $Log "Warning: could not pre-stage setup scripts from autounattend.xml: $_"
        }

        if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
            $isoDest = Join-Path $ISOContentsDir "autounattend.xml"
            Set-Content -Path $isoDest -Value $preparedAutoUnattendXml -Encoding UTF8 -Force
            & $Log "Written autounattend.xml to ISO root ($isoDest)."
        }
    } else {
        & $Log "Warning: autounattend.xml content is empty - skipping OOBE bypass file."
    }

    if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
        Write-WinUtilISOEditionConfig -ContentRoot $ISOContentsDir -EditionId $InstallEditionId -Logger $Log
    }

    & $Log "Disabling reserved storage..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves' -Type 'REG_DWORD' -Value '0'

    & $Log "Disabling BitLocker device encryption..."
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' -Name 'PreventDeviceEncryption' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling Chat icon..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' -Name 'ChatIcon' -Type 'REG_DWORD' -Value '3'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -Type 'REG_DWORD' -Value '0'

    & $Log "Disabling OneDrive folder backup..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling telemetry..."
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' -Name 'Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitInkCollection' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitTextCollection' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' -Name 'HarvestContacts' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' -Name 'Start' -Type 'REG_DWORD' -Value '4'

    & $Log "Preventing installation of DevHome and Outlook..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

    & $Log "Disabling Copilot..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' -Name 'HubsSidebarEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling Windows Update during OOBE (re-enabled on first logon via FirstLogon.ps1)..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'AUOptions' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'UseWUServer' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'DisableWindowsUpdateAccess' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'WUServer' -Type 'REG_SZ' -Value 'http://localhost:8080'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'WUStatusServer' -Type 'REG_SZ' -Value 'http://localhost:8080'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' -Name 'DODownloadMode' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\BITS' -Name 'Start' -Type 'REG_DWORD' -Value '4'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' -Name 'Start' -Type 'REG_DWORD' -Value '4'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc' -Name 'Start' -Type 'REG_DWORD' -Value '4'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSvc' -Name 'Start' -Type 'REG_DWORD' -Value '4'

    & $Log "Preventing installation of Teams..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' -Name 'DisableInstallation' -Type 'REG_DWORD' -Value '1'

    & $Log "Preventing installation of new Outlook..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' -Name 'PreventRun' -Type 'REG_DWORD' -Value '1'

    & $Log "Unloading offline registry hives..."
    reg unload HKLM\zCOMPONENTS
    reg unload HKLM\zDEFAULT
    reg unload HKLM\zNTUSER
    reg unload HKLM\zSOFTWARE
    reg unload HKLM\zSYSTEM

    # -- 4. Delete scheduled task definition files -----------------------------
    & $Log "Deleting scheduled task definition files..."
    $tasksPath = "$ScratchDir\Windows\System32\Tasks"
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program"                  -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater"               -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Chkdsk\Proxy"                                            -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"                  -Force
    Remove-Item "$tasksPath\Microsoft\Windows\InstallService"                                          -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateOrchestrator"                                      -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateAssistant"                                         -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WaaSMedic"                                               -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WindowsUpdate"                                           -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\WindowsUpdate"                                                   -Recurse -Force
    & $Log "Scheduled task files deleted."

    # -- 5. Remove ISO support folder -----------------------------------------
    if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
        & $Log "Removing ISO support\ folder..."
        Remove-Item -Path (Join-Path $ISOContentsDir "support") -Recurse -Force
        & $Log "ISO support\ folder removed."
    }
}

function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("未偵測到 USB 磁碟。")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-Win11ISOLog "No USB drives detected."
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-Win11ISOLog "Found $($removable.Count) USB drive(s)."
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("找不到已修改的 ISO 內容。請先完成步驟 1 至 3。", "尚未就緒", "OK", "Warning")
        return
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("請從下拉選單中選擇一個 USB 磁碟。", "未選擇磁碟", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "磁碟 $diskNum ($($targetDisk.FriendlyName), $sizeGB GB) 上的所有資料將被永久清除。`n`n您確定要繼續嗎？",
        "確認清除 USB", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-Win11ISOLog "USB write cancelled by user."
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    Write-Win11ISOLog "Starting USB write to Disk $diskNum..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = $label
                $sync.progressBarTextBlock.ToolTip = $label
                $sync.ProgressBar.Value            = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "Formatting USB drive..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch { Log "Warning: could not remove existing partition access path: $_" }
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "Copying Windows 11 files to USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "Finalising USB drive..." 90
            Log "Files copied to USB."
            SetProgress "USB write complete" 100
            Log "USB drive is ready for use."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB 磁碟建立成功！`n`n您現在可以從此磁碟開機以安裝 Windows 11。",
                    "USB 已就緒", "OK", "Info")
            })
        } catch {
            Log "ERROR during USB write: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB 寫入失敗：`n`n$_", "USB 寫入錯誤", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync.progressBarTextBlock.Text    = ""
                $sync.progressBarTextBlock.ToolTip = ""
                $sync.ProgressBar.Value            = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "Running Script for $Name"
        Write-WinUtilLog -Component "Script" -Message "Running script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
        Write-WinUtilLog -Component "Script" -Message "Completed script for $Name"
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Command not found while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Runtime exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Security exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Access denied while running script for $Name`: $($PSItem.Exception.Message)"
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Unhandled exception while running script for $Name`: $($psitem.Exception.Message)"
    }

}

Function Invoke-WinUtilSponsors {
    $sponsors = ([regex]::Matches(([regex]::Match((Invoke-RestMethod https://github.com/sponsors/ChrisTitusTech),'(?s)(?<=Current sponsors).*?(?=Past sponsors)')).Value,'(?<=alt="@)[^"]+')).Value | Where-Object {$_ -ne "ChrisTitusTech"}
    return $sponsors
}

function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "Enabling OpenSSH Server... This will take a long time."
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "Starting the services"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "Setting up firewall rules"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "Firewall rule for OpenSSH Server created and enabled."
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "Creating ssh directory..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "Creating authorized_keys file..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "Configuring sshd_config for standard authorized_keys behavior..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "Commented out administrator-specific SSH key configuration in sshd_config"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH server was successfully enabled."
    Write-Host "The config file can be located at C:\ProgramData\ssh\sshd_config"
    Write-Host "Add your public keys to this file -> $authorizedKeysPath"
}

function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # Apply properties that deal with colors
            if ($themeProperty.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}

function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    $action = if ($undo) { "Undo" } else { "Apply" }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak: $CheckBox"

    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if ($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Remove-WinUtilAPPX -Name $psitem
            }
        }
    }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak completed: $CheckBox"
}

function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "Successfully uninstalled CTT PowerShell Profile." -ForegroundColor Green
}

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "Removing $Name"
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX package pattern: $Name"
    Get-AppxPackage $Name -AllUsers | Remove-AppxPackage -AllUsers
    Get-AppxProvisionedPackage -Online | Where-Object DisplayName -like $Name | Remove-AppxProvisionedPackage -Online
    Write-WinUtilLog -Component "AppX" -Message "AppX removal completed for package pattern: $Name"
}

function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )

    $CheckBoxesToCheck = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures + $sync.selectedAppx
    $CheckBoxes = foreach ($syncEntry in $sync.GetEnumerator()) {
        if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -like $checkboxfilterpattern) {
            $syncEntry
        }
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key
        if (-not $CheckBoxesToCheck) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "已選軟體: $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = $sync.selectedToggles
        $allToggles = $sync.GetEnumerator() | Where-Object { $_.Key -like "WPFToggle*" -and $_.Value -is [System.Windows.Controls.CheckBox] }
        foreach ($toggle in $allToggles) {
            if ($importedToggles -contains $toggle.Key) {
                $sync[$toggle.Key].IsChecked = $true
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}

function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if($DNSProvider -eq "Default") {
        Write-WinUtilLog -Component "DNS" -Message "DNS provider is Default; no DNS changes applied."
        return
    }

    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "Ensuring DNS is set to $DNSProvider on the following interfaces:"
        Write-Host $($Adapters | Out-String)
        Write-WinUtilLog -Component "DNS" -Message "Setting DNS provider to $DNSProvider for $(@($Adapters).Count) active adapter(s)."

        if($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if($null -eq $dns) {
                Write-Warning "DNS provider $DNSProvider was not found in configuration."
                Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not found in configuration."
                return
            }
        }

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Write-WinUtilLog -Component "DNS" -Message "Resetting DNS to DHCP on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex))."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp
            } else {
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv4 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary), $($dns.Secondary)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary, $dns.Secondary)
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv6 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary6), $($dns.Secondary6)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary6, $dns.Secondary6)
            }
        }
        Write-WinUtilLog -Component "DNS" -Message "DNS provider change completed: $DNSProvider"
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "Unable to set DNS provider $DNSProvider`: $($psitem.Exception.Message)"
    }
}

function Set-WinUtilProgressbar{
    <#
    .SYNOPSIS
        This function is used to Update the Progress Bar displayed in the winutil GUI.
        It will be automatically hidden if the user clicks something and no process is running
    .PARAMETER Label
        The Text to be overlaid onto the Progress Bar
    .PARAMETER PERCENT
        The percentage of the Progress Bar that should be filled (0-100)
    #>
    param(
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    $progressLabel = $Label

    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.Text = $progressLabel}
    Invoke-WPFUIThread -ScriptBlock {$sync.progressBarTextBlock.ToolTip = $progressLabel}
    if ($Percent -lt 5 ) {
        $Percent = 5 # Ensure the progress bar is not empty, as it looks weird
    }
    Invoke-WPFUIThread -ScriptBlock { $sync.ProgressBar.Value = $Percent}

}

function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            Write-WinUtilLog -Component "Registry" -Message "Creating registry path: $Path"
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "Set $Path\$Name to $Value"
            Write-WinUtilLog -Component "Registry" -Message "Setting $Path\$Name ($Type) to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "Remove $Path\$Name"
            Write-WinUtilLog -Component "Registry" -Message "Removing $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Security exception while changing $Path\$Name to $Value`: $($psitem.Exception.Message)"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Registry item not found while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
       Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unauthorized while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unhandled exception while changing $Path\$Name`: $($psitem.Exception.Message)"
    }
}

Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "Setting Service $Name to $StartupType"
        Write-WinUtilLog -Component "Service" -Message "Setting service $Name startup type to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType) ) {
            Write-Host "Service $Name is already set to $StartupType"
            Write-WinUtilLog -Component "Service" -Message "Service $Name startup type is already $StartupType; no change needed."
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
        Write-WinUtilLog -Component "Service" -Message "Service $Name startup type set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
            Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
            Write-WinUtilLog -Level "ERROR" -Component "Service" -Message "Unable to set service $Name to $StartupType`: $($_.Exception.Message)"
        }
    }

}

function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}

function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0
    $linkHoverBrush = $LinkHoverForegroundColor

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Start-Process $eventSender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $linkHoverBrush
            $eventSender.FontSize = ($FontSize + ($FontSize / 4))
            $eventSender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $LinkForegroundColor
            $eventSender.FontSize = $FontSize
            $eventSender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}

function Show-WinUtilMessage {
    <#
    .SYNOPSIS
        Shows a WinUtil message box and returns the selected result.
    #>
    param (
        [string]$Message,
        [string]$Title = "Winutil",
        $Button = "OK",
        $Icon = "Information"
    )

    [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}

function Show-WPFInstallAppBusy {
    <#
    .SYNOPSIS
        Displays a busy overlay in the install app area of the WPF form.
        This is used to indicate that an install or uninstall is in progress.
        Dynamically updates the size of the overlay based on the app area on each invocation.
    .PARAMETER text
        The text to display in the busy overlay. Defaults to "Installing apps...".
    #>
    param (
        $text = "Installing apps..."
    )
    $overlayText = $text

    Invoke-WPFUIThread -ScriptBlock {
        $sync.InstallAppAreaOverlay.Visibility = [Windows.Visibility]::Visible
        $sync.InstallAppAreaOverlay.Width = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlay.Height = $($sync.InstallAppAreaScrollViewer.ActualWidth * 0.4)
        $sync.InstallAppAreaOverlayText.Text = $overlayText
        $sync.InstallAppAreaBorder.IsEnabled = $false
        $sync.InstallAppAreaScrollViewer.Effect.Radius = 5
    }
}

function Invoke-WinUtilInstallAppRenderBatch {
    param(
        [Parameter(Mandatory = $true)]
        $CategoryBatch
    )

    foreach ($appKey in $CategoryBatch.AppKeys) {
        $sync.$appKey = Initialize-InstallAppEntry -TargetElement $CategoryBatch.TargetElement -AppKey $appKey
    }

    if ($sync.currentTab -eq "Install" -and $sync.SearchBar -and -not [string]::IsNullOrWhiteSpace($sync.SearchBar.Text)) {
        Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
    }
}

function Complete-WinUtilInstallAppRendering {
    $sync.InstallAppEntriesRendered = $true
}

function Invoke-WinUtilInstallAppRenderNextBatch {
    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    Complete-WinUtilInstallAppRendering
}

function Start-WinUtilInstallAppRendering {
    if ($null -eq $sync.InstallAppRenderQueue) {
        return
    }

    $sync.InstallAppEntriesRendered = $false

    if ($sync.Form -and $sync.Form.Dispatcher) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    while ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    Complete-WinUtilInstallAppRendering
}

function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}

function Update-WinUtilSelections ($flatJson) {
    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        $sync.$listName.Add($cbkey)
    }
}

function Write-WinUtilLog {
    <#

    .SYNOPSIS
        Writes a timestamped WinUtil log entry to the active session log.

    .PARAMETER Message
        The message to write.

    .PARAMETER Level
        The severity level for the log entry.

    .PARAMETER Component
        The WinUtil component producing the log entry.

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$Component = "WinUtil"
    )

    try {
        $logPath = $null
        $transcriptPath = $null
        if ($null -ne $sync -and $sync.ContainsKey("logPath")) {
            $logPath = $sync.logPath
        }

        if ($null -ne $sync -and $sync.ContainsKey("transcriptPath")) {
            $transcriptPath = $sync.transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            $logPath = $transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and $null -ne $sync -and $sync.ContainsKey("winutildir")) {
            $logDirectory = Join-Path $sync.winutildir "logs"
            $logPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            $sync.logPath = $logPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
            if ([string]::IsNullOrWhiteSpace($script:WinUtilLogPath)) {
                $logDirectory = Join-Path (Join-Path $env:LocalAppData "winutil") "logs"
                $script:WinUtilLogPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            }
            $logPath = $script:WinUtilLogPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath)) {
            return
        }

        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "[$timestamp] [$Level] [$Component] $Message"

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and $logPath -eq $transcriptPath) {
            Write-Host $line
            return
        }

        try {
            Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch [System.IO.IOException] {
            Write-Host $line
        }
    } catch {
        Write-Warning "Unable to write WinUtil log entry: $($_.Exception.Message)"
    }
}

function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}


function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Milliseconds 100
        while ($sync.ProcessRunning) {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "Applying tweaks..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "Applying features..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "Installing applications..."
        Invoke-WPFInstall
        BusyWait
    }

    if ($sync.selectedAppx.Count -gt 0) {
        Write-Host "Removing AppX packages..."
        Invoke-WPFAppxRemoval
        BusyWait
    }

    Write-Host "Done."
}

function Invoke-WPFAppxRemoval {
    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "未選擇任何 AppX 套件" -Title "錯誤" -Button "OK" -Icon "Error"
        return
    }

    $selected = $sync.selectedAppx
    $apps = $sync.configs.appxHashtable

    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $sync.ProcessRunning = $true
        Write-WinUtilLog -Component "AppX" -Message "Starting AppX removal for $(@($selected).Count) selected package(s)."

        foreach ($key in $selected) {
            if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                # Making sure Game Bar isn't running
                Write-WinUtilLog -Component "AppX" -Message "Stopping GameBarFTServer before removing Xbox Gaming Overlay."
                Stop-Process -Name GameBarFTServer

                # This stops annoying ms-gamebar popup when launching games.
                Write-WinUtilLog -Component "AppX" -Message "Disabling Game DVR capture before removing Xbox Gaming Overlay."
                Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0
            }

            if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                # i hope your having fun reading this
                Write-WinUtilLog -Component "AppX" -Message "Stopping dllhost before removing Notepad."
                Stop-Process -Name dllhost
            }

            Write-Host "Removing $($apps[$key].Content)"
            Write-WinUtilLog -Component "AppX" -Message "Removing $($apps[$key].Content) ($($apps[$key].PackageId))."
            Get-AppxPackage -Name $apps[$key].PackageId -AllUsers | Remove-AppxPackage -AllUsers

            if ($key -eq "WPFAppxMSTeams") {
                # Uninstalls Microsoft Teams Meeting Add-in for Microsoft Office
                Write-WinUtilLog -Component "AppX" -Message "Uninstalling Microsoft Teams meeting add-in package."
                Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force
            }
        }

        Write-Host "================================="
        Write-Host "--   AppX Removal Finished   ---"
        Write-Host "================================="
        Write-WinUtilLog -Component "AppX" -Message "AppX removal finished."

        $sync.ProcessRunning = $false
    }
}

function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning) {
        Set-WinUtilProgressBar  -label "" -percent 0
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFAdvanced" {Invoke-WPFPresets "Advanced" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Enable}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFRemoveSelectedAppx" {Invoke-WPFAppxRemoval}
        "WPFDefaultAppxSelection" {Invoke-WPFPresets "AppxDefault" -checkboxfilterpattern "WPFAppx*"}
        "WPFSelectAllAppx" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $true}
        }
        "WPFClearAppxSelection" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $false}
        }
        "WPFGetInstalledAppx" {
            $installedAppxPackages = Get-AppxPackage -AllUsers | Select-Object -ExpandProperty Name
            foreach ($appx in $sync.configs.appxHashtable.GetEnumerator()) {
                if ($appx.Value.PackageId -in $installedAppxPackages) {
                    $sync.$($appx.Key).IsChecked = $true
                }
            }
        }
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "Bye bye!"}
        "WPFMinimizeButton" {$sync.Form.WindowState = [Windows.WindowState]::Minimized}
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
    }
}

function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall] 目前有一個安裝程序正在執行中。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$Features.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   Features are Installed    ---"
        Write-Host "---  A Reboot may be required   ---"
        Write-Host "==================================="
    }
}

function Invoke-WPFFixesNetwork {
    netsh winsock reset
    netsh int ip reset
    Write-Host "Network Configuration has been Reset. Please restart your computer."
}

function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP Configuration Complete ---"
    Write-Host "================================="
}

function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "Starting Windows Update Repair..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting driver offering through Windows Update..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "Defaulting Windows Update automatic restart..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "Clearing ANY Windows Update Policy settings..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "重設 Windows Update "
    $Messageboxbody = ("已載入原廠設定。`n 請重新開機")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- Reset All Windows Update Settings to Stock -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}

function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}

function Invoke-WPFGetInstalled {
    <#
    TODO: Add the Option to use Chocolatey as Engine
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled] 目前有一個安裝程序正在執行中。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager

    Invoke-WPFRunspace -ParameterList @(("managerPreference", $managerPreference),("checkbox", $checkbox)) -ScriptBlock {
        param (
            [string]$checkbox,
            [string]$managerPreference
        )
        $sync.ProcessRunning = $true
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" }

        if ($checkbox -eq "winget") {
            Write-Host "Getting Installed Programs..."
            switch ($managerPreference) {
                "Choco"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox "choco"; break}
                "Winget"{$Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox; break}
            }
        }
        elseif ($checkbox -eq "tweaks") {
            Write-Host "Getting Installed Tweaks..."
            $Checkboxes = Invoke-WinUtilCurrentSystem -CheckBox $checkbox
        }

        $sync.form.Dispatcher.invoke({
            foreach ($checkbox in $Checkboxes) {
                $sync.$checkbox.ischecked = $True
            }
        })

        Write-Host "Done..."
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" }
    }
}

function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON 檔案 (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures + $sync.selectedAppx) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "沒有選擇任何要匯出的設定。匯出前，請至少選擇一個軟體、調校、開關、功能或 AppX 套件。",
                            "沒有可匯出的項目", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "所選檔案不含任何可匯入的設定。未做任何變更。",
                            "空白設定檔", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if ($sync.Form) {
                        Reset-WPFCheckBoxes -doToggles $true
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}

function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
    #>

    $PackagesToInstall = $sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ }


    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFInstall] 目前有一個安裝程序正在執行中。"
        Show-WinUtilMessage -Message $msg -Title "Winutil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "請選擇要安裝或升級的程式。"
        Show-WinUtilMessage -Message $WarningMsg -Title $AppTitle -Button "OK" -Icon "Warning"
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Install" -Message "Install requested for $(@($PackagesToInstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToInstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Install" -Message "Install selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Show-WPFInstallAppBusy -text "正在安裝應用程式..."
                Install-WinUtilWinget
                Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--      Installs have finished          ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow failed: $($_.Exception.Message)"
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        } finally {
            $sync.ProcessRunning = $False
        }
    }
}

function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList '-NoExit winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}

function Invoke-WPFOOSU {
    try {
        $ProgressPreference = 'SilentlyContinue'

        Invoke-WebRequest -Uri https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe -OutFile "$winutildir\ooshutup10.exe"
        Start-Process -FilePath "$winutildir\ooshutup10.exe"

        $ProgressPreference = 'Continue'
    } catch {
        Write-Error "Couldn't download O&O ShutUp10. Please make sure you have an active Internet connection."
    }
}

function Invoke-WPFPanelAutologin {
    Invoke-WebRequest -Uri https://live.sysinternals.com/Autologon.exe -OutFile "$winutildir\autologin.exe"
    Start-Process -FilePath "$winutildir\autologin.exe" -ArgumentList /accepteula
}

function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}

function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFAppx*" { $sync.selectedAppx = [System.Collections.Generic.List[string]]::new() }
        "WPFeatures" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}

function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    if (-not ("WinUtilRunspaceCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilRunspaceCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilRunspaceCleanup
{
    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspaceCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@
    }

    Initialize-WinUtilRunspacePool | Out-Null

    # Create a PowerShell instance
    $powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    [void]$powershell.AddScript($ScriptBlock)
    [void]$powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        [void]$powershell.AddParameter($parameter[0], $parameter[1])
    }

    $powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $handle = $powershell.BeginInvoke()

    $cleanupState = [WinUtilRunspaceCleanupState]::new()
    $cleanupState.PowerShell = $powershell
    $cleanupState.Handle = $handle
    $cleanupCallback = [System.Delegate]::CreateDelegate([System.Threading.WaitOrTimerCallback], [WinUtilRunspaceCleanup], "Cleanup")
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, $cleanupCallback, $cleanupState, -1, $true) | Out-Null

    # Return the handle
    return $handle
}

function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }

    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
        }
    } else {
        $sync.$listName.Remove($checkboxName)
    }

    if ($listName -eq 'selectedApps' -and $sync.WPFselectedAppsButton) {
        $sync.WPFselectedAppsButton.Content = "已選軟體: $($sync.selectedApps.Count)"
    }
}

function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}

function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}

function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
            $tabNumber = [int]($ClickedTab-replace "WPFTab","" -replace "BT","") - 1
            $sync.$tabNav.Items[$tabNumber].IsSelected = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header
    Initialize-WinUtilTabContent -TabName $sync.currentTab

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "AppX") {
        # Reset AppX tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install, Tweaks, and AppX tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1 -or $tabNumber -eq 5) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}

function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl not initialized"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}

function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton] 目前有一個安裝程序正在執行中。"
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0
  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) selected tweak(s), DNS provider: $dnsProvider"

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "請勾選您要執行的調校項目。"
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilProgressBar -Label "Creating restore point" -Percent 0
    Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilProgressBar -Label "Tweaks finished" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     Tweaks are Finished    ---"
      Write-Host "================================="
      Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed after restore point."
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    if ($dnsProvider -ne "Default") {
      Set-WinUtilDNS -DNSProvider $dnsProvider
    }

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilProgressBar -Label "Applying $($tweaks[$i])" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilProgressBar -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     Tweaks are Finished    ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed."
  }
}

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletRun = New-Object Windows.Documents.Run
                        $bulletRun.Text = [char]0x25CF
                        $bulletRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(110, 255, 114))
                        $bulletRun.FontSize = 11.5

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletRun)
                        $textBlock.Inlines.Add($textRun)

                        $itemsControl.Items.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true
                            
                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $fontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
                                [Windows.Controls.Control]::FontSizeProperty,
                                [Windows.Controls.TextBlock]
                            )
                            $fontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkbox $Sender.name
                        })
                    }
                }
            }
        }
    }
}

function Invoke-WPFUIThread ($ScriptBlock) {
    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}

function Invoke-WPFUltimatePerformance ([switch]$Enable) {
    if ($Enable) {
        powercfg /setactive (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value
        [System.Windows.MessageBox]::Show("已安裝並啟用「極致效能」電源計劃。","成功","OK","Information")
    } else {
        powercfg /restoredefaultschemes
        [System.Windows.MessageBox]::Show("電源計劃已重設為預設值。","成功","OK","Information")
    }
}

function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall] 目前有一個安裝程序正在執行中。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "請勾選您要復原的調校項目。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $(@($tweaks).Count) selected tweak(s)."
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilProgressBar -Label "Undoing $($tweaks[$i])" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilProgressBar -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  Undo Tweaks are Finished  ---"
        Write-Host "=================================="
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks workflow completed."

    }
}

function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall] 目前有一個安裝程序正在執行中"
        Show-WinUtilMessage -Message $msg -Title "Winutil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "請選擇要解除安裝的程式"
        Show-WinUtilMessage -Message $WarningMsg -Title $AppTitle -Button "OK" -Icon "Warning"
        return
    }

    $ButtonType = "YesNo"
    $MessageboxTitle = "確定嗎？"
    $Messageboxbody = ("此操作將解除安裝以下應用程式： `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = "Information"

    $confirm = Show-WinUtilMessage -Message $Messageboxbody -Title $MessageboxTitle -Button $ButtonType -Icon $MessageIcon

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall requested for $(@($PackagesToUninstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToUninstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            Show-WPFInstallAppBusy -text "正在解除安裝應用程式..."

            if ($packagesWinget -contains "Microsoft.Edge") {
                New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
            }

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                Install-WinUtilProgramWinget -Action Uninstall -Programs $packagesWinget
            }
            if($packagesChoco.Count -gt 0) {
                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
            }
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Uninstall" -Message "Uninstall workflow completed."
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        } catch {
            Hide-WPFInstallAppBusy
            Write-Host "==========================================="
            Write-Host "Error: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Uninstall" -Message "Uninstall workflow failed: $($_.Exception.Message)"
           Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
        } finally {
            $sync.ProcessRunning = $False
        }

    }
}

function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    $ErrorActionPreference = 'SilentlyContinue'
    Write-WinUtilLog -Component "Updates" -Message "Resetting Windows Update settings to default."

    Write-Host "Removing Windows Update policy settings..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Removing Windows Update policy registry paths."

    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Recurse -Force
    Remove-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Recurse -Force

    Write-Host "Showing Windows Updates in settings..."
    Write-WinUtilLog -Component "Updates" -Message "Showing Windows Update settings page."
    Remove-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name SettingsPageVisibility

    Write-Host "Reenabling Windows Update Services..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update service startup types."

    Write-Host "Restored BITS to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring BITS service to Manual."
    Set-Service -Name BITS -StartupType Manual

    Write-Host "Restored wuauserv to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring wuauserv service to Manual."
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "Restored UsoSvc to Automatic."
    Write-WinUtilLog -Component "Updates" -Message "Starting UsoSvc service and restoring startup type to Automatic."
    Start-Service -Name UsoSvc
    Set-Service -Name UsoSvc -StartupType Automatic

    Write-Host "Restored WaaSMedicSvc to Manual."
    Write-WinUtilLog -Component "Updates" -Message "Restoring WaaSMedicSvc service to Manual."
    Set-Service -Name WaaSMedicSvc -StartupType Manual

    Write-Host "Enabling update related scheduled tasks..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Enabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "Windows Local Policies Reset to Default."
    Write-WinUtilLog -Component "Updates" -Message "Resetting local security policy to defaults with secedit."
    secedit /configure /cfg "$Env:SystemRoot\inf\defltbase.inf" /db defltbase.sdb

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update default workflow completed. Restart required."
}

function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $ErrorActionPreference = 'SilentlyContinue'
    Write-WinUtilLog -Component "Updates" -Message "Disabling Windows Update settings."

    Write-Host "Configuring registry settings..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Configuring Windows Update registry policy values for disable mode."
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    Write-Host "Hiding Windows Updates from settings..."
    Write-WinUtilLog -Component "Updates" -Message "Hiding Windows Update settings page."
    Set-ItemProperty -Path HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer -Name SettingsPageVisibility -Value hide:windowsupdate

    Write-Host "Disabled BITS Service."
    Write-WinUtilLog -Component "Updates" -Message "Disabling BITS service."
    Set-Service -Name BITS -StartupType Disabled

    Write-Host "Disabled wuauserv Service."
    Write-WinUtilLog -Component "Updates" -Message "Disabling wuauserv service."
    Set-Service -Name wuauserv -StartupType Disabled

    Write-Host "Disabled UsoSvc Service."
    Write-WinUtilLog -Component "Updates" -Message "Stopping and disabling UsoSvc service."
    Stop-Service -Name UsoSvc -Force
    Set-Service -Name UsoSvc -StartupType Disabled

    Remove-Item "C:\Windows\SoftwareDistribution\*" -Recurse -Force
    Write-Host "Cleared SoftwareDistribution folder."
    Write-WinUtilLog -Component "Updates" -Message "Cleared SoftwareDistribution folder."

    Write-Host "Disabling update related scheduled tasks..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Disabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "---   Updates Are Disabled    ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "Note: You must restart your system in order for all changes to take effect." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow completed. Restart required."
}

function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Disables Windows Update automatic restart
        3. Sets Windows Update to Semi-Annual Channel (Targeted)
        4. Defers feature updates for 365 days
        5. Defers quality updates for 4 days

    #>

    Write-Host "Disabling driver offering through Windows Update..."
    Write-WinUtilLog -Component "Updates" -Message "Applying recommended Windows Update settings."
    Write-WinUtilLog -Component "Updates" -Message "Disabling driver offering through Windows Update."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "Setting cumulative updates back by 1 year and security updates by 4 days..."
    Write-WinUtilLog -Component "Updates" -Message "Deferring feature updates by 365 days and quality updates by 4 days."

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -Type DWord -Value 20
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    Write-Host "Disabling Windows Update automatic restart..."
    Write-WinUtilLog -Component "Updates" -Message "Disabling Windows Update automatic restart while users are logged in."

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Updates" -Message "Recommended Windows Update settings workflow completed."
}

$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "工具程式",
    "choco": "1password",
    "content": "1Password",
    "description": "1Password 是一款密碼管理器，可讓你安全地儲存與管理密碼。",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password",
    "foss": false
  },
  "WPFInstall7zip": {
    "category": "工具程式",
    "choco": "7zip",
    "content": "7-Zip",
    "description": "7-Zip 是一款免費且開源的檔案壓縮工具。它支援多種壓縮格式並提供高壓縮率，是廣受歡迎的檔案壓縮選擇。",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip",
    "foss": true
  },
  "WPFInstalladobe": {
    "category": "多媒體工具",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader",
    "description": "Adobe Acrobat Reader 是一款免費的 PDF 檢視器，具備檢視、列印與註解 PDF 文件的基本功能。",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit",
    "foss": false
  },
  "WPFInstalladvancedip": {
    "category": "Pro Tools",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner",
    "description": "Advanced IP Scanner 是一款快速且易用的網路掃描器。它專為分析區域網路而設計，並提供已連線裝置的相關資訊。",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner",
    "foss": false
  },
  "WPFInstallaimp": {
    "category": "多媒體工具",
    "choco": "aimp",
    "content": "AIMP (Music Player)",
    "description": "AIMP 是一款功能豐富的音樂播放器，支援多種音訊格式、播放清單與可自訂的使用者介面。",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP",
    "foss": false
  },
  "WPFInstallangryipscanner": {
    "category": "Pro Tools",
    "choco": "angryip",
    "content": "Angry IP Scanner",
    "description": "Angry IP Scanner 是一款開源且跨平台的網路掃描器。它用於掃描 IP 位址與連接埠，並提供網路連線的相關資訊。",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner",
    "foss": true
  },
  "WPFInstallanydesk": {
    "category": "工具程式",
    "choco": "anydesk",
    "content": "AnyDesk",
    "description": "AnyDesk 是一款遠端桌面軟體，可讓使用者遠端存取與控制電腦。它以連線快速、延遲低而聞名。",
    "link": "https://anydesk.com/",
    "winget": "AnyDesk.AnyDesk",
    "foss": false
  },
  "WPFInstallaudacity": {
    "category": "多媒體工具",
    "choco": "audacity",
    "content": "Audacity",
    "description": "Audacity 是一款免費且開源的音訊編輯軟體，以強大的錄音與編輯功能著稱。",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity",
    "foss": true
  },
  "WPFInstallautoruns": {
    "category": "Microsoft 工具",
    "choco": "autoruns",
    "content": "Autoruns",
    "description": "這個工具程式會顯示哪些程式被設定為在系統開機或登入時執行。",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns",
    "foss": false
  },
  "WPFInstallrdcman": {
    "category": "Microsoft 工具",
    "choco": "rdcman",
    "content": "RDCMan",
    "description": "RDCMan 可管理多個遠端桌面連線。適用於管理伺服器機房，例如自動簽到系統與資料中心等需要經常存取各台機器的情境。",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan",
    "foss": false
  },
  "WPFInstallautohotkey": {
    "category": "工具程式",
    "choco": "autohotkey",
    "content": "AutoHotkey",
    "description": "AutoHotkey 是一款 Windows 腳本語言，可讓使用者建立自訂的自動化腳本與巨集。它常用於自動化重複性工作與自訂鍵盤快速鍵。",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey",
    "foss": true
  },
  "WPFInstallbitwarden": {
    "category": "工具程式",
    "choco": "bitwarden",
    "content": "Bitwarden",
    "description": "Bitwarden 是一款開源的密碼管理解決方案。它可讓使用者將密碼存放在安全且加密的保險庫中，並可跨多台裝置存取。",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden",
    "foss": true
  },
  "WPFInstallblender": {
    "category": "多媒體工具",
    "choco": "blender",
    "content": "Blender (3D Graphics)",
    "description": "Blender 是一套強大的開源 3D 創作軟體，提供建模、雕刻、動畫與算圖工具。",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender",
    "foss": true
  },
  "WPFInstallbrave": {
    "category": "瀏覽器",
    "choco": "brave",
    "content": "Brave",
    "description": "Brave 是一款注重隱私的網頁瀏覽器，可封鎖廣告與追蹤器，提供更快速、更安全的瀏覽體驗。",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave",
    "foss": true
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "工具程式",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller",
    "description": "Bulk Crap Uninstaller 是一款免費且開源的 Windows 解除安裝工具。它可協助使用者一次解除安裝多個應用程式，移除不需要的程式並清理系統。",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller",
    "foss": true
  },
  "WPFInstallblurautoclicker": {
    "category": "工具程式",
    "choco": "na",
    "content": "BlurAutoClicker",
    "description": "一款自動點擊器，具備多項進階功能，效能普遍優於熱門的同類產品。",
    "link": "https://blur009.vercel.app/projects/blur-autoclicker/",
    "winget": "Blur009.BlurAutoClicker",
    "foss": true
  },
  "WPFInstallcalibre": {
    "category": "多媒體工具",
    "choco": "calibre",
    "content": "Calibre",
    "description": "Calibre 是一款強大且易用的電子書管理器、檢視器與轉檔工具。",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre",
    "foss": true
  },
  "WPFInstallcemu": {
    "category": "遊戲",
    "choco": "cemu",
    "content": "Cemu",
    "description": "Cemu 是一款高度實驗性的軟體，可在 PC 上模擬 Wii U 應用程式。",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu",
    "foss": true
  },
  "WPFInstallchatgpt": {
    "category": "開發",
    "choco": "na",
    "content": "ChatGPT Desktop",
    "description": "官方的 ChatGPT Windows 桌面應用程式，透過 Microsoft Store 發行。",
    "link": "https://apps.microsoft.com/detail/9nt1r1c2hh7j",
    "winget": "msstore:9NT1R1C2HH7J",
    "foss": false
  },
  "WPFInstallchatterino": {
    "category": "通訊",
    "choco": "chatterino",
    "content": "Chatterino",
    "description": "Chatterino 是一款 Twitch 聊天室用戶端，提供簡潔且可自訂的介面，帶來更佳的串流體驗。",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "瀏覽器",
    "choco": "googlechrome",
    "content": "Chrome",
    "description": "Google Chrome 是一款廣泛使用的網頁瀏覽器，以速度快、簡潔以及與 Google 服務無縫整合而聞名。",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome",
    "foss": false
  },
  "WPFInstallchromium": {
    "category": "瀏覽器",
    "choco": "chromium",
    "content": "Chromium",
    "description": "Chromium 是作為多款網頁瀏覽器（包括 Chrome）基礎的開源專案。",
    "link": "https://github.com/Hibbiki/chromium-win64",
    "winget": "Hibbiki.Chromium",
    "foss": true
  },
  "WPFInstallcinebenchr23": {
    "category": "Pro Tools",
    "choco": "na",
    "content": "Cinebench R23",
    "description": "Cinebench R23 是一款效能評測工具，用於比較不同系統間的 CPU 算圖效能。",
    "link": "https://www.maxon.net/en/cinebench",
    "winget": "Maxon.CinebenchR23",
    "foss": false
  },
  "WPFInstallclaude": {
    "category": "開發",
    "choco": "claude",
    "content": "Claude Desktop",
    "description": "Anthropic 的 Claude 桌面應用程式，用於專注的 AI 輔助工作與對話。",
    "link": "https://claude.ai/download",
    "winget": "Anthropic.Claude",
    "foss": false
  },
  "WPFInstallclaude-code": {
    "category": "開發",
    "choco": "claude-code",
    "content": "Claude Code",
    "description": "Anthropic 推出的代理式編碼工具，適用於終端機與 IDE 的開發工作流程。",
    "link": "https://code.claude.com/",
    "winget": "Anthropic.ClaudeCode",
    "foss": false
  },
  "WPFInstallcmake": {
    "category": "開發",
    "choco": "cmake",
    "content": "CMake",
    "description": "CMake 是一套開源、跨平台的工具集，專為建置、測試與封裝軟體而設計。",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake",
    "foss": true
  },
  "WPFInstallcodex": {
    "category": "開發",
    "choco": "codex",
    "content": "Codex",
    "description": "Codex CLI 是 OpenAI 的編碼代理，可在你的終端機本機執行。",
    "link": "https://developers.openai.com/codex/cli",
    "winget": "OpenAI.Codex",
    "foss": true
  },
  "WPFInstallcpuz": {
    "category": "Pro Tools",
    "choco": "cpu-z",
    "content": "CPU-Z",
    "description": "CPU-Z 是一款 Windows 系統監控與診斷工具。它提供電腦硬體元件的詳細資訊，包括 CPU、記憶體與主機板。",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z",
    "foss": false
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "工具程式",
    "choco": "crystaldiskinfo",
    "content": "Crystal Disk Info",
    "description": "Crystal Disk Info 是一款磁碟健康監控工具，可提供硬碟狀態與效能的資訊，協助使用者預先掌握潛在問題並監控磁碟健康狀況。",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo",
    "foss": true
  },
  "WPFInstallcrystaldiskmark": {
    "category": "工具程式",
    "choco": "crystaldiskmark",
    "content": "Crystal Disk Mark",
    "description": "Crystal Disk Mark 是一款磁碟效能測試工具，可測量儲存裝置的讀寫速度，協助使用者評估硬碟與 SSD 的效能。",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark",
    "foss": true
  },
  "WPFInstallcursor": {
    "category": "開發",
    "choco": "cursoride",
    "content": "Cursor",
    "description": "以 AI 驅動的程式碼編輯器（基於 VS Code），具備代理式編碼功能與整合式 AI 輔助，適用於開發工作流程。",
    "link": "https://cursor.com/",
    "winget": "Anysphere.Cursor",
    "foss": false
  },
  "WPFInstallddu": {
    "category": "Pro Tools",
    "choco": "ddu",
    "content": "Display Driver Uninstaller",
    "description": "Display Driver Uninstaller（DDU）是一款可徹底解除安裝 NVIDIA、AMD 與 Intel 顯示卡驅動程式的工具，適合用於排解顯示卡驅動程式相關問題。",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "Wagnardsoft.DisplayDriverUninstaller",
    "foss": true
  },
  "WPFInstalldiscord": {
    "category": "通訊",
    "choco": "discord",
    "content": "Discord",
    "description": "Discord 是一款熱門的通訊平台，提供語音、視訊與文字聊天，專為玩家設計，但廣泛用於各類社群。",
    "link": "https://discord.com/",
    "winget": "Discord.Discord",
    "foss": false
  },
  "WPFInstalldismtools": {
    "category": "Microsoft 工具",
    "choco": "dismtools",
    "content": "DISMTools",
    "description": "DISMTools 是一款快速且可自訂的 DISM 工具圖形介面，支援 Windows 7 以後的 Windows 映像。它可處理任何磁碟上的安裝、提供專案支援，並讓使用者調整色彩模式、語言與 DISM 版本等設定；由原生 DISM 與受管理的 DISM API 共同驅動。",
    "link": "https://github.com/CodingWonders/DISMTools",
    "winget": "CodingWondersSoftware.DISMTools.Stable",
    "foss": true
  },
  "WPFInstallntlite": {
    "category": "Microsoft 工具",
    "choco": "ntlite-free",
    "content": "NTLite",
    "description": "整合更新、驅動程式，自動化 Windows 與應用程式的安裝設定，加速 Windows 部署流程，並為下次使用預先準備妥當。",
    "link": "https://ntlite.com",
    "winget": "Nlitesoft.NTLite",
    "foss": false
  },
  "WPFInstalldorion": {
    "category": "通訊",
    "choco": "dorion",
    "content": "Dorion",
    "description": "輕巧的替代 Discord 用戶端，佔用空間更小、啟動更迅速，並支援主題、外掛程式等更多功能！",
    "link": "https://github.com/SpikeHD/Dorion",
    "winget": "SpikeHD.Dorion",
    "foss": true
  },
  "WPFInstalldotnet6": {
    "category": "Microsoft 工具",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET Desktop Runtime 6",
    "description": ".NET Desktop Runtime 6 是執行以 .NET 6 開發的應用程式所需的執行環境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6",
    "foss": true
  },
  "WPFInstalldotnet8": {
    "category": "Microsoft 工具",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET Desktop Runtime 8",
    "description": ".NET Desktop Runtime 8 是執行以 .NET 8 開發的應用程式所需的執行環境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8",
    "foss": true
  },
  "WPFInstalldotnet9": {
    "category": "Microsoft 工具",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET Desktop Runtime 9",
    "description": ".NET Desktop Runtime 9 是執行以 .NET 9 開發的應用程式所需的執行環境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9",
    "foss": true
  },
  "WPFInstalldotnet10": {
    "category": "Microsoft 工具",
    "choco": "dotnet-10.0-runtime",
    "content": ".NET Desktop Runtime 10",
    "description": ".NET Desktop Runtime 10 是執行以 .NET 10 開發的應用程式所需的執行環境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/10.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.10",
    "foss": true
  },
  "WPFInstalldropbox": {
    "category": "工具程式",
    "choco": "dropbox",
    "content": "Dropbox",
    "description": "Dropbox 是一款雲端儲存用戶端，可同步檔案、分享內容，並讓文件在各裝置間隨時可用。",
    "link": "https://www.dropbox.com/desktop",
    "winget": "Dropbox.Dropbox",
    "foss": false
  },
  "WPFInstalleaapp": {
    "category": "遊戲",
    "choco": "ea-app",
    "content": "EA App",
    "description": "EA App 是用於存取及遊玩 Electronic Arts 遊戲的平台。",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop",
    "foss": false
  },
  "WPFInstalleartrumpet": {
    "category": "多媒體工具",
    "choco": "eartrumpet",
    "content": "EarTrumpet (Audio)",
    "description": "EarTrumpet 是一款 Windows 音訊控制應用程式，提供簡單直覺的介面來管理音效設定。",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet",
    "foss": true
  },
  "WPFInstalledge": {
    "category": "瀏覽器",
    "choco": "microsoft-edge",
    "content": "Edge",
    "description": "Microsoft Edge 是一款以 Chromium 為基礎的現代網頁瀏覽器，提供優異的效能、安全性，並與 Microsoft 服務整合。",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge",
    "foss": false
  },
  "WPFInstallenteauth": {
    "category": "工具程式",
    "choco": "ente-auth",
    "content": "Ente Auth",
    "description": "Ente Auth 是一款免費、跨平台、端對端加密的驗證器應用程式。",
    "link": "https://ente.io/auth/",
    "winget": "ente-io.auth-desktop",
    "foss": true
  },
  "WPFInstallepicgames": {
    "category": "遊戲",
    "choco": "epicgameslauncher",
    "content": "Epic Games Launcher",
    "description": "Epic Games Launcher 是用於存取及遊玩 Epic Games Store 遊戲的用戶端。",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher",
    "foss": false
  },
  "WPFInstallfiles": {
    "category": "工具程式",
    "choco": "files",
    "content": "Files",
    "description": "替代的檔案總管。",
    "link": "https://github.com/files-community/Files",
    "winget": "FilesCommunity.Files",
    "foss": true
  },
  "WPFInstallfirefox": {
    "category": "瀏覽器",
    "choco": "firefox",
    "content": "Firefox",
    "description": "Mozilla Firefox 是一款開源網頁瀏覽器，以其自訂選項、隱私功能與擴充套件而聞名。",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallfirefoxesr": {
    "category": "瀏覽器",
    "choco": "FirefoxESR",
    "content": "Firefox ESR",
    "description": "Mozilla Firefox 是一款開源網頁瀏覽器，以其自訂選項、隱私功能與擴充套件而聞名。Firefox ESR（延伸支援版）每 42 週推出一次重大更新，並視需要提供當機修正、安全性修正與原則更新等小幅更新，但至少每四週更新一次。",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR",
    "foss": true
  },
  "WPFInstallfloorp": {
    "category": "瀏覽器",
    "choco": "floorp",
    "content": "Floorp",
    "description": "Floorp 是一個開放原始碼的網頁瀏覽器專案，旨在提供簡單又快速的瀏覽體驗。",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp",
    "foss": true
  },
  "WPFInstallflux": {
    "category": "工具程式",
    "choco": "flux",
    "content": "F.lux",
    "description": "f.lux 會調整螢幕的色溫，以減輕夜間使用時的眼睛疲勞。",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux",
    "foss": false
  },
  "WPFInstallgeforcenow": {
    "category": "遊戲",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW",
    "description": "GeForce NOW 是一項雲端遊戲服務，讓你在自己的裝置上遊玩高品質的 PC 遊戲。",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow",
    "foss": false
  },
  "WPFInstallgimp": {
    "category": "多媒體工具",
    "choco": "gimp",
    "content": "GIMP (Image Editor)",
    "description": "GIMP 是一款功能多元的開放原始碼點陣圖形編輯器，可用於相片修飾、影像編輯與影像合成等工作。",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP.3",
    "foss": true
  },
  "WPFInstallgit": {
    "category": "開發",
    "choco": "git",
    "content": "Git",
    "description": "Git 是一套分散式版本控制系統，廣泛用於在軟體開發過程中追蹤原始碼的變更。",
    "link": "https://git-scm.com/",
    "winget": "Git.Git",
    "foss": true
  },
  "WPFInstallgithubdesktop": {
    "category": "開發",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop",
    "description": "GitHub Desktop 是一款視覺化的 Git 用戶端，以易於使用的介面簡化 GitHub 儲存庫的協作。",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop",
    "foss": true
  },
  "WPFInstallgog": {
    "category": "遊戲",
    "choco": "goggalaxy",
    "content": "GOG Galaxy",
    "description": "GOG Galaxy 是一款遊戲用戶端，提供無 DRM 遊戲、額外內容等。",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy",
    "foss": false
  },
  "WPFInstallgolang": {
    "category": "開發",
    "choco": "golang",
    "content": "Go",
    "description": "Go（或稱 Golang）是一種靜態型別的編譯式程式語言，設計著重於簡潔、可靠與效率。",
    "link": "https://go.dev/",
    "winget": "GoLang.Go",
    "foss": true
  },
  "WPFInstallgoogledrive": {
    "category": "工具程式",
    "choco": "googledrive",
    "content": "Google Drive",
    "description": "跨裝置同步檔案，全部繫結至你的 Google 帳戶。",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive",
    "foss": false
  },
  "WPFInstallgpuz": {
    "category": "Pro Tools",
    "choco": "gpu-z",
    "content": "GPU-Z",
    "description": "GPU-Z 提供顯示卡與 GPU 的詳細資訊。",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z",
    "foss": false
  },
  "WPFInstallhelium": {
    "category": "瀏覽器",
    "choco": "helium",
    "content": "Helium",
    "description": "注重隱私、快速且誠實的網頁瀏覽器。",
    "link": "https://github.com/imputnet/helium/",
    "winget": "ImputNet.Helium",
    "foss": true
  },
  "WPFInstallhugo": {
    "category": "工具程式",
    "choco": "hugo-extended",
    "content": "Hugo",
    "description": "全世界最快的網站建置框架。",
    "link": "https://github.com/gohugoio/hugo/",
    "winget": "Hugo.Hugo.Extended",
    "foss": true
  },
  "WPFInstallhandbrake": {
    "category": "多媒體工具",
    "choco": "handbrake",
    "content": "HandBrake",
    "description": "HandBrake 是一款開源影片轉檔工具，可將幾乎任何格式的影片轉換為多種廣泛支援的編碼格式。",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake",
    "foss": true
  },
  "WPFInstallheroiclauncher": {
    "category": "遊戲",
    "choco": "heroic-games-launcher",
    "content": "Heroic Games Launcher",
    "description": "Heroic Games Launcher 是 Epic Games Store 的開源替代遊戲啟動器。",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher",
    "foss": true
  },
  "WPFInstallhwinfo": {
    "category": "Pro Tools",
    "choco": "hwinfo",
    "content": "HWiNFO",
    "description": "HWiNFO 為 Windows 提供完整的硬體資訊與診斷功能。",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO",
    "foss": false
  },
  "WPFInstallhwmonitor": {
    "category": "Pro Tools",
    "choco": "hwmonitor",
    "content": "HWMonitor",
    "description": "HWMonitor 是一款硬體監控程式，可讀取電腦系統的主要健康感測器數據。",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor",
    "foss": false
  },
  "WPFInstallimageglass": {
    "category": "多媒體工具",
    "choco": "imageglass",
    "content": "ImageGlass (Image Viewer)",
    "description": "ImageGlass 是一款多功能的影像檢視器，支援多種影像格式，並著重於簡潔與速度。",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass",
    "foss": true
  },
  "WPFInstallinternetdownloadmanager": {
    "category": "工具程式",
    "choco": "internet-download-manager",
    "content": "Internet Download Manager",
    "description": "Internet Download Manager 是一款下載管理工具，可加速、續傳並排程檔案下載。",
    "link": "https://www.internetdownloadmanager.com/",
    "winget": "Tonec.InternetDownloadManager",
    "foss": false
  },
  "WPFInstallirfanview": {
    "category": "多媒體工具",
    "choco": "irfanview",
    "content": "IrfanView",
    "description": "IrfanView 是一款輕巧、快速且免費的影像檢視與編輯器，支援多種格式、批次處理與強大的外掛。",
    "link": "https://irfanview.com/",
    "winget": "IrfanSkiljan.IrfanView",
    "foss": false
  },
  "WPFInstallitch": {
    "category": "遊戲",
    "choco": "itch",
    "content": "Itch.io",
    "description": "Itch.io 是一個專為獨立遊戲與創意作品打造的數位發行平台。",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch",
    "foss": true
  },
  "WPFInstallitunes": {
    "category": "多媒體工具",
    "choco": "itunes",
    "content": "iTunes",
    "description": "iTunes 是 Apple Inc. 開發的媒體播放器、媒體庫與線上廣播應用程式。",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes",
    "foss": false
  },
  "WPFInstalljava8": {
    "category": "開發",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS)",
    "description": "Amazon Corretto 是免費、跨平台且可用於正式環境的 Open Java Development Kit（OpenJDK）發行版。",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK",
    "foss": true
  },
  "WPFInstalljava21": {
    "category": "開發",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS)",
    "description": "Amazon Corretto 是免費、跨平台且可用於正式環境的 Open Java Development Kit（OpenJDK）發行版。",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK",
    "foss": true
  },
  "WPFInstalljava25": {
    "category": "開發",
    "choco": "corretto25jdk",
    "content": "Amazon Corretto 25 (LTS)",
    "description": "Amazon Corretto 是免費、跨平台且可用於正式環境的 Open Java Development Kit（OpenJDK）發行版。",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.25.JDK",
    "foss": true
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "自架工具",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin Media Player",
    "description": "Jellyfin Media Player 是 Jellyfin 媒體伺服器的用戶端應用程式，可讓你存取自己的媒體庫。",
    "link": "https://github.com/jellyfin/jellyfin-media-player",
    "winget": "Jellyfin.JellyfinMediaPlayer",
    "foss": true
  },
  "WPFInstalljellyfinserver": {
    "category": "自架工具",
    "choco": "jellyfin",
    "content": "Jellyfin Server",
    "description": "Jellyfin Server 是一款開源媒體伺服器軟體，可讓你整理並串流自己的媒體庫。",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server",
    "foss": true
  },
  "WPFInstalljetbrains": {
    "category": "開發",
    "choco": "jetbrainstoolbox",
    "content": "Jetbrains Toolbox",
    "description": "Jetbrains Toolbox 是一個可輕鬆安裝與管理 JetBrains 開發工具的平台。",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox",
    "foss": false
  },
  "WPFInstalljpegview": {
    "category": "工具程式",
    "choco": "jpegview",
    "content": "JPEG View",
    "description": "JPEGView 是一款精簡、快速且高度可自訂的影像檢視/編輯器，支援 JPEG、BMP、PNG、WEBP、TGA、GIF、JXL、HEIC、HEIF、AVIF 與 TIFF 影像，並具備極簡的介面。",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView",
    "foss": true
  },
  "WPFInstallkeepassxc": {
    "category": "工具程式",
    "choco": "keepassxc",
    "content": "KeePassXC",
    "description": "KeePassXC 是一款現代、安全的開源密碼管理器，可儲存與管理你最敏感的資訊。KeePassXC 可在 Windows、macOS 與 Linux 系統上執行。KeePassXC 適合對個人資料安全管理有極高要求的使用者，能將使用者名稱、密碼、URL、附件與備註等多種資訊儲存在離線加密的檔案中，該檔案可存放於任何位置，包括私有雲與公有雲方案。為方便辨識與管理，可為各項目指定自訂標題與圖示；此外，項目還可依可自訂的群組分類。內建的搜尋功能可讓你運用進階模式輕鬆找到資料庫中的任何項目。可自訂、快速且易用的密碼產生器工具，可讓你以任意字元組合建立密碼，或產生容易記憶的複合密語。",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC",
    "foss": true
  },
  "WPFInstallklite": {
    "category": "多媒體工具",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite Codec Standard",
    "description": "K-Lite Codec Pack Standard 是一套音訊與視訊編解碼器及相關工具的集合，提供媒體播放所需的必要元件。",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard",
    "foss": false
  },
  "WPFInstallkodi": {
    "category": "自架工具",
    "choco": "kodi",
    "content": "Kodi Media Center",
    "description": "Kodi 是一款開源媒體中心應用程式，可讓你播放與檢視大多數的影片、音樂、Podcast 及其他數位媒體檔案。",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi",
    "foss": true
  },
  "WPFInstalllazygit": {
    "category": "開發",
    "choco": "lazygit",
    "content": "Lazygit",
    "description": "簡潔的 git 指令終端機介面。",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit",
    "foss": true
  },
  "WPFInstalllibreoffice": {
    "category": "多媒體工具",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice",
    "description": "LibreOffice 是一套功能強大的免費辦公軟體，並與其他主流辦公軟體相容。",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice",
    "foss": true
  },
  "WPFInstalllibrewolf": {
    "category": "瀏覽器",
    "choco": "librewolf",
    "content": "LibreWolf",
    "description": "LibreWolf 是一款以隱私為重的網頁瀏覽器，以 Firefox 為基礎，並加入額外的隱私與安全強化功能。",
    "link": "https://librewolf-community.gitlab.io/",
    "winget": "LibreWolf.LibreWolf",
    "foss": true
  },
  "WPFInstalllocalsend": {
    "category": "自架工具",
    "choco": "localsend.install",
    "content": "LocalSend",
    "description": "開源的跨平台 AirDrop 替代方案。",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend",
    "foss": true
  },
  "WPFInstallmpc-qt": {
    "category": "多媒體工具",
    "choco": "mediainfo",
    "content": "mpc-qt",
    "description": "Media Player Classic Qute Theater",
    "link": "https://github.com/mpc-qt/mpc-qt",
    "winget": "mpc-qt.mpc-qt",
    "foss": true
  },
  "WPFInstallmatrix": {
    "category": "通訊",
    "choco": "element-desktop",
    "content": "Element",
    "description": "Element 是 Matrix 的用戶端；Matrix 是一個提供安全、去中心化通訊的開放網路。",
    "link": "https://element.io/",
    "winget": "Element.Element",
    "foss": true
  },
  "WPFInstallminitoolpartitionwizard": {
    "category": "工具程式",
    "choco": "minitoolpartitionwizard",
    "content": "MiniTool Partition Wizard",
    "description": "功能完整的免費磁碟分割管理器，可執行 Windows 原生無法進行的進階操作，例如合併分割區、轉換檔案系統與整理磁碟容量。",
    "link": "https://www.partitionwizard.com/",
    "winget": "MiniTool.PartitionWizard.Free",
    "foss": false
  },
  "WPFInstallmodrinth": {
    "category": "遊戲",
    "choco": "modrinth-app",
    "content": "Modrinth App",
    "description": "Modrinth App 是一款桌面應用程式，用於管理 Minecraft 模組與模組包。",
    "link": "https://modrinth.com/app",
    "winget": "Modrinth.ModrinthApp",
    "foss": true
  },
  "WPFInstallmoonlight": {
    "category": "自架工具",
    "choco": "moonlight-qt",
    "content": "Moonlight/GameStream Client",
    "description": "Moonlight/GameStream 用戶端可讓你透過本機網路將電腦遊戲串流至其他裝置。",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight",
    "foss": true
  },
  "WPFInstallmpchc": {
    "category": "多媒體工具",
    "choco": "mpc-hc-clsid2",
    "content": "Media Player Classic - Home Cinema",
    "description": "Media Player Classic - Home Cinema (MPC-HC) 是一款適用於 Windows 的免費開源影音播放器。MPC-HC 以原始的 Guliverkli 專案為基礎，並包含許多額外功能與錯誤修正。",
    "link": "https://github.com/clsid2/mpc-hc/",
    "winget": "clsid2.mpc-hc",
    "foss": true
  },
  "WPFInstallmsedgeredirect": {
    "category": "工具程式",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect",
    "description": "可將新聞、搜尋、小工具、天氣等重新導向至你預設瀏覽器的工具。",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect",
    "foss": true
  },
  "WPFInstallmsiafterburner": {
    "category": "工具程式",
    "choco": "msiafterburner",
    "content": "MSI Afterburner",
    "description": "MSI Afterburner 是一款具備進階功能的顯示卡超頻工具。",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner",
    "foss": false
  },
  "WPFInstallmullvadvpn": {
    "category": "Pro Tools",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "這是 Mullvad VPN 服務的 VPN 用戶端軟體。",
    "link": "https://github.com/mullvad/mullvadvpn-app",
    "winget": "MullvadVPN.MullvadVPN",
    "foss": true
  },
  "WPFInstallmullvadbrowser": {
    "category": "瀏覽器",
    "choco": "na",
    "content": "Mullvad Browser",
    "description": "Mullvad Browser 是一款以隱私為重的網頁瀏覽器，由 Tor Project 合作開發。",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser",
    "foss": true
  },
  "WPFInstallnomacs": {
    "category": "多媒體工具",
    "choco": "nomacs",
    "content": "nomacs",
    "description": "nomacs 是一款免費、開放原始碼的跨平台影像檢視器。可用於檢視所有常見的影像格式，包括 RAW 與 .psd 影像。",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs",
    "foss": true
  },
  "WPFInstallnanazip": {
    "category": "工具程式",
    "choco": "nanazip",
    "content": "NanaZip",
    "description": "NanaZip 是一款快速且高效率的檔案壓縮與解壓縮工具。",
    "link": "https://github.com/M2Team/NanaZip",
    "winget": "M2Team.NanaZip",
    "foss": true
  },
  "WPFInstallnetbird": {
    "category": "自架工具",
    "choco": "netbird",
    "content": "NetBird",
    "description": "NetBird 是可媲美 TailScale 的開源替代方案，可連線至自架伺服器。",
    "link": "https://netbird.io/",
    "winget": "Netbird.Netbird",
    "foss": true
  },
  "WPFInstallnaps2": {
    "category": "多媒體工具",
    "choco": "naps2",
    "content": "NAPS2 (Document Scanner)",
    "description": "NAPS2 是一款文件掃描應用程式，可簡化建立電子文件的流程。",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2",
    "foss": true
  },
  "WPFInstallneovim": {
    "category": "開發",
    "choco": "neovim",
    "content": "Neovim",
    "description": "Neovim 是一款高度可擴充的文字編輯器，是原始 Vim 編輯器的改良版。",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim",
    "foss": true
  },
  "WPFInstallnextclouddesktop": {
    "category": "自架工具",
    "choco": "nextcloud-client",
    "content": "Nextcloud Desktop",
    "description": "Nextcloud Desktop 是 Nextcloud 檔案同步與分享平台的官方桌面用戶端。",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop",
    "foss": true
  },
  "WPFInstallnmap": {
    "category": "Pro Tools",
    "choco": "nmap",
    "content": "Nmap",
    "description": "Nmap（Network Mapper）是一款用於網路探索與資安稽核的開放原始碼工具。它可探索網路上的裝置，並提供其連接埠與服務的相關資訊。",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap",
    "foss": true
  },
  "WPFInstallnodejs": {
    "category": "開發",
    "choco": "nodejs",
    "content": "NodeJS",
    "description": "NodeJS 是建構在 Chrome V8 JavaScript 引擎上的 JavaScript 執行環境，用於建置伺服器端與網路應用程式。",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallnodejslts": {
    "category": "開發",
    "choco": "nodejs-lts",
    "content": "NodeJS LTS",
    "description": "NodeJS LTS 提供長期支援（LTS）版本，適合穩定可靠的伺服器端 JavaScript 開發。",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS",
    "foss": true
  },
  "WPFInstallpnpm": {
    "category": "開發",
    "content": "pnpm",
    "description": "pnpm 是一款快速且節省磁碟空間的套件管理器，適用於 JavaScript 與 Node.js 應用程式。",
    "link": "https://pnpm.io/",
    "winget": "pnpm.pnpm",
    "foss": true
  },
  "WPFInstallnotepadplus": {
    "category": "多媒體工具",
    "choco": "notepadplusplus",
    "content": "Notepad++",
    "description": "Notepad++ 是一款免費、開放原始碼的程式碼編輯器，可取代記事本，並支援多種語言。",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++",
    "foss": true
  },
  "WPFInstallnuget": {
    "category": "Microsoft 工具",
    "choco": "nuget.commandline",
    "content": "NuGet",
    "description": "NuGet 是 .NET Framework 的套件管理器，讓開發者能在 .NET 應用程式中管理與分享程式庫。",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet",
    "foss": true
  },
  "WPFInstallnvclean": {
    "category": "工具程式",
    "choco": "na",
    "content": "NVCleanstall",
    "description": "NVCleanstall 是一款可自訂 NVIDIA 驅動程式安裝的工具，讓進階使用者能掌控安裝過程中的更多細節。",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall",
    "foss": false
  },
  "WPFInstallobs": {
    "category": "多媒體工具",
    "choco": "obs-studio",
    "content": "OBS Studio",
    "description": "OBS Studio 是一款免費、開放原始碼的影片錄製與直播軟體。支援即時影音擷取與混音，深受內容創作者歡迎。",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio",
    "foss": true
  },
  "WPFInstallobsidian": {
    "category": "多媒體工具",
    "choco": "obsidian",
    "content": "Obsidian",
    "description": "Obsidian 是一款功能強大的筆記與知識管理應用程式。",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian",
    "foss": false
  },
  "WPFInstallonedrive": {
    "category": "Microsoft 工具",
    "choco": "onedrive",
    "content": "OneDrive",
    "description": "OneDrive 是 Microsoft 提供的雲端儲存服務，讓使用者能在各裝置間安全地儲存與分享檔案。",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive",
    "foss": false
  },
  "WPFInstallonlyoffice": {
    "category": "多媒體工具",
    "choco": "onlyoffice",
    "content": "ONLYOFFICE Desktop",
    "description": "ONLYOFFICE Desktop 是一套完整的辦公軟體，用於文件編輯與協作。",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors",
    "foss": true
  },
  "WPFInstallOPAutoClicker": {
    "category": "工具程式",
    "choco": "autoclicker",
    "content": "OPAutoClicker",
    "description": "功能完整的自動點擊器，提供兩種點擊模式：跟隨游標動態位置點擊，或於預先指定的位置點擊。",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker",
    "foss": false
  },
  "WPFInstallopenrgb": {
    "category": "工具程式",
    "choco": "openrgb",
    "content": "OpenRGB",
    "description": "OpenRGB 是一款開放原始碼的 RGB 燈光控制軟體，用於管理與控制各種零組件及周邊裝置的 RGB 燈光。",
    "link": "https://openrgb.org/",
    "winget": "OpenRGB.OpenRGB",
    "foss": true
  },
  "WPFInstallOpenVPN": {
    "category": "Pro Tools",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect",
    "description": "OpenVPN Connect 是一款 VPN 用戶端，讓你能安全地連線至 VPN 伺服器。它提供安全加密的連線，保護你的線上隱私。",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect",
    "foss": false
  },
  "WPFInstallOVirtualBox": {
    "category": "工具程式",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox",
    "description": "Oracle VirtualBox 是一款功能強大且免費的開放原始碼虛擬化工具，支援 x86 與 AMD64/Intel64 架構。",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox",
    "foss": true
  },
  "WPFInstallpolicyplus": {
    "category": "工具程式",
    "choco": "na",
    "content": "Policy Plus",
    "description": "本機群組原則編輯器及更多功能，適用於所有 Windows 版本。",
    "link": "https://github.com/Fleex255/PolicyPlus",
    "winget": "Fleex255.PolicyPlus",
    "foss": true
  },
  "WPFInstallprocessexplorer": {
    "category": "Microsoft 工具",
    "choco": "procexp",
    "content": "Process Explorer",
    "description": "Process Explorer 是一款工作管理員與系統監視器。",
    "link": "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
    "winget": "Microsoft.Sysinternals.ProcessExplorer",
    "foss": false
  },
  "WPFInstallPaintdotnet": {
    "category": "多媒體工具",
    "choco": "paint.net",
    "content": "Paint.NET",
    "description": "Paint.NET 是一款適用於 Windows 的免費影像與相片編輯軟體。介面直覺，並支援多種功能強大的編輯工具。",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet",
    "foss": false
  },
  "WPFInstallparsec": {
    "category": "工具程式",
    "choco": "parsec",
    "content": "Parsec",
    "description": "Parsec 是一款低延遲、高畫質的遠端桌面分享應用程式，可用於跨裝置協作與遊戲。",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec",
    "foss": false
  },
  "WPFInstallpeazip": {
    "category": "工具程式",
    "choco": "peazip",
    "content": "PeaZip",
    "description": "PeaZip 是一款免費、開放原始碼的檔案壓縮工具，支援多種壓縮格式並提供加密功能。",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip",
    "foss": true
  },
  "WPFInstallplaynite": {
    "category": "遊戲",
    "choco": "playnite",
    "content": "Playnite",
    "description": "Playnite 是一款開放原始碼的電玩遊戲庫管理器，目標很單純：為你所有的遊戲提供統一的介面。",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite",
    "foss": true
  },
  "WPFInstallplex": {
    "category": "自架工具",
    "choco": "plexmediaserver",
    "content": "Plex Media Server",
    "description": "Plex Media Server 是一款媒體伺服器軟體，讓你能整理並串流你的媒體庫。它支援多種媒體格式並提供豐富的功能。",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer",
    "foss": false
  },
  "WPFInstallplexdesktop": {
    "category": "自架工具",
    "choco": "plex",
    "content": "Plex Desktop",
    "description": "Plex Desktop for Windows 是 Plex Media Server 的前端介面。",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex",
    "foss": false
  },
  "WPFInstallposh": {
    "category": "開發",
    "choco": "oh-my-posh",
    "content": "Oh My Posh (Prompt)",
    "description": "Oh My Posh 是一款跨平台的提示字元主題引擎，適用於任何 shell。",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh",
    "foss": true
  },
  "WPFInstallpowershell": {
    "category": "Microsoft 工具",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell 是專為系統管理員設計的工作自動化框架與指令碼語言，提供強大的命令列功能。",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallpowertoys": {
    "category": "Microsoft 工具",
    "choco": "powertoys",
    "content": "PowerToys",
    "description": "PowerToys 是一組供進階使用者提升生產力的公用程式，內含 FancyZones、PowerRename 等工具。",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys",
    "foss": true
  },
  "WPFInstallprismlauncher": {
    "category": "遊戲",
    "choco": "prismlauncher",
    "content": "Prism Launcher",
    "description": "Prism Launcher 是一款開放原始碼的 Minecraft 啟動器，能管理多個執行個體、帳號與模組。",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher",
    "foss": true
  },
  "WPFInstallprocesslasso": {
    "category": "工具程式",
    "choco": "plasso",
    "content": "Process Lasso",
    "description": "Process Lasso 是一款系統最佳化與自動化工具，透過調整處理程序優先順序與 CPU 親和性，改善系統的回應速度與穩定性。",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso",
    "foss": false
  },
  "WPFInstallprotonauth": {
    "category": "工具程式",
    "choco": "protonauth",
    "content": "Proton Authenticator",
    "description": "Proton 推出的雙重驗證 App，可安全同步與備份 2FA 驗證碼。",
    "link": "https://proton.me/authenticator",
    "winget": "Proton.ProtonAuthenticator",
    "foss": true
  },
  "WPFInstallprotonmail": {
    "category": "通訊",
    "choco": "protonmail",
    "content": "Proton Mail",
    "description": "Proton Mail 是 Proton 推出的端對端加密電子郵件服務，以零存取加密保護你的隱私。",
    "link": "https://proton.me/mail",
    "winget": "Proton.ProtonMail",
    "foss": true
  },
  "WPFInstallprotondrive": {
    "category": "工具程式",
    "choco": "protondrive",
    "content": "Proton Drive",
    "description": "Proton Drive 是一個端對端加密的瑞士檔案保險庫，保護你的資料。",
    "link": "https://proton.me/drive",
    "winget": "Proton.ProtonDrive",
    "foss": true
  },
  "WPFInstallprotonpass": {
    "category": "工具程式",
    "choco": "protonpass",
    "content": "Proton Pass",
    "description": "Proton Pass 是一款雲端密碼管理器，具備端對端加密與獨特的電子郵件別名功能。",
    "link": "https://proton.me/pass",
    "winget": "Proton.ProtonPass",
    "foss": true
  },
  "WPFInstallprotonvpn": {
    "category": "Pro Tools",
    "choco": "protonvpn",
    "content": "Proton VPN",
    "description": "Proton VPN 是一款不記錄日誌的 VPN 服務，以 Secure Core 及 Tor over VPN 等功能保護你的線上隱私。",
    "link": "https://protonvpn.com/",
    "winget": "Proton.ProtonVPN",
    "foss": true
  },
  "WPFInstallprocessmonitor": {
    "category": "Microsoft 工具",
    "choco": "procexp",
    "content": "Process Monitor",
    "description": "SysInternals Process Monitor 是進階監控工具，可即時顯示檔案系統、登錄檔以及處理程序／執行緒的活動。",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor",
    "foss": false
  },
  "WPFInstallputty": {
    "category": "Pro Tools",
    "choco": "putty",
    "content": "PuTTY",
    "description": "PuTTY 是一款免費、開放原始碼的終端機模擬器、序列主控台與網路檔案傳輸應用程式。支援 SSH、Telnet、SCP 等多種網路通訊協定。",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY",
    "foss": true
  },
  "WPFInstallpython3": {
    "category": "開發",
    "choco": "python",
    "content": "Python3",
    "description": "Python 是一款多用途的程式語言，可用於網頁開發、資料分析、人工智慧等領域。",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.14",
    "foss": true
  },
  "WPFInstallqbittorrent": {
    "category": "工具程式",
    "choco": "qbittorrent",
    "content": "qBittorrent",
    "description": "qBittorrent 是一款免費、開放原始碼的 BitTorrent 用戶端，旨在提供功能豐富且輕量的種子下載替代方案。",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent",
    "foss": true
  },
  "WPFInstallqtox": {
    "category": "通訊",
    "choco": "qtox",
    "content": "QTox",
    "description": "QTox 是一款免費、開放原始碼的訊息應用程式，設計上以使用者隱私與安全為優先。",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox",
    "foss": true
  },
  "WPFInstallrevo": {
    "category": "工具程式",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller",
    "description": "Revo Uninstaller 是進階的解除安裝工具，協助你移除不需要的軟體並清理系統。",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller",
    "foss": false
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "工具程式",
    "choco": "na",
    "content": "Wise Program Uninstaller (WiseCleaner)",
    "description": "Wise Program Uninstaller 是解除安裝 Windows 程式的理想方案，透過其簡潔易用的介面，讓你快速且徹底地解除安裝應用程式。",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller",
    "foss": false
  },
  "WPFInstallrufus": {
    "category": "工具程式",
    "choco": "rufus",
    "content": "Rufus Imager",
    "description": "Rufus 是協助格式化與建立可開機 USB 隨身碟（如 USB 隨身碟或隨身碟）的工具程式。",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus",
    "foss": true
  },
  "WPFInstallrustlang": {
    "category": "開發",
    "choco": "rust",
    "content": "Rust",
    "description": "Rust 是專為安全性與效能設計的程式語言，特別著重於系統程式開發。",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC",
    "foss": true
  },
  "WPFInstallsdio": {
    "category": "工具程式",
    "choco": "sdio",
    "content": "Snappy Driver Installer Origin",
    "description": "Snappy Driver Installer Origin 是免費且開放原始碼的驅動程式更新工具，內建龐大的 Windows 驅動程式資料庫。",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin",
    "foss": true
  },
  "WPFInstallsharex": {
    "category": "多媒體工具",
    "choco": "sharex",
    "content": "ShareX (Screenshots)",
    "description": "ShareX 是免費且開放原始碼的螢幕擷取與檔案分享工具。它支援多種擷取方式，並提供編輯與分享螢幕擷取畫面的進階功能。",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX",
    "foss": true
  },
  "WPFInstallnilesoftShell": {
    "category": "工具程式",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell",
    "description": "Shell 是擴充的右鍵選單工具，為 Windows 右鍵選單新增額外功能與自訂選項。",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell",
    "foss": false
  },
  "WPFInstallsysteminformer": {
    "category": "開發",
    "choco": "systeminformer",
    "content": "System Informer",
    "description": "一款免費、強大的多用途工具，可協助你監控系統資源、除錯軟體與偵測惡意程式。",
    "link": "https://systeminformer.com/",
    "winget": "WinsiderSS.SystemInformer",
    "foss": true
  },
  "WPFInstallsignal": {
    "category": "通訊",
    "choco": "signal",
    "content": "Signal",
    "description": "Signal 是注重隱私的通訊軟體，提供端對端加密以確保安全私密的通訊。",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal",
    "foss": true
  },
  "WPFInstallsignalrgb": {
    "category": "工具程式",
    "choco": "na",
    "content": "SignalRGB",
    "description": "SignalRGB 讓你用一個免費應用程式控制並同步你喜愛的 RGB 裝置。",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb",
    "foss": false
  },
  "WPFInstallsimplewall": {
    "category": "Pro Tools",
    "choco": "simplewall",
    "content": "Simplewall",
    "description": "Simplewall 是免費且開放原始碼的 Windows 防火牆應用程式。它讓使用者控制並管理應用程式的傳入與傳出網路流量。",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall",
    "foss": true
  },
  "WPFInstallslack": {
    "category": "通訊",
    "choco": "slack",
    "content": "Slack",
    "description": "Slack 是協作中樞，透過頻道、訊息與檔案分享連結團隊並促進溝通。",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack",
    "foss": false
  },
  "WPFInstallstartallback": {
    "category": "工具程式",
    "choco": "StartAllBack",
    "content": "StartAllBack",
    "description": "StartAllBack 還原並改善 Windows 工作列、開始功能表、File Explorer 與 shell 介面的操作行為。",
    "link": "https://www.startallback.com/",
    "winget": "StartIsBack.StartAllBack",
    "foss": false
  },
  "WPFInstallsteam": {
    "category": "遊戲",
    "choco": "steam-client",
    "content": "Steam",
    "description": "Steam 是購買與遊玩電子遊戲的數位發行平台，提供多人遊戲、影片串流等功能。",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam",
    "foss": false
  },
  "WPFInstallsublimetext": {
    "category": "開發",
    "choco": "sublimetext4",
    "content": "Sublime Text",
    "description": "Sublime Text 是功能精緻的文字編輯器，適用於程式碼、標記語言與文稿撰寫。",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4",
    "foss": false
  },
  "WPFInstallsunshine": {
    "category": "自架工具",
    "choco": "sunshine",
    "content": "Sunshine/GameStream Server",
    "description": "Sunshine 是 GameStream 伺服器，讓你在 Android 裝置上遠端遊玩 PC 遊戲，提供低延遲串流。",
    "link": "https://github.com/LizardByte/Sunshine",
    "winget": "LizardByte.Sunshine",
    "foss": true
  },
  "WPFInstalltcpview": {
    "category": "Microsoft 工具",
    "choco": "tcpview",
    "content": "TCPView",
    "description": "SysInternals TCPView 是網路監控工具，可顯示系統上所有 TCP 與 UDP 端點的詳細清單。",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView",
    "foss": false
  },
  "WPFInstallteams": {
    "category": "通訊",
    "choco": "microsoft-teams",
    "content": "Teams",
    "description": "Microsoft Teams 是一個協作平台，整合 Office 365，並提供聊天、視訊會議、檔案分享等功能。",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams",
    "foss": false
  },
  "WPFInstallteamviewer": {
    "category": "工具程式",
    "choco": "teamviewer9",
    "content": "TeamViewer",
    "description": "TeamViewer 是熱門的遠端存取與支援軟體，讓你連線並控制遠端裝置。",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer",
    "foss": false
  },
  "WPFInstallteamspeak3": {
    "category": "通訊",
    "choco": "teamspeak",
    "content": "TeamSpeak 3",
    "description": "TEAMSPEAK。你的團隊。你的規則。以清晰無比的音質跨平台與隊友溝通，具備軍規級安全性、無延遲的效能，以及無與倫比的可靠度與運作時間。",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient",
    "foss": false
  },
  "WPFInstalltelegram": {
    "category": "通訊",
    "choco": "telegram",
    "content": "Telegram",
    "description": "Telegram 是雲端即時通訊軟體，以其安全功能、速度與簡潔著稱。",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop",
    "foss": true
  },
  "WPFInstallterminal": {
    "category": "Microsoft 工具",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal",
    "description": "Windows Terminal 是一款現代、快速且高效的終端機應用程式，供命令列使用者使用，支援多重分頁、窗格等功能。",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstallthunderbird": {
    "category": "通訊",
    "choco": "thunderbird",
    "content": "Thunderbird",
    "description": "Mozilla Thunderbird 是一款免費開源的電子郵件、新聞群組與聊天用戶端，具備多項進階功能。",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird",
    "foss": true
  },
  "WPFInstallbetterbird": {
    "category": "通訊",
    "choco": "betterbird",
    "content": "Betterbird",
    "description": "Betterbird 是 Mozilla Thunderbird 的分支，加入了額外功能與錯誤修正。",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird",
    "foss": true
  },
  "WPFInstalltor": {
    "category": "瀏覽器",
    "choco": "tor-browser",
    "content": "Tor Browser",
    "description": "Tor Browser 專為匿名瀏覽網頁而設計，利用 Tor 網路保護使用者的隱私與安全。",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser",
    "foss": true
  },
  "WPFInstalltotalcommander": {
    "category": "工具程式",
    "choco": "TotalCommander",
    "content": "Total Commander",
    "description": "Total Commander 是 Windows 的檔案管理員，提供強大且直覺的檔案管理介面。",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander",
    "foss": false
  },
  "WPFInstalltreesize": {
    "category": "工具程式",
    "choco": "treesizefree",
    "content": "TreeSize Free",
    "description": "TreeSize Free 是一款磁碟空間管理工具，協助你分析並視覺化磁碟的空間使用情形。",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free",
    "foss": false
  },
  "WPFInstallttaskbar": {
    "category": "工具程式",
    "choco": "translucenttb",
    "content": "TranslucentTB",
    "description": "TranslucentTB 是一款可讓你自訂 Windows 工作列透明度的工具。",
    "link": "https://github.com/TranslucentTB/TranslucentTB",
    "winget": "CharlesMilette.TranslucentTB",
    "foss": true
  },
  "WPFInstallubisoft": {
    "category": "遊戲",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect",
    "description": "Ubisoft Connect 是 Ubisoft 的數位發行與線上遊戲服務，可存取 Ubisoft 的遊戲與服務。",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect",
    "foss": false
  },
  "WPFInstallungoogled": {
    "category": "瀏覽器",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled Chromium",
    "description": "Ungoogled Chromium 是移除 Google 整合的 Chromium 版本，以增強隱私與掌控權。",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium",
    "foss": true
  },
  "WPFInstallunity": {
    "category": "開發",
    "choco": "unityhub",
    "content": "Unity Game Engine",
    "description": "Unity 是強大的遊戲開發平台，可用於製作 2D、3D、擴增實境與虛擬實境遊戲。",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub",
    "foss": false
  },
  "WPFInstalleverything": {
    "category": "工具程式",
    "choco": "everything",
    "content": "Everything",
    "description": "Everything 是一款 Windows 搜尋引擎，可依檔名即時定位檔案與資料夾。與 Windows 搜尋不同，Everything 一開始會顯示電腦上的每個檔案與資料夾（因此得名 Everything）。你可輸入搜尋條件來限縮顯示的檔案與資料夾。",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything",
    "foss": false
  },
  "WPFInstallvc2015_32": {
    "category": "Microsoft 工具",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 32-bit",
    "description": "Visual C++ 2015-2022 32 位元可轉散發套件會安裝執行 32 位元應用程式所需的 Visual C++ 程式庫執行階段元件。",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86",
    "foss": false
  },
  "WPFInstallvc2015_64": {
    "category": "Microsoft 工具",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 64-bit",
    "description": "Visual C++ 2015-2022 64 位元可轉散發套件會安裝執行 64 位元應用程式所需的 Visual C++ 程式庫執行階段元件。",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64",
    "foss": false
  },
  "WPFInstallventoy": {
    "category": "Pro Tools",
    "choco": "ventoy",
    "content": "Ventoy",
    "description": "Ventoy 是一款開源工具，可用於製作可開機的 USB 隨身碟。它支援在單一 USB 上放入多個 ISO 檔案，是安裝作業系統的多用途方案。",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy",
    "foss": true
  },
  "WPFInstallvesktop": {
    "category": "通訊",
    "choco": "na",
    "content": "Vesktop",
    "description": "一款以 electron 為基礎的跨平台桌面 App，預裝 Vencord，讓你享有更流暢的 Discord 體驗。",
    "link": "https://github.com/Vencord/Vesktop",
    "winget": "Vencord.Vesktop",
    "foss": true
  },
  "WPFInstallviber": {
    "category": "通訊",
    "choco": "viber",
    "content": "Viber",
    "description": "Viber 是一款免費的訊息與通話應用程式，具備群組聊天、視訊通話等功能。",
    "link": "https://www.viber.com/",
    "winget": "Rakuten.Viber",
    "foss": false
  },
  "WPFInstallvisualstudio2022": {
    "category": "開發",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 是一套整合式開發環境（IDE），用於建置、除錯與部署應用程式。",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community",
    "foss": false
  },
  "WPFInstallvisualstudio2026": {
    "category": "開發",
    "choco": "visualstudio2026community",
    "content": "Visual Studio 2026",
    "description": "Visual Studio 2026 是一套整合式開發環境（IDE），用於建置、除錯與部署應用程式。",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.Community",
    "foss": false
  },
  "WPFInstallvivaldi": {
    "category": "瀏覽器",
    "choco": "vivaldi",
    "content": "Vivaldi",
    "description": "Vivaldi 是一款高度可自訂的網頁瀏覽器，著重於使用者個人化與生產力功能。",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi",
    "foss": false
  },
  "WPFInstallvlc": {
    "category": "多媒體工具",
    "choco": "vlc",
    "content": "VLC (Video Player)",
    "description": "VLC Media Player 是一款免費開源的多媒體播放器，支援廣泛的音訊與視訊格式。它以多功能與跨平台相容性著稱。",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "遊戲",
    "choco": "na",
    "content": "Virtual Desktop Streamer",
    "description": "Virtual Desktop Streamer 是一款可將你的桌面畫面串流到 VR 裝置的工具。",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer",
    "foss": false
  },
  "WPFInstallvscode": {
    "category": "開發",
    "choco": "vscode",
    "content": "VS Code",
    "description": "Visual Studio Code 是一款免費的開源程式碼編輯器，支援多種程式語言。",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode",
    "foss": true
  },
  "WPFInstallvscodium": {
    "category": "開發",
    "choco": "vscodium",
    "content": "VS Codium",
    "description": "VSCodium 是社群主導、採自由授權的 Microsoft VS Code 二進位發行版。",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium",
    "foss": true
  },
  "WPFInstallwaterfox": {
    "category": "瀏覽器",
    "choco": "waterfox",
    "content": "Waterfox",
    "description": "Waterfox 是一款以 Firefox 為基礎、快速且重視隱私的網頁瀏覽器，旨在維護使用者的選擇權與隱私。",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox",
    "foss": true
  },
  "WPFInstallwhatsapp": {
    "category": "通訊",
    "choco": "na",
    "content": "WhatsApp Desktop",
    "description": "WhatsApp Desktop 是 Meta 官方的 Windows 桌面訊息應用程式，透過 Microsoft Store 發行。",
    "link": "https://apps.microsoft.com/detail/9nksqgp7f2nh",
    "winget": "msstore:9NKSQGP7F2NH",
    "foss": false
  },
  "WPFInstallwingetui": {
    "category": "工具程式",
    "choco": "wingetui",
    "content": "UniGetUI",
    "description": "UniGetUI 是 WinGet、Chocolatey 及其他 Windows 命令列套件管理器的圖形介面。",
    "link": "https://devolutions.net/unigetui/",
    "winget": "Devolutions.UniGetUI",
    "foss": true
  },
  "WPFInstallwinrar": {
    "category": "工具程式",
    "choco": "winrar",
    "content": "WinRAR",
    "description": "WinRAR 是一款強大的壓縮檔管理員，可讓你建立、管理及解壓縮壓縮檔。",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR",
    "foss": false
  },
  "WPFInstallwinscp": {
    "category": "Pro Tools",
    "choco": "winscp",
    "content": "WinSCP",
    "description": "WinSCP 是一款熱門的開源 SFTP、FTP 與 SCP 用戶端，適用於 Windows。它可在本機與遠端電腦之間進行安全的檔案傳輸。",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP",
    "foss": true
  },
  "WPFInstallwireguard": {
    "category": "Pro Tools",
    "choco": "wireguard",
    "content": "WireGuard",
    "description": "WireGuard 是一款快速且現代的 VPN（虛擬私人網路）協定。它力求比其他 VPN 協定更簡潔、更高效，提供安全可靠的連線。",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard",
    "foss": true
  },
  "WPFInstallwireshark": {
    "category": "Pro Tools",
    "choco": "wireshark",
    "content": "Wireshark",
    "description": "Wireshark 是一款廣受使用的開源網路協定分析器。它可讓使用者即時擷取並分析網路流量，提供對網路活動的詳細洞察。",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark",
    "foss": true
  },
  "WPFInstallwiztree": {
    "category": "工具程式",
    "choco": "wiztree",
    "content": "WizTree",
    "description": "WizTree 是一款快速的磁碟空間分析器，協助你迅速找出硬碟中佔用最多空間的檔案與資料夾。",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree",
    "foss": false
  },
  "WPFInstallxeheditor": {
    "category": "工具程式",
    "choco": "HxD",
    "content": "HxD Hex Editor",
    "description": "HxD 是一款免費的十六進位編輯器，可讓你編輯、檢視、搜尋與分析二進位檔案。",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD",
    "foss": false
  },
  "WPFInstallyarn": {
    "category": "開發",
    "choco": "yarn",
    "content": "Yarn",
    "description": "Yarn 是一款快速、可靠且安全的 JavaScript 專案相依套件管理工具。",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn",
    "foss": true
  },
  "WPFInstallzoom": {
    "category": "通訊",
    "choco": "zoom",
    "content": "Zoom",
    "description": "Zoom 是一款熱門的視訊會議與網路會議服務，適用於線上會議、網路研討會與協作專案。",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom",
    "foss": false
  },
  "WPFInstalluv": {
    "category": "開發",
    "choco": "uv",
    "content": "uv",
    "description": "uv 是以 Rust 撰寫、快速的 Python 套件與專案管理器。",
    "link": "https://docs.astral.sh/uv/getting-started/installation/",
    "winget": "astral-sh.uv",
    "foss": true
  },
  "WPFInstalltightvnc": {
    "category": "工具程式",
    "choco": "TightVNC",
    "content": "TightVNC",
    "description": "TightVNC 是免費且開放原始碼的遠端桌面軟體，讓你透過網路存取並控制電腦。憑藉其直覺的介面，你可以操作遠端畫面，彷彿就坐在電腦前一樣。你幾乎可以像親臨現場般在遠端桌面上開啟檔案、啟動應用程式與執行其他操作。",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC",
    "foss": true
  },
  "WPFInstallglazewm": {
    "category": "工具程式",
    "choco": "glazewm",
    "content": "GlazeWM",
    "description": "GlazeWM 是一款 Windows 平鋪式視窗管理器，靈感來自 i3 與 Polybar。",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm",
    "foss": true
  },
  "WPFInstallOverwolf": {
    "category": "遊戲",
    "choco": "overwolf",
    "content": "Overwolf",
    "description": "熱門的遊戲覆疊與輔助應用程式平台（模組管理器、追蹤器等），廣受玩家使用。",
    "link": "https://www.overwolf.com/app/overwolf-curseforge",
    "winget": "Overwolf.CurseForge",
    "foss": false
  },
  "WPFInstallOFGB": {
    "category": "工具程式",
    "choco": "ofgb",
    "content": "OFGB (Oh Frick Go Back)",
    "description": "用於移除 Windows 11 各處廣告的圖形介面工具",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB",
    "foss": true
  },
  "WPFInstallZenBrowser": {
    "category": "瀏覽器",
    "choco": "zen-browser",
    "content": "Zen Browser",
    "description": "以 Firefox 為基礎打造、注重隱私且以效能為導向的現代化瀏覽器。",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser",
    "foss": true
  },
  "WPFInstallZed": {
    "category": "開發",
    "choco": "zed",
    "content": "Zed",
    "description": "Zed 是一款現代、高效能的程式碼編輯器，從底層設計即著重於速度與協作。",
    "link": "https://zed.dev/",
    "winget": "ZedIndustries.Zed",
    "foss": true
  },
  "WPFInstalldeskflow": {
    "category": "工具程式",
    "choco": "deskflow",
    "content": "Deskflow",
    "description": "Deskflow 是一款免費且開放原始碼的軟體 KVM，讓你在多台電腦間共用同一組鍵盤與滑鼠。",
    "link": "https://github.com/deskflow/deskflow",
    "winget": "Deskflow.Deskflow",
    "foss": true
  },
  "WPFInstallRuby": {
    "category": "開發",
    "choco": "ruby",
    "winget": "RubyInstallerTeam.Ruby.4.0",
    "description": "內含 MSYS2 安裝的 Ruby 語言執行環境。",
    "content": "Ruby",
    "link": "https://rubyinstaller.org/",
    "foss": true
  },
  "WPFInstallLua": {
    "category": "開發",
    "choco": "lua",
    "winget": "rjpcomputing.luaforwindows",
    "description": "Windows 上的 Lua 腳本語言「開箱即用環境」。",
    "content": "Lua",
    "link": "https://github.com/rjpcomputing/luaforwindows",
    "foss": true
  }
}
'@ | ConvertFrom-Json
$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "安裝/升級應用程式",
    "Category": "____操作",
    "Type": "Button",
    "Order": "1",
    "Description": "安裝或升級所選的應用程式"
  },
  "WPFUninstall": {
    "Content": "解除安裝應用程式",
    "Category": "____操作",
    "Type": "Button",
    "Order": "2",
    "Description": "解除安裝所選的應用程式"
  },
  "WPFInstallUpgrade": {
    "Content": "升級所有應用程式",
    "Category": "____操作",
    "Type": "Button",
    "Order": "3",
    "Description": "將所有應用程式升級至最新版本"
  },
  "WingetRadioButton": {
    "Content": "WinGet",
    "Category": "__套件管理器",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "使用 WinGet 進行套件管理"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey",
    "Category": "__套件管理器",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "使用 Chocolatey 進行套件管理"
  },
  "WPFCollapseAllCategories": {
    "Content": "摺疊所有分類",
    "Category": "__選取",
    "Type": "Button",
    "Order": "1",
    "Description": "摺疊所有應用程式分類"
  },
  "WPFExpandAllCategories": {
    "Content": "展開所有分類",
    "Category": "__選取",
    "Type": "Button",
    "Order": "2",
    "Description": "展開所有應用程式分類"
  },
  "WPFClearInstallSelection": {
    "Content": "清除選取",
    "Category": "__選取",
    "Type": "Button",
    "Order": "3",
    "Description": "清除已選取的應用程式"
  },
  "WPFGetInstalled": {
    "Content": "顯示已安裝軟體",
    "Category": "__選取",
    "Type": "Button",
    "Order": "4",
    "Description": "顯示已安裝的應用程式"
  },
  "WPFselectedAppsButton": {
    "Content": "已選軟體: 0",
    "Category": "__選取",
    "Type": "Button",
    "Order": "5",
    "Description": "顯示已選取的應用程式"
  },
  "WPFInstallFOSSInfo": {
    "Content": "免費與開放原始碼軟體",
    "Category": "__選取",
    "Type": "Note",
    "Order": "0",
    "Description": "關於應用程式項目上 #FOSS 標籤的說明"
  }
}
'@ | ConvertFrom-Json
$sync.configs.appx = @'
{
  "WPFAppxMicrosoft_WindowsFeedbackHub": {
    "Category": "Microsoft 應用程式",
    "Content": "Feedback Hub",
    "Description": "允許使用者直接向 Microsoft 提交錯誤回報、功能建議與診斷資料。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsFeedbackHub"
  },
  "WPFAppxMicrosoft_GetHelp": {
    "Category": "Microsoft 應用程式",
    "Content": "取得協助",
    "Description": "提供自動化疑難排解指南、支援文件及 Microsoft 客戶服務的直接協助。",
    "Panel": "0",
    "PackageId": "Microsoft.GetHelp"
  },
  "WPFAppxMicrosoft_OutlookForWindows": {
    "Category": "Microsoft 應用程式",
    "Content": "Outlook for Windows",
    "Description": "提供現代化的電子郵件管理、行事曆排程及聯絡人整理功能。",
    "Panel": "0",
    "PackageId": "Microsoft.OutlookForWindows"
  },
  "WPFAppxMSTeams": {
    "Category": "Microsoft 應用程式",
    "Content": "Microsoft Teams",
    "Description": "提供即時通訊、視訊會議、檔案分享與工作區協作功能。",
    "Panel": "0",
    "PackageId": "MSTeams"
  },
  "WPFAppxClipchamp_Clipchamp": {
    "Category": "工具程式與生產力",
    "Content": "Clipchamp",
    "Description": "提供操作友善的影片編輯器，內建範本、特效與時間軸編輯工具。",
    "Panel": "0",
    "PackageId": "Clipchamp.Clipchamp"
  },
  "WPFAppxMicrosoft_MicrosoftOfficeHub": {
    "Category": "Microsoft 應用程式",
    "Content": "Microsoft 365",
    "Description": "作為集中式啟動器與儀表板，用於存取雲端 Microsoft 365 應用程式與最近的文件。",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftOfficeHub"
  },
  "WPFAppxMicrosoft_ZuneMusic": {
    "Category": "工具程式與生產力",
    "Content": "媒體播放器",
    "Description": "播放本機音訊與影片檔案，並提供現代化的播放清單管理與投放功能。",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneMusic"
  },
  "WPFAppxMicrosoft_BingSearch": {
    "Category": "Bing 與網路服務",
    "Content": "Bing 搜尋",
    "Description": "將 Microsoft Bing 搜尋功能與網路服務直接整合進作業系統。",
    "Panel": "1",
    "PackageId": "Microsoft.BingSearch"
  },
  "WPFAppxMicrosoftCorporationII_QuickAssist": {
    "Category": "工具程式與生產力",
    "Content": "快速助手",
    "Description": "透過網際網路連線啟用安全的遠端技術支援與螢幕分享。",
    "Panel": "0",
    "PackageId": "MicrosoftCorporationII.QuickAssist"
  },
  "WPFAppxMicrosoft_WindowsDevHome": {
    "Category": "開發者工具",
    "Content": "Dev Home",
    "Description": "提供專為軟體開發者設計的儀表板，用於開發環境設定、儲存庫同步與硬體小工具。",
    "Panel": "1",
    "PackageId": "Microsoft.Windows.DevHome"
  },
  "WPFAppxMicrosoft_WindowsCrossDevice": {
    "Category": "Microsoft 生態系",
    "Content": "行動裝置",
    "Description": "管理與已配對行動裝置的系統層級背景連線。移除此項可能會停用跨裝置功能，例如手機螢幕鏡射、檔案傳輸，以及整合於 Windows 設定中的行動熱點交接。",
    "Panel": "0",
    "PackageId": "MicrosoftWindows.CrossDevice"
  },
  "WPFAppxMicrosoft_Todos": {
    "Category": "工具程式與生產力",
    "Content": "To Do",
    "Description": "建立、追蹤並同步個人工作、智慧型清單與每日提醒。",
    "Panel": "0",
    "PackageId": "Microsoft.Todos"
  },
  "WPFAppxMicrosoft_PowerAutomateDesktop": {
    "Category": "開發者工具",
    "Content": "Power Automate",
    "Description": "運用低程式碼的視覺化腳本，自動化重複性工作流程與桌面工作。",
    "Panel": "1",
    "PackageId": "Microsoft.PowerAutomateDesktop"
  },
  "WPFAppxMicrosoft_YourPhone": {
    "Category": "Microsoft 生態系",
    "Content": "手機連結",
    "Description": "將行動裝置的簡訊、手機通知、相片與通話同步到桌面。",
    "Panel": "0",
    "PackageId": "Microsoft.YourPhone"
  },
  "WPFAppxMicrosoft_MicrosoftStickyNotes": {
    "Category": "工具程式與生產力",
    "Content": "便利貼",
    "Description": "在桌面上建立快速的浮動文字便箋，並自動跨裝置同步。",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftStickyNotes"
  },
  "WPFAppxMicrosoft_WindowsSoundRecorder": {
    "Category": "工具程式與生產力",
    "Content": "錄音機",
    "Description": "錄製並修剪即時音訊輸入，並提供簡易的麥克風調整控制。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsSoundRecorder"
  },
  "WPFAppxMicrosoft_WindowsAlarms": {
    "Category": "工具程式與生產力",
    "Content": "時鐘",
    "Description": "提供世界時鐘、鬧鐘、倒數計時器、碼錶，以及專屬的專注時段追蹤功能。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsAlarms"
  },
  "WPFAppxMicrosoft_Paint": {
    "Category": "工具程式與生產力",
    "Content": "小畫家",
    "Description": "提供內建的數位素描、基本影像編輯及像素級圖形處理工具。",
    "Panel": "0",
    "PackageId": "Microsoft.Paint"
  },
  "WPFAppxMicrosoft_WindowsNotepad": {
    "Category": "工具程式與生產力",
    "Content": "記事本",
    "Description": "提供一款輕量的文字編輯器，支援多分頁，適用於純文字檔案與程式碼片段。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsNotepad"
  },
  "WPFAppxMicrosoft_ScreenSketch": {
    "Category": "工具程式與生產力",
    "Content": "剪取工具",
    "Description": "擷取螢幕截圖或螢幕錄影，並內建標註、圖片裁切與光學字元辨識（OCR）功能。",
    "Panel": "0",
    "PackageId": "Microsoft.ScreenSketch"
  },
  "WPFAppxMicrosoft_Copilot": {
    "Category": "Bing 與網路服務",
    "Content": "Copilot",
    "Description": "啟動 Microsoft AI 助理，提供情境式解答、創意寫作協助與智慧網路搜尋。",
    "Panel": "1",
    "PackageId": "Microsoft.Copilot"
  },
  "WPFAppxMicrosoft_WindowsCalculator": {
    "Category": "工具程式與生產力",
    "Content": "計算機",
    "Description": "執行標準算術、科學運算、程式設計計算及單位換算。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCalculator"
  },
  "WPFAppxMicrosoft_WindowsCamera": {
    "Category": "工具程式與生產力",
    "Content": "相機",
    "Description": "透過連接的網路攝影機或影像裝置拍攝相片與錄製影片檔。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCamera"
  },
  "WPFAppxMicrosoft_WindowsPhotos": {
    "Category": "工具程式與生產力",
    "Content": "相片",
    "Description": "整理、檢視及裁切本機影像，並提供基本的色彩調整與相簿建立工具。",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.Photos"
  },
  "WPFAppxMicrosoft_BingNews": {
    "Category": "Bing 與網路服務",
    "Content": "新聞",
    "Description": "彙整即時新聞頭條、個人化文章動態與世界時事。",
    "Panel": "1",
    "PackageId": "Microsoft.BingNews"
  },
  "WPFAppxMicrosoft_BingWeather": {
    "Category": "Bing 與網路服務",
    "Content": "天氣",
    "Description": "顯示當地即時天氣追蹤、雷達圖與歷史氣象預報。",
    "Panel": "1",
    "PackageId": "Microsoft.BingWeather"
  },
  "WPFAppxMicrosoft_GamingApp": {
    "Category": "Xbox 與遊戲",
    "Content": "Xbox App",
    "Description": "作為主要的遊戲庫管理員、社群社交介面與 PC Game Pass 儀表板。",
    "Panel": "1",
    "PackageId": "Microsoft.GamingApp"
  },
  "WPFAppxMicrosoft_XboxGamingOverlay": {
    "Category": "Xbox 與遊戲",
    "Content": "Xbox Game Bar",
    "Description": "提供可自訂的遊戲內狀態小工具、音訊平衡滑桿、系統監控工具及遊戲畫面錄製功能。",
    "Panel": "1",
    "PackageId": "Microsoft.XboxGamingOverlay"
  },
  "WPFAppxMicrosoft_XboxIdentityProvider": {
    "Category": "Xbox 與遊戲",
    "Content": "Xbox Identity Provider",
    "Description": "管理 Xbox 網路使用者驗證，以及已連線遊戲的背景帳號驗證。警告：移除此項可能會導致依賴此驗證管道的非 Xbox 遊戲與應用程式無法使用 Microsoft 帳號登入。",
    "Panel": "1",
    "PackageId": "Microsoft.XboxIdentityProvider"
  },
  "WPFAppxMicrosoft_XboxSpeechToTextOverlay": {
    "Category": "Xbox 與遊戲",
    "Content": "Xbox Speech To Text Overlay",
    "Description": "為遊戲聊天網路提供系統層級的即時輔助字幕及語音轉文字翻譯功能。",
    "Panel": "1",
    "PackageId": "Microsoft.XboxSpeechToTextOverlay"
  },
  "WPFAppxMicrosoft_Xbox_TCUI": {
    "Category": "Xbox 與遊戲",
    "Content": "Xbox TCUI",
    "Description": "為遊戲中的單一登入流程提供核心帳號連結 UI 模組。警告：移除此項可能導致原本不需 Xbox app 的遊戲與應用程式無法進行 Microsoft 帳號驗證。",
    "Panel": "1",
    "PackageId": "Microsoft.Xbox.TCUI"
  },
  "WPFAppxMicrosoft_StartExperiencesApp": {
    "Category": "Bing 與網路服務",
    "Content": "Start Experiences App",
    "Description": "為 Windows Widgets 面板提供動力，傳遞個人化的新聞、天氣、體育與財經內容資訊流。",
    "Panel": "1",
    "PackageId": "Microsoft.StartExperiencesApp"
  },
  "WPFAppxMicrosoft_MicrosoftSolitaireCollection": {
    "Category": "Xbox 與遊戲",
    "Content": "接龍遊戲集",
    "Description": "內建 Klondike、Spider、FreeCell、Pyramid 與 TriPeaks 等紙牌遊戲模式，並附有每日挑戰。",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftSolitaireCollection"
  }
}
'@ | ConvertFrom-Json
$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff"
  }
}
'@ | ConvertFrom-Json
$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": ".NET Framework（版本 2、3、4）- 啟用",
    "Description": ".NET 與 .NET Framework 是由工具、程式語言與函式庫組成的開發者平台，可用於建置多種不同類型的應用程式。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/dotnet"
  },
  "WPFFixesNTPPool": {
    "Content": "NTP 伺服器 - 啟用",
    "Description": "將預設的 Windows NTP 伺服器（time.windows.com）替換為 pool.ntp.org，以提升時間同步的準確度與可靠性。",
    "category": "修正",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNTPPool",
    "link": "https://winutil.christitus.com/dev/features/fixes/ntppool"
  },
  "WPFFeatureshyperv": {
    "Content": "Hyper-V - 啟用",
    "Description": "Hyper-V 是 Microsoft 開發的硬體虛擬化產品，可讓使用者建立與管理虛擬機器。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "傳統媒體元件 (WMP、DirectPlay) - 啟用",
    "Description": "啟用舊版 Windows 的傳統程式。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "Windows Subsystem for Linux (WSL) - 啟用",
    "Description": "Windows Subsystem for Linux 是 Windows 的選用功能，可讓 Linux 程式在 Windows 上原生執行，無需另建虛擬機器或雙系統開機。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "網路檔案系統 (NFS) - 啟用",
    "Description": "網路檔案系統 (NFS) 是一種將檔案儲存於網路上的機制。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/nfs"
  },
  "WPFFeatureRegBackup": {
    "Content": "登錄檔備份（每日排程 12:30am）- 啟用",
    "Description": "啟用每日登錄檔備份，此功能先前於 Windows 10 1803 中被 Microsoft 停用。",
    "category": "功能",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force\n      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force\n      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'\n      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30\n      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'\n      "
    ],
    "link": "https://winutil.christitus.com/dev/features/features/regbackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "傳統 F8 開機修復 - 啟用",
    "Description": "啟用進階開機選項畫面，該畫面可讓你以進階疑難排解模式啟動 Windows。",
    "category": "功能",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/enablelegacyrecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "傳統 F8 開機修復 - 停用",
    "Description": "停用進階開機選項畫面，該畫面可讓你以進階疑難排解模式啟動 Windows。",
    "category": "功能",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/disablelegacyrecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "Windows Sandbox - 啟用",
    "Description": "Windows Sandbox 是一種輕量級虛擬機器，提供暫時的桌面環境，讓你在隔離狀態下安全地執行應用程式與軟體。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "安裝功能",
    "category": "功能",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFeatureInstall",
    "link": "https://winutil.christitus.com/dev/features/features/install"
  },
  "WPFPanelAutologin": {
    "Content": "AutoLogon - 執行",
    "category": "修正",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFPanelAutologin",
    "link": "https://winutil.christitus.com/dev/features/fixes/autologin"
  },
  "WPFFixesUpdate": {
    "Content": "Windows Update - 重設",
    "category": "修正",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesUpdate",
    "link": "https://winutil.christitus.com/dev/features/fixes/update"
  },
  "WPFFixesNetwork": {
    "Content": "網路 - 重設",
    "category": "修正",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNetwork",
    "link": "https://winutil.christitus.com/dev/features/fixes/network"
  },
  "WPFPanelDISM": {
    "Content": "系統損毀掃描 - 執行",
    "category": "修正",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSystemRepair",
    "link": "https://winutil.christitus.com/dev/features/fixes/dism"
  },
  "WPFFixesWinget": {
    "Content": "WinGet - 重新安裝",
    "category": "修正",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesWinget",
    "link": "https://winutil.christitus.com/dev/features/fixes/winget"
  },
  "WPFPanelControl": {
    "Content": "控制台",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "control"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/control"
  },
  "WPFPanelComputer": {
    "Content": "電腦管理",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "compmgmt.msc"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/computer"
  },
  "WPFPanelNetwork": {
    "Content": "網路連線",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "ncpa.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/network"
  },
  "WPFPanelPower": {
    "Content": "電源面板",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "powercfg.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/power"
  },
  "WPFPanelPrinter": {
    "Content": "印表機面板",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "Start-Process 'shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}'"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/printer"
  },
  "WPFPanelRegion": {
    "Content": "地區",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "intl.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/region"
  },
  "WPFPanelRestore": {
    "Content": "Windows 還原",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "rstrui.exe"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/restore"
  },
  "WPFPanelSound": {
    "Content": "音效設定",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "mmsys.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/sound"
  },
  "WPFPanelSystem": {
    "Content": "系統內容",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "sysdm.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/system"
  },
  "WPFPanelTimedate": {
    "Content": "時間與日期",
    "category": "傳統 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "timedate.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/timedate"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "CTT PowerShell Profile - 安裝",
    "category": "Powershell 設定檔（僅限 Powershell 7+）",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilInstallPSProfile",
    "link": "https://winutil.christitus.com/dev/features/powershell-profile-powershell-7--only/installpsprofile"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "CTT PowerShell Profile - 移除",
    "category": "Powershell 設定檔（僅限 Powershell 7+）",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilUninstallPSProfile",
    "link": "https://winutil.christitus.com/dev/features/powershell-profile-powershell-7--only/uninstallpsprofile"
  },
  "WPFWinUtilSSHServer": {
    "Content": "OpenSSH 伺服器 - 啟用",
    "category": "遠端存取",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSSHServer",
    "link": "https://winutil.christitus.com/dev/features/remote-access/sshserver"
  }
}
'@ | ConvertFrom-Json
$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ],
  "Advanced": [
    "WPFTweaksRestorePoint",
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksDisableStoreSearch",
    "WPFTweaksRevertStartMenu",
    "WPFTweaksWidget",
    "WPFTweaksRemoveOneDrive",
    "WPFTweaksWindowsAI",
    "WPFTweaksRightClickMenu"
  ],
  "AppxDefault": [
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_WindowsCalculator",
    "WPFAppxClipchamp_Clipchamp",
    "WPFAppxMicrosoft_WindowsAlarms",
    "WPFAppxMicrosoftCorporationII_QuickAssist",
    "WPFAppxMicrosoft_WindowsSoundRecorder",
    "WPFAppxMicrosoft_MicrosoftStickyNotes",
    "WPFAppxMicrosoft_Todos",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingWeather",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_Copilot",
    "WPFAppxMicrosoft_BingSearch"
  ]
}
'@ | ConvertFrom-Json
$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "200",
    "AppEntryFontSize": "11",
    "AppEntryMargin": "1,0,1,0",
    "AppEntryBorderThickness": "0",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "130",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "18",
    "GroupBorderBackgroundColor": "#232629",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "250",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F7F7F7",
    "AppInstallHighlightedColor": "#CFCFCF",
    "AppInstallSelectedColor": "#C2C2C2",
    "AppInstallOverlayBackgroundColor": "#6A6D72",
    "ComboBoxForegroundColor": "#232629",
    "ComboBoxBackgroundColor": "#F7F7F7",
    "LabelboxForegroundColor": "#232629",
    "MainForegroundColor": "#232629",
    "MainBackgroundColor": "#F7F7F7",
    "LabelBackgroundColor": "#F7F7F7",
    "LinkForegroundColor": "#484848",
    "LinkHoverForegroundColor": "#232629",
    "ScrollBarBackgroundColor": "#4A4D52",
    "ScrollBarHoverColor": "#5A5D62",
    "ScrollBarDraggingColor": "#6A6D72",
    "ProgressBarForegroundColor": "#2E77FF",
    "ProgressBarBackgroundColor": "Transparent",
    "ProgressBarTextColor": "#232629",
    "ButtonInstallBackgroundColor": "#F7F7F7",
    "ButtonTweaksBackgroundColor": "#F7F7F7",
    "ButtonConfigBackgroundColor": "#F7F7F7",
    "ButtonUpdatesBackgroundColor": "#F7F7F7",
    "ButtonWin11ISOBackgroundColor": "#F7F7F7",
    "ButtonAppxBackgroundColor": "#F7F7F7",
    "ButtonInstallForegroundColor": "#232629",
    "ButtonTweaksForegroundColor": "#232629",
    "ButtonConfigForegroundColor": "#232629",
    "ButtonUpdatesForegroundColor": "#232629",
    "ButtonWin11ISOForegroundColor": "#232629",
    "ButtonAppxForegroundColor": "#232629",
    "ButtonBackgroundColor": "#F5F5F5",
    "ButtonBackgroundPressedColor": "#1A1A1A",
    "ButtonBackgroundMouseoverColor": "#C2C2C2",
    "ButtonBackgroundSelectedColor": "#F0F0F0",
    "ButtonForegroundColor": "#232629",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#F7F7F7",
    "BorderColor": "#232629",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#232629",
    "AppInstallHighlightedColor": "#3C3C3C",
    "AppInstallSelectedColor": "#4C4C4C",
    "AppInstallOverlayBackgroundColor": "#2E3135",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#1E3747",
    "LabelboxForegroundColor": "#5BDCFF",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#232629",
    "LabelBackgroundColor": "#232629",
    "LinkForegroundColor": "#ADD8E6",
    "LinkHoverForegroundColor": "#F7F7F7",
    "ScrollBarBackgroundColor": "#2E3135",
    "ScrollBarHoverColor": "#3B4252",
    "ScrollBarDraggingColor": "#5E81AC",
    "ProgressBarForegroundColor": "#222222",
    "ProgressBarBackgroundColor": "Transparent",
    "ProgressBarTextColor": "#232629",
    "ButtonInstallBackgroundColor": "#222222",
    "ButtonTweaksBackgroundColor": "#333333",
    "ButtonConfigBackgroundColor": "#444444",
    "ButtonUpdatesBackgroundColor": "#555555",
    "ButtonWin11ISOBackgroundColor": "#666666",
    "ButtonAppxBackgroundColor": "#777777",
    "ButtonInstallForegroundColor": "#F7F7F7",
    "ButtonTweaksForegroundColor": "#F7F7F7",
    "ButtonConfigForegroundColor": "#F7F7F7",
    "ButtonUpdatesForegroundColor": "#F7F7F7",
    "ButtonWin11ISOForegroundColor": "#F7F7F7",
    "ButtonAppxForegroundColor": "#F7F7F7",
    "ButtonBackgroundColor": "#1E3747",
    "ButtonBackgroundPressedColor": "#F7F7F7",
    "ButtonBackgroundMouseoverColor": "#3B4252",
    "ButtonBackgroundSelectedColor": "#5E81AC",
    "ButtonForegroundColor": "#F7F7F7",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#2F373D",
    "BorderColor": "#2F373D",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "活動歷程記錄 - 停用",
    "Description": "清除最近的文件、剪貼簿與執行歷程記錄。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/activity"
  },
  "WPFTweaksHiber": {
    "Content": "休眠 - 停用",
    "Description": "休眠功能主要是為筆記型電腦設計的，會在關機前將記憶體內容儲存起來。一般電腦其實不應使用。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/hiber"
  },
  "WPFTweaksWidget": {
    "Content": "小工具 - 移除",
    "Description": "移除工作列左下角惱人的小工具。",
    "category": "必要調校",
    "panel": "1",
    "InvokeScript": [
      "\n      # Sometimes if you dont stop the Widgets process the removal may fail\n\n      Get-Process *Widget* | Stop-Process\n      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers\n      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers\n\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      Write-Host \"Removed widgets\"\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/widget"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "開始功能表舊版配置 - 啟用",
    "Description": "還原 25H2 逐步推出新版之前的舊版開始功能表配置。在較新版本的 Windows 上 !!此調校將無法運作!!",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
        "Name": "EnabledState",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/revertstartmenu"
  },
  "WPFTweaksDisableStoreSearch": {
    "Content": "Microsoft Store 推薦搜尋結果 - 停用",
    "Description": "在開始功能表中搜尋應用程式時，不顯示推薦的 Microsoft Store 應用程式。",
    "category": "必要調校",
    "panel": "1",
    "InvokeScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
    ],
    "UndoScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disablestoresearch"
  },
  "WPFTweaksLocation": {
    "Content": "位置追蹤 - 停用",
    "Description": "停用位置追蹤。",
    "category": "必要調校",
    "panel": "1",
    "service": [
      {
        "Name": "lfsvc",
        "StartupType": "Disable",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/location"
  },
  "WPFTweaksServices": {
    "Content": "服務 - 設為手動",
    "Description": "將部分服務設為手動啟動，並調整 SvcHostSplitThresholdInKB 登錄值以更符合系統記憶體，可大幅減少 svchost.exe 處理程序的數量。",
    "category": "必要調校",
    "panel": "1",
    "service": [
      {
        "Name": "CscService",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      }
    ],
    "InvokeScript": [
      "\n      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB\n      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/services"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Brave Browser - 移除臃腫元件",
    "Description": "停用各種惱人功能，例如 Brave Rewards、Leo AI、Crypto Wallet 與 VPN。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveNewsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveTalkDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "TorDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveP3AEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "UrlKeyedAnonymizedDataCollectionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "SafeBrowsingExtendedReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "MetricsReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/bravedebloat"
  },
  "WPFTweaksDisableWarningForUnsignedRdp": {
    "Content": "RDP 未簽署檔案警告 - 停用",
    "Description": "停用最新 Windows 10 與 11 更新所引入、在啟動未簽署 RDP 檔案時顯示的警告。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
        "Name": "RedirectionWarningDialogVersion",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
        "Name": "RdpLaunchConsentAccepted",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Microsoft Edge - 精簡化",
    "Description": "停用 Edge 中各種遙測選項、彈出視窗及其他惱人功能。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DefaultBrowserSettingsCampaignEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/edgedebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "消費者功能 - 停用",
    "Description": "Windows 不會為登入的使用者自動從 Windows Store 安裝任何遊戲、第三方應用程式或應用程式連結。部分預設應用程式將無法使用（例如 Phone Link）。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/consumerfeatures"
  },
  "WPFTweaksTelemetry": {
    "Content": "遙測 - 停用",
    "Description": "停用 Microsoft 遙測。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\n      # Disable Defender Auto Sample Submission\n      Set-MpPreference -SubmitSamplesConsent 2\n\n      # Disable (Connected User Experiences and Telemetry) Service\n      Set-Service -Name diagtrack -StartupType Disabled\n\n      # Disable (Windows Error Reporting Manager) Service\n      Set-Service -Name wermgr -StartupType Disabled\n\n      # Disable PowerShell 7 telemetry\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')\n\n      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds\n      "
    ],
    "UndoScript": [
      "\n      # Enable Defender Auto Sample Submission\n      Set-MpPreference -SubmitSamplesConsent 1\n\n      # Enable (Connected User Experiences and Telemetry) Service\n      Set-Service -Name diagtrack -StartupType Automatic\n\n      # Enable (Windows Error Reporting Manager) Service\n      Set-Service -Name wermgr -StartupType Automatic\n\n      # Enable PowerShell 7 telemetry\n      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/telemetry"
  },
  "WPFTweaksDeliveryOptimization": {
    "Content": "傳遞最佳化 - 停用",
    "Description": "阻止 Windows 使用你的頻寬，向網際網路或區域網路上的其他電腦上傳更新。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
        "Name": "DODownloadMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/deliveryoptimization"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Microsoft Edge - 移除",
    "Description": "透過在舊版 Edge 資料夾中建立假的 MicrosoftEdge.exe 檔案來解除安裝 Microsoft Edge。此舉會誘使 Windows 解鎖官方 Edge 解除安裝程式，達成系統層級的移除。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "InvokeScript": [
      "\n      $Path = Resolve-Path -Path \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\\*\\Installer\\setup.exe\" | Select-Object -Last 1\n\n      if (Test-Path $Path) {\n          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force\n          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait\n          Write-Host \"Microsoft Edge was removed\"\n      } else {\n          Write-Host \"Microsoft Edge is not installed\"\n      }\n      "
    ],
    "UndoScript": [
      "\n      Write-Host \"Installing Microsoft Edge...\"\n      winget install Microsoft.Edge --source winget\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removeedge"
  },
  "WPFTweaksDisableBitLocker": {
    "Content": "BitLocker - 停用",
    "Description": "停用 BitLocker。",
    "category": "必要調校",
    "panel": "1",
    "InvokeScript": [
      "Disable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "UndoScript": [
      "Enable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disablebitlocker"
  },
  "WPFTweaksUTC": {
    "Content": "日期與時間 - 將時間設為 UTC",
    "Description": "對雙重開機的電腦至關重要，可修正與 Linux 系統的時間同步問題。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/utc"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "Microsoft OneDrive - 移除",
    "Description": "拒絕移除 OneDrive 使用者檔案的權限，接著使用其內建的解除安裝程式移除它，之後再還原原本的權限。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "InvokeScript": [
      "\n      # Deny permission to remove OneDrive folder\n      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"\n\n      Write-Host \"Uninstalling OneDrive...\"\n      Start-Process '$Env:SystemRoot\\System32\\OneDriveSetup.exe' -ArgumentList '/uninstall' -Wait\n\n      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth\n      Write-Host \"Removing leftover OneDrive Files...\"\n\n      Stop-Process -Name FileCoAuth,Explorer\n\n      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force\n      Remove-Item \"$Env:ProgramData\\Microsoft OneDrive\" -Recurse -Force\n\n      # Grant back permission to access OneDrive folder\n      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"\n\n      if (-not (Get-ChildItem -Path $Env:OneDrive)) {\n          Remove-Item -Path $Env:OneDrive -Recurse\n          [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')\n      }\n\n      # Disable OneSyncSvc\n      Set-Service -Name OneSyncSvc -StartupType Disabled\n      "
    ],
    "UndoScript": [
      "\n      Write-Host \"Installing OneDrive\"\n      winget install Microsoft.Onedrive --source winget\n\n      # Enabled OneSyncSvc\n      Set-Service -Name OneSyncSvc -StartupType Automatic\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removeonedrive"
  },
  "WPFTweaksRemoveHomeAndGallery": {
    "Content": "檔案總管首頁與圖庫 - 停用",
    "Description": "從檔案總管移除「首頁」與「媒體庫」，並將「本機」設為預設。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removehomeandgallery"
  },
  "WPFTweaksDisplay": {
    "Content": "視覺效果 - 設為最佳效能",
    "Description": "將系統偏好設定調整為效能優先。你也可以透過 sysdm.cpl 手動設定。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/display"
  },
  "WPFTweaksReservedStorage": {
    "Content": "停用保留儲存空間",
    "Description": "停用 Windows 保留儲存空間（保留 7-10 GB 供更新／暫存檔使用）。僅建議在小容量磁碟上使用。請在重大 Windows 功能更新前重新啟用，以免安裝失敗。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "InvokeScript": [
      "DISM /Online /Set-ReservedStorageState /State:Disabled"
    ],
    "UndoScript": [
      "DISM /Online /Set-ReservedStorageState /State:Enabled"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/reservedstorage"
  },
  "WPFTweaksRestorePoint": {
    "Content": "還原點 - 建立",
    "Description": "在執行階段建立還原點，以便在需要時回復 WinUtil 所做的修改。",
    "category": "必要調校",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "\n      if (-not (Get-ComputerRestorePoint)) {\n          Enable-ComputerRestore -Drive $Env:SystemDrive\n      }\n\n      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS\n      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/restorepoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "以右鍵結束工作 - 啟用",
    "Description": "啟用在工具列上以右鍵點擊程式時結束工作的選項。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/endtaskontaskbar"
  },
  "WPFTweaksStorage": {
    "Content": "儲存空間感知 - 停用",
    "Description": "儲存空間感知會自動刪除暫存檔。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/storage"
  },
  "WPFTweaksWindowsAI": {
    "Content": "Windows AI - 停用並移除",
    "Description": "移除並停用所有 AI 功能／套件",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:aicomponents",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
        "Name": "DisableAIFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "\n      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName\n      $Sid = (Get-LocalUser $Env:UserName).Sid.Value\n\n      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force\n\n      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers\n      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2>$null\n      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers\n\n      if ($Appx) {\n          Remove-AppxPackage $Appx\n      }\n\n      Set-Service -Name WSAIFabricSvc -StartupType Disabled\n      Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart\n\n      Write-Host \"Windows AI Disabled\"\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/windowsai"
  },
  "WPFTweaksWPBT": {
    "Content": "Windows Platform Binary Table (WPBT) - 停用",
    "Description": "啟用後，WPBT 允許電腦廠商在開機時執行程式，例如防盜軟體、軟體驅動程式，甚至在未經使用者同意下強制安裝軟體。具有潛在的安全風險。",
    "category": "必要調校",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/wpbt"
  },
  "WPFTweaksRazerBlock": {
    "Content": "Razer 軟體自動安裝 - 停用",
    "Description": "封鎖所有 Razer 軟體的安裝。硬體不需任何軟體即可正常運作。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "\n      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"\n\n      if (Test-Path $RazerPath) {\n        Remove-Item $RazerPath\\* -Recurse -Force\n      } else {\n        New-Item -Path $RazerPath -ItemType Directory\n      }\n\n      icacls $RazerPath /deny \"Everyone:(W)\"\n      "
    ],
    "UndoScript": [
      "\n      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d Everyone\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/razerblock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "系統匣通知與行事曆 - 停用",
    "Description": "停用所有通知，包含行事曆。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablenotifications"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Adobe URL 封鎖清單 - 啟用",
    "Description": "選擇性封鎖與 Adobe 啟用及遙測伺服器的連線，減少對使用者的干擾。鳴謝：Ruddernation-Designs",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "InvokeScript": [
      "\n      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts\n      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl\n\n      ipconfig /flushdns\n      Write-Host 'Added Adobe url block list from host file'\n      "
    ],
    "UndoScript": [
      "\n      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (\n          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace '(?s)#New Ver.*', ''\n      )\n\n      ipconfig /flushdns\n      Write-Host 'Removed Adobe url block list from host file'\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/blockadobenet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "右鍵選單舊版配置 - 啟用",
    "Description": "在 File Explorer 中按右鍵時還原傳統的右鍵選單，取代 Windows 11 的簡化版本。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "InvokeScript": [
      "\n      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force\n      Stop-Process -Name explorer\n      "
    ],
    "UndoScript": [
      "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/rightclickmenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "磁碟清理 - 執行",
    "Description": "對 C: 磁碟機執行磁碟清理，並移除舊的 Windows Updates。",
    "category": "必要調校",
    "panel": "1",
    "InvokeScript": [
      "\n      cleanmgr.exe /d C: /VERYLOWDISK\n      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/diskcleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "暫存檔 - 移除",
    "Description": "清除 TEMP 資料夾。",
    "category": "必要調校",
    "panel": "1",
    "InvokeScript": [
      "\n      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force\n      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/deletetempfiles"
  },
  "WPFTweaksIPv46": {
    "Content": "IPv6 - 將 IPv4 設為優先",
    "Description": "在未設定 IPv6 的私人網路上，設定 IPv4 優先可帶來延遲與安全性上的好處。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/ipv46"
  },
  "WPFTweaksTeredo": {
    "Content": "Teredo - 停用",
    "Description": "Teredo 網路通道是 IPv6 的功能，可能造成額外延遲，也可能導致部分遊戲發生問題。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/teredo"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "IPv6 - 停用",
    "Description": "停用 IPv6。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disableipv6"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "背景應用程式 - 停用",
    "Description": "停用所有 Microsoft Store 應用程式的背景執行；自 Windows 11 起此設定必須逐一進行。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablebgapps"
  },
  "WPFTweaksDisableFSO": {
    "Content": "全螢幕最佳化 - 停用",
    "Description": "停用所有應用程式的 FSO。注意：這會停用獨佔全螢幕模式下的色彩管理。",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_DXGIHonorFSEWindowsCompatible",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablefso"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "檔案總管自動資料夾探索 - 停用",
    "Description": "Windows Explorer 會依資料夾內容自動猜測資料夾類型，拖慢瀏覽體驗。警告！這會停用檔案總管的分組功能。",
    "category": "必要調校",
    "panel": "1",
    "InvokeScript": [
      "\n      # Previously detected folders\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\n\n      # Folder types lookup table\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\n\n      # Flush Explorer view database\n      Remove-Item -Path $bags -Recurse -Force\n      Write-Host \"Removed $bags\"\n\n      Remove-Item -Path $bagMRU -Recurse -Force\n      Write-Host \"Removed $bagMRU\"\n\n      # Every folder\n      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"\n\n      if (!(Test-Path $allFolders)) {\n        New-Item -Path $allFolders -Force\n        Write-Host \"Created $allFolders\"\n      }\n\n      # Generic view\n      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force\n      Write-Host \"Set FolderType to NotSpecified\"\n\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\n      "
    ],
    "UndoScript": [
      "\n      # Previously detected folders\n      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"\n\n      # Folder types lookup table\n      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"\n\n      # Flush Explorer view database\n      Remove-Item -Path $bags -Recurse -Force\n      Write-Host \"Removed $bags\"\n\n      Remove-Item -Path $bagMRU -Recurse -Force\n      Write-Host \"Removed $bagMRU\"\n\n      Write-Host Please sign out and back in, or restart your computer to apply the changes!\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disableexplorerautodiscovery"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "藍色當機畫面詳細模式",
    "Description": "在發生藍白當機時提供更多資訊。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/detailedbsod"
  },
  "WPFToggleBatteryPercentage": {
    "Content": "系統匣電池百分比",
    "Description": "在系統匣的電池圖示旁顯示數字電量百分比。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "IsBatteryPercentageEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/batterypercentage"
  },
  "WPFToggleDarkMode": {
    "Content": "Windows 深色主題",
    "Description": "為系統與應用程式啟用深色模式。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\n      Invoke-WinUtilExplorerUpdate\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\n        Invoke-WinutilThemeChange -theme \"Auto\"\n      }\n      "
    ],
    "UndoScript": [
      "\n      Invoke-WinUtilExplorerUpdate\n      if ($sync.ThemeButton.Content -eq [char]0xF08C) {\n        Invoke-WinutilThemeChange -theme \"Auto\"\n      }\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/darkmode"
  },
  "WPFToggleShowExt": {
    "Content": "檔案總管副檔名",
    "Description": "在 Explorer 中顯示副檔名（.exe、.png 等）。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "UndoScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/showext"
  },
  "WPFToggleHiddenFiles": {
    "Content": "檔案總管隱藏檔案",
    "Description": "在 Explorer 中顯示隱藏檔案。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "UndoScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/hiddenfiles"
  },
  "WPFToggleVerboseLogon": {
    "Content": "登入詳細資訊模式",
    "Description": "在開機／關機時顯示詳細訊息。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/verboselogon"
  },
  "WPFToggleNewOutlook": {
    "Content": "Microsoft Outlook 新版",
    "Description": "這會確保使用傳統版的 Outlook 應用程式。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/newoutlook"
  },
  "WPFToggleScrollbars": {
    "Content": "捲軸永遠顯示",
    "Description": "啟用後捲軸將一律顯示；停用後 Windows 會在未使用時自動隱藏捲軸。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility",
        "Name": "DynamicScrollbars",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false",
        "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/scrollbars"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/scrollbars"
  },
  "WPFToggleMultiplaneOverlay": {
    "Content": "多平面重疊 (Multiplane Overlay)",
    "Description": "多平面重疊 (Multiplane Overlay) 會合成多個影像圖層，有時可能導致顯示卡發生問題。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "5",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "Name": "DisableOverlays",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/multiplaneoverlay"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "滑鼠加速",
    "Description": "讓游標移動受實體滑鼠移動速度影響。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/mouseacceleration"
  },
  "WPFToggleNumLock": {
    "Content": "開機時啟用 Num Lock",
    "Description": "在電腦啟動時切換 Num Lock 鍵的狀態。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/numlock"
  },
  "WPFToggleWindowSnapping": {
    "Content": "視窗貼齊",
    "Description": "切換拖曳視窗時的視窗貼齊功能。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/windowsnapping"
  },
  "WPFToggleStandbyFix": {
    "Content": "S0 睡眠網路連線",
    "Description": "切換 S0 睡眠期間的網路連線，S0 是現代筆電的低耗電閒置狀態。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
        "Name": "ACSettingIndex",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/standbyfix"
  },
  "WPFToggleS3Sleep": {
    "Content": "S3 睡眠",
    "Description": "在 Modern Standby 與 S3 睡眠之間切換；S3 睡眠會切斷 CPU 的電源，同時持續更新記憶體。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/s3sleep"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "設定首頁",
    "Description": "切換 Windows 設定應用程式中的首頁。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "show:home",
        "Type": "String",
        "OriginalValue": "hide:home",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/hidesettingshome"
  },
  "WPFToggleBingSearch": {
    "Content": "開始功能表 Bing 搜尋",
    "Description": "在 Windows Search 中切換 Bing 網路搜尋結果的開關。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/bingsearch"
  },
  "WPFToggleLoginBlur": {
    "Content": "登入畫面壓克力模糊",
    "Description": "切換登入畫面背景的壓克力模糊效果。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "DisableAcrylicBackgroundOnLogon",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/loginblur"
  },
  "WPFTweaksDisableLockscreen": {
    "Content": "鎖定畫面 - 停用",
    "Description": "在開機與喚醒時完全跳過鎖定畫面，直接進入登入畫面。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
        "Name": "NoLockScreen",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/disablelockscreen"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "開始功能表推薦項目",
    "Description": "切換開始功能表中的推薦區塊。警告：這也會連帶停用鎖定畫面上的 Windows Spotlight。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "UndoScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/startmenurecommendations"
  },
  "WPFToggleStickyKeys": {
    "Content": "相黏鍵",
    "Description": "切換相黏鍵，快速連按 Shift 時會啟動。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/stickykeys"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "工作列置中圖示",
    "Description": "切換工作列對齊方式為靠左或置中。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "UndoScript": [
      "\n      Invoke-WinUtilExplorerUpdate -action \"restart\"\n      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskbaralignment"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "工作列搜尋圖示",
    "Description": "切換工作列上的搜尋按鈕。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskbarsearch"
  },
  "WPFToggleTaskView": {
    "Content": "工作列工作檢視圖示",
    "Description": "切換工作列上的工作檢視按鈕。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskview"
  },
  "WPFToggleGameMode": {
    "Content": "遊戲模式",
    "Description": "切換 Windows 優先分配系統資源給遊戲以提升遊戲效能。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AllowAutoGameMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AutoGameModeEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/gamemode"
  },
  "WPFToggleLongPaths": {
    "Content": "啟用長路徑",
    "Description": "切換 Explorer 中超過 260 個字元的檔案路徑支援。",
    "category": "自訂偏好設定",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/longpaths"
  },
  "WPFOOSUbutton": {
    "Content": "O&O ShutUp10++ - 執行",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "Type": "Button",
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/oosubutton"
  },
  "WPFchangedns": {
    "Content": "DNS - 設定為：",
    "category": "z__進階調校 - 注意",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "極致效能設定檔 - 啟用",
    "category": "效能計畫 - 不適用筆電",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/tweaks/performance-plans---not-for-laptops/addultperf"
  },
  "WPFRemoveUltPerf": {
    "Content": "極致效能設定檔 - 停用",
    "category": "效能計畫 - 不適用筆電",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/tweaks/performance-plans---not-for-laptops/removeultperf"
  }
}
'@ | ConvertFrom-Json
$inputXML = @'
<Window
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        xmlns:d="http://schemas.microsoft.com/expression/blend/2008"
        xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
        xmlns:local="clr-namespace:WinUtility"
        WindowStartupLocation="CenterScreen"
        UseLayoutRounding="True"
        WindowStyle="None"
        Width="Auto"
        Height="Auto"
        MinWidth="800"
        MinHeight="600"
        Title="WinUtil">
    <WindowChrome.WindowChrome>
        <WindowChrome CaptionHeight="0" CornerRadius="10"/>
    </WindowChrome.WindowChrome>
    <Window.Resources>
    <Style TargetType="ToolTip">
        <Setter Property="Background" Value="{DynamicResource ToolTipBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
        <Setter Property="MaxWidth" Value="{DynamicResource ToolTipWidth}"/>
        <Setter Property="BorderThickness" Value="1"/>
        <Setter Property="Padding" Value="2"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <!-- This ContentTemplate ensures that the content of the ToolTip wraps text properly for better readability -->
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <ContentPresenter Content="{TemplateBinding Content}">
                        <ContentPresenter.Resources>
                            <Style TargetType="TextBlock">
                                <Setter Property="TextWrapping" Value="Wrap"/>
                            </Style>
                        </ContentPresenter.Resources>
                    </ContentPresenter>
                </DataTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="{x:Type MenuItem}">
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
        <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        <Setter Property="Padding" Value="5,2,5,2"/>
        <Setter Property="BorderThickness" Value="0"/>
    </Style>

    <!--Scrollbar Thumbs-->
    <Style x:Key="ScrollThumbs" TargetType="{x:Type Thumb}">
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type Thumb}">
                    <Grid Name="Grid">
                        <Rectangle HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto" Fill="Transparent" />
                        <Border Name="Rectangle1" CornerRadius="5" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" Width="Auto" Height="Auto"  Background="{TemplateBinding Background}" />
                    </Grid>
                    <ControlTemplate.Triggers>
                        <Trigger Property="Tag" Value="Horizontal">
                            <Setter TargetName="Rectangle1" Property="Width" Value="Auto" />
                            <Setter TargetName="Rectangle1" Property="Height" Value="7" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <Style TargetType="TextBlock" x:Key="HoverTextBlockStyle">
        <Setter Property="Foreground" Value="{DynamicResource LinkForegroundColor}" />
        <Setter Property="TextDecorations" Value="Underline" />
        <Style.Triggers>
            <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="{DynamicResource LinkHoverForegroundColor}" />
                <Setter Property="TextDecorations" Value="Underline" />
                <Setter Property="Cursor" Value="Hand" />
            </Trigger>
        </Style.Triggers>
    </Style>
    <Style x:Key="AppEntryBorderStyle" TargetType="Border">
        <Setter Property="BorderBrush" Value="Gray"/>
        <Setter Property="BorderThickness" Value="{DynamicResource AppEntryBorderThickness}"/>
        <Setter Property="CornerRadius" Value="2"/>
        <Setter Property="Padding" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Width" Value="{DynamicResource AppEntryWidth}"/>
        <Setter Property="VerticalAlignment" Value="Top"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Cursor" Value="Hand"/>
        <Setter Property="Background" Value="{DynamicResource AppInstallUnselectedColor}"/>
    </Style>
    <Style x:Key="AppEntryCheckboxStyle" TargetType="CheckBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="HorizontalAlignment" Value="Left"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="CheckBox">
                    <StackPanel Orientation="Horizontal">
                        <Grid Width="16" Height="16" Margin="0,0,8,0">
                            <Border Name="CheckBoxBorder"
                                    BorderBrush="{DynamicResource MainForegroundColor}"
                                    Background="{DynamicResource ButtonBackgroundColor}"
                                    BorderThickness="1"
                                    Width="12"
                                    Height="12"
                                    CornerRadius="2"/>
                            <Path Name="CheckMark"
                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                  StrokeThickness="2"
                                  Data="M 2 8 L 6 12 L 14 4"
                                  Visibility="Collapsed"/>
                        </Grid>
                        <ContentPresenter Content="{TemplateBinding Content}"
                                        VerticalAlignment="Center"
                                        HorizontalAlignment="Left"/>
                    </StackPanel>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsChecked" Value="True">
                            <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>
    <Style x:Key="AppEntryNameStyle" TargetType="TextBlock">
        <Setter Property="FontSize" Value="{DynamicResource AppEntryFontSize}"/>
        <Setter Property="FontWeight" Value="Bold"/>
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Background" Value="Transparent"/>
    </Style>
    <Style x:Key="AppEntryButtonStyle" TargetType="Button">
        <Setter Property="Width" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Height" Value="{DynamicResource IconButtonSize}"/>
        <Setter Property="Margin" Value="{DynamicResource AppEntryMargin}"/>
        <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
        <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
        <Setter Property="HorizontalAlignment" Value="Center"/>
        <Setter Property="VerticalAlignment" Value="Center"/>
        <Setter Property="ContentTemplate">
            <Setter.Value>
                <DataTemplate>
                    <TextBlock  Text="{Binding}"
                                FontFamily="Segoe MDL2 Assets"
                                FontSize="{DynamicResource IconFontSize}"
                                Background="Transparent"/>
                </DataTemplate>
            </Setter.Value>
        </Setter>
        <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Cursor" Value="Hand"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>


    </Style>
    <Style TargetType="Button" x:Key="HoverButtonStyle">
        <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
        <Setter Property="FontWeight" Value="Normal" />
        <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}" />
        <Setter Property="TextElement.FontFamily" Value="{DynamicResource ButtonFontFamily}"/>
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="Button">
                    <Border Background="{TemplateBinding Background}">
                        <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <ControlTemplate.Triggers>
                        <Trigger Property="IsMouseOver" Value="True">
                            <Setter Property="FontWeight" Value="Bold" />
                            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
                            <Setter Property="Cursor" Value="Hand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
    </Style>

    <!--ScrollBars-->
    <Style x:Key="{x:Type ScrollBar}" TargetType="{x:Type ScrollBar}">
        <Setter Property="Stylus.IsFlicksEnabled" Value="false" />
        <Setter Property="Foreground" Value="{DynamicResource ScrollBarBackgroundColor}" />
        <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
        <Setter Property="Width" Value="6" />
        <Setter Property="Template">
            <Setter.Value>
                <ControlTemplate TargetType="{x:Type ScrollBar}">
                    <Grid Name="GridRoot" Width="7" Background="{TemplateBinding Background}" >
                        <Grid.RowDefinitions>
                            <RowDefinition Height="0.00001*" />
                        </Grid.RowDefinitions>

                        <Track Name="PART_Track" Grid.Row="0" IsDirectionReversed="true" Focusable="false">
                            <Track.Thumb>
                                <Thumb Name="Thumb" Background="{TemplateBinding Foreground}" Style="{DynamicResource ScrollThumbs}" />
                            </Track.Thumb>
                            <Track.IncreaseRepeatButton>
                                <RepeatButton Name="PageUp" Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="false" />
                            </Track.IncreaseRepeatButton>
                            <Track.DecreaseRepeatButton>
                                <RepeatButton Name="PageDown" Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="false" />
                            </Track.DecreaseRepeatButton>
                        </Track>
                    </Grid>

                    <ControlTemplate.Triggers>
                        <Trigger SourceName="Thumb" Property="IsMouseOver" Value="true">
                            <Setter Value="{DynamicResource ScrollBarHoverColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>
                        <Trigger SourceName="Thumb" Property="IsDragging" Value="true">
                            <Setter Value="{DynamicResource ScrollBarDraggingColor}" TargetName="Thumb" Property="Background" />
                        </Trigger>

                        <Trigger Property="IsEnabled" Value="false">
                            <Setter TargetName="Thumb" Property="Visibility" Value="Collapsed" />
                        </Trigger>
                        <Trigger Property="Orientation" Value="Horizontal">
                            <Setter TargetName="GridRoot" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter TargetName="PART_Track" Property="LayoutTransform">
                                <Setter.Value>
                                    <RotateTransform Angle="-90" />
                                </Setter.Value>
                            </Setter>
                            <Setter Property="Width" Value="Auto" />
                            <Setter Property="Height" Value="8" />
                            <Setter TargetName="Thumb" Property="Tag" Value="Horizontal" />
                            <Setter TargetName="PageDown" Property="Command" Value="ScrollBar.PageLeftCommand" />
                            <Setter TargetName="PageUp" Property="Command" Value="ScrollBar.PageRightCommand" />
                        </Trigger>
                    </ControlTemplate.Triggers>
                </ControlTemplate>
            </Setter.Value>
        </Setter>
        </Style>
        <Style TargetType="ComboBox">
            <Setter Property="Foreground" Value="{DynamicResource ComboBoxForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource ComboBoxBackgroundColor}" />
            <Setter Property="MinWidth"   Value="{DynamicResource ButtonWidth}" />
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ComboBox">
                        <Grid>
                            <Border Name="OuterBorder"
                                    BorderBrush="{DynamicResource BorderColor}"
                                    BorderThickness="1"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}"
                                    Background="{TemplateBinding Background}">
                                <ToggleButton Name="ToggleButton"
                                              Background="Transparent"
                                              BorderThickness="0"
                                              IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}"
                                              ClickMode="Press">
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBlock Grid.Column="0"
                                                   Text="{TemplateBinding SelectionBoxItem}"
                                                   Foreground="{TemplateBinding Foreground}"
                                                   Background="Transparent"
                                                   HorizontalAlignment="Left" VerticalAlignment="Center"
                                                   Margin="6,3,2,3"/>
                                        <Path Grid.Column="1"
                                              Data="M 0,0 L 8,0 L 4,5 Z"
                                              Fill="{TemplateBinding Foreground}"
                                              Width="8" Height="5"
                                              VerticalAlignment="Center"
                                              HorizontalAlignment="Center"
                                              Stretch="Uniform"
                                              Margin="4,0,6,0"/>
                                    </Grid>
                                </ToggleButton>
                            </Border>
                            <Popup Name="Popup"
                                   IsOpen="{TemplateBinding IsDropDownOpen}"
                                   Placement="Bottom"
                                   Focusable="False"
                                   AllowsTransparency="True"
                                   PopupAnimation="Slide">
                                <Border Name="DropDownBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1"
                                        CornerRadius="4">
                                    <ScrollViewer>
                                        <ItemsPresenter HorizontalAlignment="Left" VerticalAlignment="Center" Margin="4,2"/>
                                    </ScrollViewer>
                                </Border>
                            </Popup>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
        </Style>

        <!-- TextBlock template -->
        <Style TargetType="TextBlock">
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="Foreground" Value="{DynamicResource LabelboxForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource LabelBackgroundColor}"/>
        </Style>
        <!-- Toggle button template x:Key="TabToggleButton" -->
        <Style TargetType="{x:Type ToggleButton}">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Content" Value=""/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="ButtonGlow"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonForegroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <Border Name="BackgroundBorder"
                                        Background="{TemplateBinding Background}"
                                        BorderBrush="{DynamicResource ButtonBackgroundColor}"
                                        BorderThickness="{DynamicResource ButtonBorderThickness}"
                                        CornerRadius="{DynamicResource ButtonCornerRadius}">
                                        <ContentPresenter
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"
                                            Margin="10,2,10,2"/>
                                    </Border>
                                </Grid>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="5" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-100" BlurRadius="15"/>
                                    </Setter.Value>
                                </Setter>
                                <Setter Property="Panel.ZIndex" Value="2000"/>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter Property="BorderBrush" Value="Pink"/>
                                <Setter Property="BorderThickness" Value="2"/>
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Effect">
                                    <Setter.Value>
                                        <DropShadowEffect Opacity="1" ShadowDepth="2" Color="{DynamicResource CButtonBackgroundMouseoverColor}" Direction="-111" BlurRadius="10"/>
                                    </Setter.Value>
                                </Setter>
                            </Trigger>
                            <Trigger Property="IsChecked" Value="False">
                                <Setter Property="BorderBrush" Value="Transparent"/>
                                <Setter Property="BorderThickness" Value="{DynamicResource ButtonBorderThickness}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Button Template -->
        <Style TargetType="Button">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="10,2,10,2"/>
                            </Border>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ToggleButtonStyle" TargetType="ToggleButton">
            <Setter Property="Margin" Value="{DynamicResource ButtonMargin}"/>
            <Setter Property="Foreground" Value="{DynamicResource ButtonForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource ButtonBackgroundColor}"/>
            <Setter Property="Height" Value="{DynamicResource ButtonHeight}"/>
            <Setter Property="Width" Value="{DynamicResource ButtonWidth}"/>
            <Setter Property="FontSize" Value="{DynamicResource ButtonFontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ToggleButton">
                        <Grid>
                            <Border Name="BackgroundBorder"
                                    Background="{TemplateBinding Background}"
                                    BorderBrush="{TemplateBinding BorderBrush}"
                                    BorderThickness="{DynamicResource ButtonBorderThickness}"
                                    CornerRadius="{DynamicResource ButtonCornerRadius}">
                                <Grid>
                                    <!-- Toggle Dot Background -->
                                    <Ellipse Width="8" Height="16"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0" />

                                    <!-- Toggle Dot with hover grow effect -->
                                    <Ellipse Name="ToggleDot"
                                            Width="8" Height="8"
                                            Fill="{DynamicResource ButtonForegroundColor}"
                                            HorizontalAlignment="Right"
                                            VerticalAlignment="Top"
                                            Margin="0,3,5,0"
                                            RenderTransformOrigin="0.5,0.5">
                                        <Ellipse.RenderTransform>
                                            <ScaleTransform ScaleX="1" ScaleY="1"/>
                                        </Ellipse.RenderTransform>
                                    </Ellipse>

                                    <!-- Content Presenter -->
                                    <ContentPresenter HorizontalAlignment="Center"
                                                    VerticalAlignment="Center"
                                                    Margin="10,2,10,2"/>
                                </Grid>
                            </Border>
                        </Grid>

                        <!-- Triggers for ToggleButton states -->
                        <ControlTemplate.Triggers>
                            <!-- Hover effect -->
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundMouseoverColor}"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to grow the dot when hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.2" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <!-- Animation to shrink the dot back to original size when not hovered -->
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                            <DoubleAnimation Storyboard.TargetName="ToggleDot"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1"/>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>

                            <!-- IsChecked state -->
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="ToggleDot" Property="VerticalAlignment" Value="Bottom"/>
                                <Setter TargetName="ToggleDot" Property="Margin" Value="0,0,5,3"/>
                            </Trigger>

                            <!-- IsEnabled state -->
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="BackgroundBorder" Property="Background" Value="{DynamicResource ButtonBackgroundSelectedColor}"/>
                                <Setter Property="Foreground" Value="DimGray"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="SearchBarClearButtonStyle" TargetType="Button">
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="FontSize" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Content" Value="X"/>
            <Setter Property="Height" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Width" Value="{DynamicResource SearchBarClearButtonFontSize}"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="BorderBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="Red"/>
                    <Setter Property="Background" Value="Transparent"/>
                    <Setter Property="BorderThickness" Value="10"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Checkbox template -->
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="TextElement.FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <Grid Background="{TemplateBinding Background}" Margin="{DynamicResource CheckBoxMargin}">
                            <BulletDecorator Background="Transparent">
                                <BulletDecorator.Bullet>
                                    <Grid Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                        <Border Name="Border"
                                                BorderBrush="{TemplateBinding BorderBrush}"
                                                Background="{DynamicResource ButtonBackgroundColor}"
                                                BorderThickness="1"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize *0.85}"
                                                Margin="1"
                                                SnapsToDevicePixels="True"/>
                                        <Viewbox Name="CheckMarkContainer"
                                                Width="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                Height="{DynamicResource CheckBoxBulletDecoratorSize}"
                                                HorizontalAlignment="Center"
                                                VerticalAlignment="Center"
                                                Visibility="Collapsed">
                                            <Path Name="CheckMark"
                                                  Stroke="{DynamicResource ToggleButtonOnColor}"
                                                  StrokeThickness="1.5"
                                                  Data="M 0 5 L 5 10 L 12 0"
                                                  Stretch="Uniform"/>
                                        </Viewbox>
                                    </Grid>
                                </BulletDecorator.Bullet>
                                <ContentPresenter Margin="4,0,0,0"
                                                  HorizontalAlignment="Left"
                                                  VerticalAlignment="Center"
                                                  RecognizesAccessKey="True"/>
                            </BulletDecorator>
                        </Grid>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="CheckMarkContainer" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <!--Setter TargetName="Border" Property="Background" Value="{DynamicResource ButtonBackgroundPressedColor}"/-->
                                <Setter Property="Foreground" Value="{DynamicResource ButtonBackgroundPressedColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                 </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="RadioButton">
                        <StackPanel Orientation="Horizontal" Margin="{DynamicResource CheckBoxMargin}">
                            <Viewbox Width="{DynamicResource CheckBoxBulletDecoratorSize}" Height="{DynamicResource CheckBoxBulletDecoratorSize}">
                                <Grid Width="14" Height="14">
                                    <Ellipse Name="OuterCircle"
                                            Stroke="{DynamicResource ToggleButtonOffColor}"
                                            Fill="{DynamicResource ButtonBackgroundColor}"
                                            StrokeThickness="1"
                                            Width="14"
                                            Height="14"
                                            SnapsToDevicePixels="True"/>
                                    <Ellipse Name="InnerCircle"
                                            Fill="{DynamicResource ToggleButtonOnColor}"
                                            Width="8"
                                            Height="8"
                                            Visibility="Collapsed"
                                            HorizontalAlignment="Center"
                                            VerticalAlignment="Center"/>
                                </Grid>
                            </Viewbox>
                            <ContentPresenter Margin="4,0,0,0"
                                            VerticalAlignment="Center"
                                            RecognizesAccessKey="True"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="InnerCircle" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="OuterCircle" Property="Stroke" Value="{DynamicResource ToggleButtonOnColor}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel>
                            <Grid>
                                <Border Width="45"
                                        Height="20"
                                        Background="#555555"
                                        CornerRadius="10"
                                        Margin="5,0"
                                />
                                <Border Name="WPFToggleSwitchButton"
                                        Width="25"
                                        Height="25"
                                        Background="Black"
                                        CornerRadius="12.5"
                                        HorizontalAlignment="Left"
                                />
                                <ContentPresenter Name="WPFToggleSwitchContent"
                                                  Margin="10,0,0,0"
                                                  Content="{TemplateBinding Content}"
                                                  VerticalAlignment="Center"
                                />
                            </Grid>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="false">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchLeft" />
                                    <BeginStoryboard Name="WPFToggleSwitchRight">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="0,0,0,0"
                                                    To="28,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#fff9f4f4"
                                />
                            </Trigger>
                            <Trigger Property="IsChecked" Value="true">
                                <Trigger.ExitActions>
                                    <RemoveStoryboard BeginStoryboardName="WPFToggleSwitchRight" />
                                    <BeginStoryboard Name="WPFToggleSwitchLeft">
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetProperty="Margin"
                                                    Storyboard.TargetName="WPFToggleSwitchButton"
                                                    Duration="0:0:0:0"
                                                    From="28,0,0,0"
                                                    To="0,0,0,0">
                                            </ThicknessAnimation>
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                                <Setter TargetName="WPFToggleSwitchButton"
                                        Property="Background"
                                        Value="#ff060600"
                                />
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="ColorfulToggleSwitchStyle" TargetType="{x:Type CheckBox}">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="{x:Type ToggleButton}">
                        <Grid Name="toggleSwitch">

                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>

                        <Border Grid.Column="1" Name="Border" CornerRadius="8"
                                BorderThickness="1"
                                Width="34" Height="17">
                            <Ellipse Name="Ellipse" Fill="{DynamicResource MainForegroundColor}" Stretch="Uniform"
                                    Margin="2,2,2,1"
                                    HorizontalAlignment="Left" Width="10.8"
                                    RenderTransformOrigin="0.5, 0.5">
                                <Ellipse.RenderTransform>
                                    <ScaleTransform ScaleX="1" ScaleY="1" />
                                </Ellipse.RenderTransform>
                            </Ellipse>
                        </Border>
                        </Grid>

                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource MainForegroundColor}" />
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource LinkHoverForegroundColor}"/>
                                <Setter Property="Cursor" Value="Hand" />
                                <Setter Property="Panel.ZIndex" Value="1000"/>
                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.1" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)"
                                                            To="1.0" Duration="0:0:0.1" />
                                            <DoubleAnimation Storyboard.TargetName="Ellipse"
                                                            Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)"
                                                            To="1.0" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                            <Trigger Property="ToggleButton.IsChecked" Value="False">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource MainBackgroundColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOffColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="{DynamicResource ToggleButtonOffColor}" />
                            </Trigger>

                            <Trigger Property="ToggleButton.IsChecked" Value="True">
                                <Setter TargetName="Border" Property="Background" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Border" Property="BorderBrush" Value="{DynamicResource ToggleButtonOnColor}" />
                                <Setter TargetName="Ellipse" Property="Fill" Value="White" />

                                <Trigger.EnterActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="18,2,2,2" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.EnterActions>
                                <Trigger.ExitActions>
                                    <BeginStoryboard>
                                        <Storyboard>
                                            <ThicknessAnimation Storyboard.TargetName="Ellipse"
                                                    Storyboard.TargetProperty="Margin"
                                                    To="2,2,2,1" Duration="0:0:0.1" />
                                        </Storyboard>
                                    </BeginStoryboard>
                                </Trigger.ExitActions>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="VerticalContentAlignment" Value="Center" />
        </Style>

        <Style x:Key="labelfortweaks" TargetType="{x:Type Label}">
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}" />
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}" />
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Foreground" Value="White" />
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style x:Key="BorderStyle" TargetType="Border">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource BorderColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="CornerRadius" Value="5"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="Margin" Value="5"/>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="ContextMenu">
                <Setter.Value>
                    <ContextMenu>
                        <ContextMenu.Style>
                            <Style TargetType="ContextMenu">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="ContextMenu">
                                            <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" Padding="5">
                                                <StackPanel>
                                                    <MenuItem Command="Cut" Header="剪下"/>
                                                    <MenuItem Command="Copy" Header="複製"/>
                                                    <MenuItem Command="Paste" Header="貼上"/>
                                                </StackPanel>
                                            </Border>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                            </Style>
                        </ContextMenu.Style>
                    </ContextMenu>
                </Setter.Value>
            </Setter>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource MainBackgroundColor}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Foreground" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="FontSize" Value="{DynamicResource FontSize}"/>
            <Setter Property="FontFamily" Value="{DynamicResource FontFamily}"/>
            <Setter Property="Padding" Value="5"/>
            <Setter Property="HorizontalAlignment" Value="Stretch"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
            <Setter Property="CaretBrush" Value="{DynamicResource MainForegroundColor}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="5">
                            <Grid>
                                <ScrollViewer Name="PART_ContentHost" />
                            </Grid>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Setter Property="Effect">
                <Setter.Value>
                    <DropShadowEffect ShadowDepth="5" BlurRadius="5" Opacity="{DynamicResource BorderOpacity}" Color="{DynamicResource CBorderColor}"/>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="ScrollVisibilityRectangle" TargetType="Rectangle">
            <Setter Property="Visibility" Value="Collapsed"/>
            <Style.Triggers>
                <MultiDataTrigger>
                    <MultiDataTrigger.Conditions>
                        <Condition Binding="{Binding Path=ComputedHorizontalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                        <Condition Binding="{Binding Path=ComputedVerticalScrollBarVisibility, ElementName=scrollViewer}" Value="Visible"/>
                    </MultiDataTrigger.Conditions>
                    <Setter Property="Visibility" Value="Visible"/>
                </MultiDataTrigger>
            </Style.Triggers>
        </Style>
    </Window.Resources>
    <Grid Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Name="WPFMainGrid" Width="Auto" Height="Auto" HorizontalAlignment="Stretch">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <!-- Offline banner -->
        <Border Name="WPFOfflineBanner" Grid.Row="0" Background="#8B0000" Visibility="Collapsed" Padding="6,4">
            <TextBlock Text="&#x26A0; Offline Mode - No Internet Connection" Foreground="White" FontWeight="Bold"
                HorizontalAlignment="Center" FontSize="13" Background="Transparent"/>
        </Border>
        <Grid Grid.Row="1" Background="{DynamicResource MainBackgroundColor}">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="Auto"/> <!-- Navigation buttons -->
                <ColumnDefinition Width="*"/> <!-- Search bar and buttons -->
            </Grid.ColumnDefinitions>

            <!-- Navigation Buttons Panel -->
            <StackPanel Name="NavDockPanel" Orientation="Horizontal" Grid.Column="0" Margin="5,5,10,5">
                <StackPanel Name="NavLogoPanel" Orientation="Horizontal" HorizontalAlignment="Left" Background="{DynamicResource MainBackgroundColor}" SnapsToDevicePixels="True" Margin="10,0,20,0">
                </StackPanel>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonInstallBackgroundColor}" Foreground="white" FontWeight="Bold" Name="WPFTab1BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonInstallForegroundColor}" >
                            安裝
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonTweaksBackgroundColor}" Foreground="{DynamicResource ButtonTweaksForegroundColor}" FontWeight="Bold" Name="WPFTab2BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonTweaksForegroundColor}">
                            調校
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonConfigBackgroundColor}" Foreground="{DynamicResource ButtonConfigForegroundColor}" FontWeight="Bold" Name="WPFTab3BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonConfigForegroundColor}">
                            設定
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonUpdatesBackgroundColor}" Foreground="{DynamicResource ButtonUpdatesForegroundColor}" FontWeight="Bold" Name="WPFTab4BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonUpdatesForegroundColor}">
                            更新
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="Auto" MinWidth="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonWin11ISOBackgroundColor}" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}" FontWeight="Bold" Name="WPFTab5BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonWin11ISOForegroundColor}">
                            Win11 建立工具
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
                <ToggleButton Margin="0,0,5,0" Height="{DynamicResource TabButtonHeight}" Width="Auto" MinWidth="{DynamicResource TabButtonWidth}"
                    Background="{DynamicResource ButtonAppxBackgroundColor}" Foreground="{DynamicResource ButtonAppxForegroundColor}" FontWeight="Bold" Name="WPFTab6BT">
                    <ToggleButton.Content>
                        <TextBlock FontSize="{DynamicResource TabButtonFontSize}" Background="Transparent" Foreground="{DynamicResource ButtonAppxForegroundColor}">
                            AppX 移除
                        </TextBlock>
                    </ToggleButton.Content>
                </ToggleButton>
            </StackPanel>

            <!-- Search Bar and Action Buttons -->
            <Grid Name="GridBesideNavDockPanel" Grid.Column="1" Background="{DynamicResource MainBackgroundColor}" ShowGridLines="False" Height="Auto">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="2*"/> <!-- Search bar area - priority space -->
                    <ColumnDefinition Width="Auto"/><!-- Buttons area -->
                </Grid.ColumnDefinitions>

                <Border Grid.Column="0" Margin="5,0,0,0" Width="{DynamicResource SearchBarWidth}" Height="{DynamicResource SearchBarHeight}" VerticalAlignment="Center" HorizontalAlignment="Left">
                    <Grid>
                        <TextBox
                            Width="{DynamicResource SearchBarWidth}"
                            Height="{DynamicResource SearchBarHeight}"
                            FontSize="{DynamicResource SearchBarTextBoxFontSize}"
                            VerticalAlignment="Center" HorizontalAlignment="Left"
                            BorderThickness="1"
                            Name="SearchBar"
                            Foreground="{DynamicResource MainForegroundColor}" Background="{DynamicResource MainBackgroundColor}"
                            Padding="3,3,30,0"
                            ToolTip="按 Ctrl-F 並輸入軟體名稱以篩選下方清單，按 Esc 清除篩選">
                        </TextBox>
                        <TextBlock
                            VerticalAlignment="Center" HorizontalAlignment="Right"
                            FontFamily="Segoe MDL2 Assets"
                            Foreground="{DynamicResource ButtonBackgroundSelectedColor}"
                            FontSize="{DynamicResource IconFontSize}"
                            Margin="0,0,8,0" Width="Auto" Height="Auto">&#xE721;
                        </TextBlock>
                    </Grid>
                </Border>
                <Button Grid.Column="0"
                    VerticalAlignment="Center" HorizontalAlignment="Left"
                    Name="SearchBarClearButton"
                    Style="{StaticResource SearchBarClearButtonStyle}"
                    Margin="213,0,0,0" Visibility="Collapsed">
                </Button>

                <!-- Buttons Container -->
                <StackPanel Grid.Column="1" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Margin="5,5,5,5">
                    <Button Name="ThemeButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="N/A"
                    ToolTip="變更 WinUtil 介面佈景主題"
                />
                    <Popup Name="ThemePopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=ThemeButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="自動" Name="AutoThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="跟隨 Windows 主題"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="深色" Name="DarkThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="使用深色主題"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="淺色" Name="LightThemeMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="使用淺色主題"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="FontScalingButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE8D3;"
                    ToolTip="調整字型縮放（無障礙）"
                />
                    <Popup Name="FontScalingPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=FontScalingButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch" MinWidth="200">
                            <TextBlock Text="字型縮放"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,5,10,5"
                                       FontWeight="Bold"/>
                            <Separator Margin="5,0,5,5"/>
                            <StackPanel Orientation="Horizontal" Margin="10,5,10,10">
                                <TextBlock Text="小"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="0,0,10,0"/>
                                <Slider Name="FontScalingSlider"
                                        Minimum="0.75" Maximum="2.0"
                                        Value="1.0"
                                        TickFrequency="0.25"
                                        TickPlacement="BottomRight"
                                        IsSnapToTickEnabled="True"
                                        Width="120"
                                        VerticalAlignment="Center"/>
                                <TextBlock Text="大"
                                           FontSize="{DynamicResource ButtonFontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           VerticalAlignment="Center"
                                           Margin="10,0,0,0"/>
                            </StackPanel>
                            <TextBlock Name="FontScalingValue"
                                       Text="100%"
                                       FontSize="{DynamicResource ButtonFontSize}"
                                       Foreground="{DynamicResource MainForegroundColor}"
                                       HorizontalAlignment="Center"
                                       Margin="10,0,10,5"/>
                            <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="10,0,10,10">
                                <Button Name="FontScalingResetButton"
                                        Content="重設"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                                <Button Name="FontScalingApplyButton"
                                        Content="套用"
                                        Style="{StaticResource HoverButtonStyle}"
                                        Width="60" Height="25"
                                        Margin="5,0,5,0"/>
                            </StackPanel>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button Name="SettingsButton"
                        Style="{StaticResource HoverButtonStyle}"
                        BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Foreground="{DynamicResource MainForegroundColor}"
                    FontSize="{DynamicResource SettingsIconFontSize}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,2,0"
                    FontFamily="Segoe MDL2 Assets"
                    Content="&#xE713;"/>
                    <Popup Name="SettingsPopup"
                    IsOpen="False"
                    PlacementTarget="{Binding ElementName=SettingsButton}" Placement="Bottom"
                    HorizontalAlignment="Right" VerticalAlignment="Top">
                    <Border Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource MainForegroundColor}" BorderThickness="1" CornerRadius="0" Margin="0">
                        <StackPanel Background="{DynamicResource MainBackgroundColor}" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="匯入" Name="ImportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="從匯出的檔案匯入設定。"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="匯出" Name="ExportMenuItem" Foreground="{DynamicResource MainForegroundColor}">
                                <MenuItem.ToolTip>
                                    <ToolTip Content="匯出所選項目，並將執行指令複製到剪貼簿。"/>
                                </MenuItem.ToolTip>
                            </MenuItem>
                            <Separator/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="關於" Name="AboutMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="說明文件" Name="DocumentationMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                            <MenuItem FontSize="{DynamicResource ButtonFontSize}" Header="贊助者" Name="SponsorMenuItem" Foreground="{DynamicResource MainForegroundColor}"/>
                        </StackPanel>
                    </Border>
                </Popup>

                    <Button
                    Content="&#x2212;" BorderThickness="0"
                    BorderBrush="Transparent"
                    Background="{DynamicResource MainBackgroundColor}"
                    Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                    HorizontalAlignment="Right" VerticalAlignment="Top"
                    Margin="0,0,0,0"
                    FontFamily="{DynamicResource FontFamily}"
                    Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFMinimizeButton" />

                    <Button
                    Content="&#xD7;" BorderThickness="0"
                BorderBrush="Transparent"
                Background="{DynamicResource MainBackgroundColor}"
                Width="{DynamicResource IconButtonSize}" Height="{DynamicResource IconButtonSize}"
                HorizontalAlignment="Right" VerticalAlignment="Top"
                Margin="0,0,0,0"
                FontFamily="{DynamicResource FontFamily}"
                Foreground="{DynamicResource MainForegroundColor}" FontSize="{DynamicResource CloseIconFontSize}" Name="WPFCloseButton" />
                </StackPanel>
            </Grid>
        </Grid>

        <TabControl Name="WPFTabNav" Background="Transparent" Width="Auto" Height="Auto" BorderBrush="Transparent" BorderThickness="0" Grid.Row="2" Grid.Column="0" Padding="-1">
            <TabItem Header="Install" Visibility="Collapsed" Name="WPFTab1">
                <Grid Background="Transparent" >

                    <Grid Grid.Row="0" Grid.Column="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>

                        <Grid Name="appscategory" Grid.Column="0" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>

                        <Grid Name="appspanel" Grid.Column="1" HorizontalAlignment="Stretch" VerticalAlignment="Stretch">
                        </Grid>
                    </Grid>
                </Grid>
            </TabItem>
            <TabItem Header="Tweaks" Visibility="Collapsed" Name="WPFTab2">
                <Grid>
                    <!-- Main content area with a ScrollViewer -->
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Grid.ColumnSpan="2" Margin="5">
                                <Label Content="建議選項：" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFstandard" Content=" 標準 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFminimal" Content=" 精簡 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFAdvanced" Content=" 進階 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearTweaksSelection" Content=" 清除 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledTweaks" Content=" 取得已套用調校 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="tweakspanel" Grid.Row="1">
                                <!-- Your tweakspanel content goes here -->
                            </Grid>

                            <Border Grid.ColumnSpan="2" Grid.Row="2" Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10">
                                        注意：將滑鼠移到項目上可看到更詳細的說明。請小心，許多調校會大幅修改你的系統。
                                        <LineBreak/>建議選項適合一般使用者；如果你不確定，請勿勾選其他項目！
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>
                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center" Grid.Column="0">
                            <Button Name="WPFTweaksbutton" Content="執行調校" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                            <Button Name="WPFUndoall" Content="復原所選調校" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
            <TabItem Header="Config" Visibility="Collapsed" Name="WPFTab3">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Margin="{DynamicResource TabContentMargin}">
                    <Grid Name="featurespanel" Grid.Row="1" Background="Transparent">
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Updates" Visibility="Collapsed" Name="WPFTab4">
                <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="{DynamicResource TabContentMargin}">
                    <Grid Background="Transparent" MaxWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ScrollViewer}}">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>  <!-- Row for the 3 columns -->
                            <RowDefinition Height="Auto"/>  <!-- Row for Windows Version -->
                        </Grid.RowDefinitions>

                        <!-- Three columns container -->
                        <Grid Grid.Row="0">
                            <Grid.ColumnDefinitions>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                                <ColumnDefinition Width="*"/>
                            </Grid.ColumnDefinitions>

                            <!-- Default Settings -->
                            <Border Grid.Column="0" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdefault"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="預設設定"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">預設 Windows Update 設定</Run>
                                        <LineBreak/>
                                         - 不修改 Windows 預設值
                                        <LineBreak/>
                                         - 移除所有自訂更新設定
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">注意：這會把 Windows Update 設定重設為原廠預設值，並移除對 Windows Update 所做的任何原則或自訂設定。</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Security Settings -->
                            <Border Grid.Column="1" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatessecurity"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="安全性設定"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold">平衡式安全性設定</Run>
                                        <LineBreak/>
                                         - 功能更新延後 365 天
                                        <LineBreak/>
                                         - 安全性更新於 4 天後安裝
                                        <LineBreak/>
                                         - 阻止 Windows Update 安裝驅動程式
                                        <LineBreak/><LineBreak/>
                                        <Run FontWeight="SemiBold">功能更新：</Run> 新功能與潛在錯誤
                                        <LineBreak/>
                                        <Run FontWeight="SemiBold">安全性更新：</Run> 重大安全性修補
                                    <LineBreak/><LineBreak/>
                                    <Run FontStyle="Italic" FontSize="11">注意：這僅適用於可使用群組原則的 Pro 版系統。</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>

                            <!-- Disable Updates -->
                            <Border Grid.Column="2" Style="{StaticResource BorderStyle}">
                                <StackPanel>
                                    <Button Name="WPFUpdatesdisable"
                                            FontSize="{DynamicResource ConfigTabButtonFontSize}"
                                            Content="停用所有更新"
                                            Foreground="Red"
                                            Margin="10,5"
                                            Padding="10"/>
                                    <TextBlock Margin="10"
                                             TextWrapping="Wrap"
                                             Foreground="{DynamicResource MainForegroundColor}">
                                        <Run FontWeight="Bold" Foreground="Red">!! 不建議 !!</Run>
                                        <LineBreak/>
                                         - 停用所有 Windows Update
                                        <LineBreak/>
                                         - 增加安全性風險
                                        <LineBreak/>
                                         - 僅用於隔離的系統
                                        <LineBreak/><LineBreak/>
                                        <Run FontStyle="Italic" FontSize="11">警告：沒有安全性更新，你的系統將處於風險之中。</Run>
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>

                        <!-- Future Implementation: Add Windows Version to updates panel -->
                        <Grid Name="updatespanel" Grid.Row="1" Background="Transparent">
                        </Grid>
                    </Grid>
                </ScrollViewer>
            </TabItem>
            <TabItem Header="Win11ISO" Visibility="Collapsed" Name="WPFTab5">
                <Grid Name="Win11ISOPanel" Margin="{DynamicResource TabContentMargin}" Background="Transparent">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>  <!-- Steps 1-4 -->
                        <RowDefinition Height="*"/>     <!-- Log / Status -->
                    </Grid.RowDefinitions>

                    <!-- Steps 1-4 -->
                    <StackPanel Grid.Row="0">

                            <!-- ─── STEP 1 : Select Windows 11 ISO ─────────────── -->
                            <Grid Name="WPFWin11ISOSelectSection" Margin="5" HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <!-- Left: File Selector -->
                                <StackPanel Grid.Column="0" Margin="5,5,15,5">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        步驟 1 - 選擇 Windows 11 ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,6">瀏覽並選擇本機儲存的 Windows 11 ISO 檔案。僅支援從 Microsoft 官方下載的 ISO。</TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}" Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" FontStyle="Italic">
                                        <Run FontWeight="Bold">注意：</Run> 此功能僅適用於全新安裝的 Windows。
                                    </TextBlock>
                                    <Grid>
                                        <Grid.ColumnDefinitions>
                                            <ColumnDefinition Width="*"/>
                                            <ColumnDefinition Width="Auto"/>
                                        </Grid.ColumnDefinitions>
                                        <TextBox Grid.Column="0"
                                                 Name="WPFWin11ISOPath"
                                                 IsReadOnly="True"
                                                 VerticalAlignment="Center"
                                                 Padding="6,4"
                                                 Margin="0,0,6,0"
                                                 Text="未選擇 ISO..."
                                                 Foreground="{DynamicResource MainForegroundColor}"
                                                 Background="{DynamicResource MainBackgroundColor}"/>
                                        <Button Grid.Column="1"
                                                Name="WPFWin11ISOBrowseButton"
                                                Content="瀏覽"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </Grid>
                                    <TextBlock Name="WPFWin11ISOFileInfo"
                                               FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               Margin="0,8,0,0"
                                               TextWrapping="Wrap"
                                               Visibility="Collapsed"/>
                                </StackPanel>

                                <!-- Right: Download guidance -->
                                <Border Grid.Column="1"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Margin="5" Padding="15">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="OrangeRed" Margin="0,0,0,10">
                                            !!警告!! 你必須使用 Microsoft 官方 ISO
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">直接從 Microsoft.com 下載 Windows 11 ISO。不支援第三方、預先修改或非官方的映像，可能導致失敗。</TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,6">
                                            在 Microsoft 下載頁面選擇：
                                        </TextBlock>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="12,0,0,12">
                                            - 版本：Windows 11
                                            <LineBreak/>- 語言：你偏好的語言
                                            <LineBreak/>- 架構：64 位元 (x64)
                                        </TextBlock>
                                        <Button Name="WPFWin11ISODownloadLink"
                                                Content="開啟 Microsoft 下載頁面"
                                                HorizontalAlignment="Left"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- ─── STEP 2 : Mount & Verify ISO ──────────────────── -->
                            <Grid Name="WPFWin11ISOMountSection"
                                  Margin="5"
                                  Visibility="Collapsed"
                                  HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>

                                <StackPanel Grid.Column="0" Margin="0,0,20,0" VerticalAlignment="Top">
                                    <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                        步驟 2 - 掛載並驗證 ISO
                                    </TextBlock>
                                    <TextBlock FontSize="{DynamicResource FontSize}"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               TextWrapping="Wrap" Margin="0,0,0,12" MaxWidth="320">掛載 ISO，並在進行任何修改前確認其中含有有效的 Windows 11 install.wim。</TextBlock>
                                    <Button Name="WPFWin11ISOMountButton"
                                            Content="掛載並驗證 ISO"
                                            HorizontalAlignment="Left"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <CheckBox Name="WPFWin11ISOInjectDrivers"
                                              Content="注入目前系統驅動程式"
                                              FontSize="{DynamicResource FontSize}"
                                              Foreground="{DynamicResource MainForegroundColor}"
                                              IsChecked="False"
                                              Margin="0,8,0,0"
                                              ToolTip="從本機匯出所有驅動程式並注入 install.wim 與 boot.wim。建議用於 NVMe 或網路控制器不受支援的系統。"/>
                                </StackPanel>

                                <!-- Verification results panel -->
                                <Border Grid.Column="1"
                                        Name="WPFWin11ISOVerifyResultPanel"
                                        Background="{DynamicResource MainBackgroundColor}"
                                        BorderBrush="{DynamicResource BorderColor}"
                                        BorderThickness="1" CornerRadius="5"
                                        Padding="12" Margin="0,0,0,0"
                                        Visibility="Collapsed">
                                    <StackPanel>
                                        <TextBlock Name="WPFWin11ISOMountDriveLetter"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock Name="WPFWin11ISOArchLabel"
                                                   FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,0,0,4"/>
                                        <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   Margin="0,6,0,4">
                                            選擇版本：
                                        </TextBlock>
                                        <ComboBox Name="WPFWin11ISOEditionComboBox"
                                                  FontSize="{DynamicResource FontSize}"
                                                  Foreground="{DynamicResource MainForegroundColor}"
                                                  Background="{DynamicResource MainBackgroundColor}"
                                                  HorizontalAlignment="Left"
                                                  Margin="0,0,0,0"/>
                                    </StackPanel>
                                </Border>
                            </Grid>

                            <!-- ─── STEP 3 : Modify install.wim ───────────────────── -->
                            <StackPanel Name="WPFWin11ISOModifySection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <TextBlock FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                           Foreground="{DynamicResource MainForegroundColor}" Margin="0,0,0,8">
                                    步驟 3 - 修改 install.wim
                                </TextBlock>
                                <TextBlock FontSize="{DynamicResource FontSize}"
                                           Foreground="{DynamicResource MainForegroundColor}"
                                           TextWrapping="Wrap" Margin="0,0,0,12">ISO 內容會被解壓縮到暫存工作目錄，install.wim 會被修改（移除元件、套用調校），接著重新封裝。此程序視硬體效能可能需要數分鐘。</TextBlock>
                                <Button Name="WPFWin11ISOModifyButton"
                                        Content="執行 Windows ISO 修改與建立工具"
                                        HorizontalAlignment="Left"
                                        Width="Auto" Padding="12,0"
                                        Height="{DynamicResource ButtonHeight}"/>
                            </StackPanel>

                            <!-- ─── STEP 4 : Output Options ───────────────────────── -->
                            <StackPanel Name="WPFWin11ISOOutputSection"
                                        Margin="5"
                                        Visibility="Collapsed"
                                        HorizontalAlignment="Left" MinWidth="{DynamicResource ButtonWidth}">
                                <!-- Header row: title + Clean & Reset button -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock Grid.Column="0" FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                               Foreground="{DynamicResource MainForegroundColor}"
                                               VerticalAlignment="Center">
                                        步驟 4 - 輸出：你想如何處理修改後的映像？
                                    </TextBlock>
                                    <Button Grid.Column="1"
                                            Name="WPFWin11ISOCleanResetButton"
                                            Content="清除並重設"
                                            Foreground="OrangeRed"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"
                                            ToolTip="刪除暫存工作目錄並將介面重設回步驟 1"
                                            Margin="12,0,0,0"/>
                                </Grid>

                                <!-- ── Choice prompt buttons ── -->
                                <Grid Margin="0,0,0,12">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="16"/>
                                        <ColumnDefinition Width="*"/>
                                    </Grid.ColumnDefinitions>
                                    <Button Grid.Column="0"
                                            Name="WPFWin11ISOChooseISOButton"
                                            Content="另存為 ISO 檔"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                    <Button Grid.Column="2"
                                            Name="WPFWin11ISOChooseUSBButton"
                                            Content="直接寫入 USB 隨身碟（會清除磁碟）"
                                            Foreground="OrangeRed"
                                            HorizontalAlignment="Stretch"
                                            Width="Auto" Padding="12,0"
                                            Height="{DynamicResource ButtonHeight}"/>
                                </Grid>

                                <!-- ── USB write sub-panel (revealed on USB choice) ── -->
                                <Border Name="WPFWin11ISOOptionUSB"
                                        Style="{StaticResource BorderStyle}"
                                        Visibility="Collapsed"
                                        Margin="0,8,0,0">
                                    <StackPanel>
                                        <TextBlock FontSize="{DynamicResource FontSize}"
                                                   Foreground="{DynamicResource MainForegroundColor}"
                                                   TextWrapping="Wrap" Margin="0,0,0,8">
                                            <Run FontWeight="Bold" Foreground="OrangeRed">!! 所選 USB 磁碟上的所有資料將被永久清除 !!</Run>
                                            <LineBreak/>
                                            在下方選擇一個卸除式 USB 磁碟，然後點擊「清除並寫入」。
                                        </TextBlock>
                                        <!-- USB drive selector row -->
                                        <Grid Margin="0,0,0,8">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <ComboBox Grid.Column="0"
                                                      Name="WPFWin11ISOUSBDriveComboBox"
                                                      Foreground="{DynamicResource MainForegroundColor}"
                                                      Background="{DynamicResource MainBackgroundColor}"
                                                      VerticalAlignment="Center"
                                                      Margin="0,0,6,0"/>
                                            <Button Grid.Column="1"
                                                    Name="WPFWin11ISORefreshUSBButton"
                                                    Content="重新整理"
                                                    Width="Auto" Padding="8,0"
                                                    Height="{DynamicResource ButtonHeight}"/>
                                        </Grid>
                                        <Button Name="WPFWin11ISOWriteUSBButton"
                                                Content="清除並寫入 USB"
                                                Foreground="OrangeRed"
                                                HorizontalAlignment="Stretch"
                                                Width="Auto" Padding="12,0"
                                                Height="{DynamicResource ButtonHeight}"
                                                Margin="0,0,0,10"/>
                                    </StackPanel>
                                </Border>
                            </StackPanel>

                    </StackPanel>

                    <!-- Status Log (fills remaining height) -->
                    <Grid Grid.Row="1" Margin="5">
                        <Grid.RowDefinitions>
                            <RowDefinition Height="Auto"/>
                            <RowDefinition Height="*"/>
                        </Grid.RowDefinitions>
                        <TextBlock Grid.Row="0"
                                   FontSize="{DynamicResource FontSize}" FontWeight="Bold"
                                   Foreground="{DynamicResource MainForegroundColor}"
                                   Margin="0,0,0,4">
                            狀態記錄
                        </TextBlock>
                        <TextBox Grid.Row="1"
                                 Name="WPFWin11ISOStatusLog"
                                 IsReadOnly="True"
                                 TextWrapping="Wrap"
                                 VerticalScrollBarVisibility="Visible"
                                 VerticalAlignment="Stretch"
                                 Padding="6"
                                 Background="{DynamicResource MainBackgroundColor}"
                                 Foreground="{DynamicResource MainForegroundColor}"
                                 BorderBrush="{DynamicResource BorderColor}"
                                 BorderThickness="1"
                                 Text="已就緒。請選擇一個 Windows 11 ISO 以開始。"/>
                    </Grid>

                </Grid>
            </TabItem>
            <TabItem Header="AppX" Visibility="Collapsed" Name="WPFTab6">
                <Grid>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="*" />
                        <RowDefinition Height="Auto" />
                    </Grid.RowDefinitions>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Grid.Row="0" Margin="{DynamicResource TabContentMargin}">
                        <Grid Background="Transparent">
                            <Grid.RowDefinitions>
                                <RowDefinition Height="Auto"/>
                                <RowDefinition Height="*"/>
                                <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>

                            <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Vertical" Grid.Row="0" Grid.Column="0" Margin="5">
                                <Label Content="選項：" FontSize="{DynamicResource FontSize}" VerticalAlignment="Center" Margin="2"/>
                                <StackPanel Orientation="Horizontal" HorizontalAlignment="Left" Margin="0,2,0,0">
                                    <Button Name="WPFDefaultAppxSelection" Content=" 預設 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFGetInstalledAppx" Content=" 取得已安裝 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFSelectAllAppx" Content=" 全選 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                    <Button Name="WPFClearAppxSelection" Content=" 清除選取 " Margin="2" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                                </StackPanel>
                            </StackPanel>

                            <Grid Name="appxpanel" Grid.Row="1">
                            </Grid>

                            <Border Grid.Row="2" Style="{StaticResource BorderStyle}" Margin="5,15,5,5">
                                <StackPanel Background="{DynamicResource MainBackgroundColor}" Orientation="Horizontal" HorizontalAlignment="Left">
                                    <TextBlock Padding="10" TextWrapping="Wrap" Foreground="{DynamicResource MainForegroundColor}">
                                        注意：勾選你想移除的預先安裝 Windows AppX 套件，然後點擊「移除所選」。
                                        <LineBreak/>這些套件會針對目前使用者及所有新使用者設定檔移除。
                                    </TextBlock>
                                </StackPanel>
                            </Border>
                        </Grid>
                    </ScrollViewer>

                    <Border Grid.Row="1" Background="{DynamicResource MainBackgroundColor}" BorderBrush="{DynamicResource BorderColor}" BorderThickness="1" CornerRadius="5" HorizontalAlignment="Stretch" Padding="10">
                        <WrapPanel Orientation="Horizontal" HorizontalAlignment="Left" VerticalAlignment="Center">
                            <Button Name="WPFRemoveSelectedAppx" Content="移除所選" Margin="5" Width="{DynamicResource ButtonWidth}" Height="{DynamicResource ButtonHeight}"/>
                        </WrapPanel>
                    </Border>
                </Grid>
            </TabItem>
        </TabControl>
    </Grid>
</Window>

'@
$WinUtilAutounattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <!--https://schneegans.de/windows/unattend-generator/?LanguageMode=Interactive&ProcessorArchitecture=amd64&BypassRequirementsCheck=true&ComputerNameMode=Random&CompactOsMode=Default&TimeZoneMode=Implicit&PartitionMode=Interactive&DiskAssertionMode=Skip&WindowsEditionMode=Interactive&InstallFromMode=Automatic&PEMode=Default&UserAccountMode=InteractiveLocal&PasswordExpirationMode=Unlimited&LockoutMode=Default&HideFiles=Hidden&ClassicContextMenu=true&LaunchToThisPC=true&ShowEndTask=true&TaskbarSearch=Hide&TaskbarIconsMode=Empty&DisableWidgets=true&LeftTaskbar=true&HideTaskViewButton=true&StartTilesMode=Default&StartPinsMode=Empty&EnableLongPaths=true&HideEdgeFre=true&DisableEdgeStartupBoost=true&DeleteWindowsOld=true&EffectsMode=Default&DeleteEdgeDesktopIcon=true&DesktopIconsMode=Default&StartFoldersMode=Default&WifiMode=Skip&ExpressSettings=DisableAll&LockKeysMode=Configure&CapsLockInitial=Off&CapsLockBehavior=Toggle&NumLockInitial=On&NumLockBehavior=Toggle&ScrollLockInitial=Off&ScrollLockBehavior=Toggle&StickyKeysMode=Disabled&ColorMode=Custom&SystemColorTheme=Dark&AppsColorTheme=Dark&AccentColor=%230078d4&WallpaperMode=Default&LockScreenMode=Default&WdacMode=Skip&AppLockerMode=Skip-->
    <settings pass="offlineServicing"></settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <UseConfigurationSet>false</UseConfigurationSet>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="generalize"></settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\Specialize.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\DefaultUser.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="auditSystem"></settings>
    <settings pass="auditUser"></settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <ExtractScript>
param(
    [xml]$Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
        </ExtractScript>
        <File path="C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml">
&lt;LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"&gt;
    &lt;CustomTaskbarLayoutCollection PinListPlacement="Replace"&gt;
        &lt;defaultlayout:TaskbarLayout&gt;
            &lt;taskbar:TaskbarPinList&gt;
                &lt;taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /&gt;
            &lt;/taskbar:TaskbarPinList&gt;
        &lt;/defaultlayout:TaskbarLayout&gt;
    &lt;/CustomTaskbarLayoutCollection&gt;
&lt;/LayoutModificationTemplate&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.vbs">
HKU = &amp;H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")

If reg.EnumKey(HKU, "", sids) = 0 Then
    If Not IsNull(sids) Then
        For Each sid In sids
            key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
            name = "LockedStartLayout"
            If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
                reg.SetDWORDValue HKU, key, name, 0
            End If
        Next
    End If
End If
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.xml">
&lt;Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"&gt;
    &lt;Triggers&gt;
        &lt;EventTrigger&gt;
            &lt;Enabled&gt;true&lt;/Enabled&gt;
            &lt;Subscription&gt;&amp;lt;QueryList&amp;gt;&amp;lt;Query Id="0" Path="Application"&amp;gt;&amp;lt;Select Path="Application"&amp;gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&amp;lt;/Select&amp;gt;&amp;lt;/Query&amp;gt;&amp;lt;/QueryList&amp;gt;&lt;/Subscription&gt;
        &lt;/EventTrigger&gt;
    &lt;/Triggers&gt;
    &lt;Principals&gt;
        &lt;Principal id="Author"&gt;
            &lt;UserId&gt;S-1-5-18&lt;/UserId&gt;
            &lt;RunLevel&gt;LeastPrivilege&lt;/RunLevel&gt;
        &lt;/Principal&gt;
    &lt;/Principals&gt;
    &lt;Settings&gt;
        &lt;MultipleInstancesPolicy&gt;IgnoreNew&lt;/MultipleInstancesPolicy&gt;
        &lt;DisallowStartIfOnBatteries&gt;false&lt;/DisallowStartIfOnBatteries&gt;
        &lt;StopIfGoingOnBatteries&gt;false&lt;/StopIfGoingOnBatteries&gt;
        &lt;AllowHardTerminate&gt;true&lt;/AllowHardTerminate&gt;
        &lt;StartWhenAvailable&gt;false&lt;/StartWhenAvailable&gt;
        &lt;RunOnlyIfNetworkAvailable&gt;false&lt;/RunOnlyIfNetworkAvailable&gt;
        &lt;IdleSettings&gt;
            &lt;StopOnIdleEnd&gt;true&lt;/StopOnIdleEnd&gt;
            &lt;RestartOnIdle&gt;false&lt;/RestartOnIdle&gt;
        &lt;/IdleSettings&gt;
        &lt;AllowStartOnDemand&gt;true&lt;/AllowStartOnDemand&gt;
        &lt;Enabled&gt;true&lt;/Enabled&gt;
        &lt;Hidden&gt;false&lt;/Hidden&gt;
        &lt;RunOnlyIfIdle&gt;false&lt;/RunOnlyIfIdle&gt;
        &lt;WakeToRun&gt;false&lt;/WakeToRun&gt;
        &lt;ExecutionTimeLimit&gt;PT72H&lt;/ExecutionTimeLimit&gt;
        &lt;Priority&gt;7&lt;/Priority&gt;
    &lt;/Settings&gt;
    &lt;Actions Context="Author"&gt;
        &lt;Exec&gt;
            &lt;Command&gt;C:\Windows\System32\wscript.exe&lt;/Command&gt;
            &lt;Arguments&gt;C:\Windows\Setup\Scripts\UnlockStartLayout.vbs&lt;/Arguments&gt;
        &lt;/Exec&gt;
    &lt;/Actions&gt;
&lt;/Task&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\SetStartPins.ps1">
$json = '{"pinnedList":[]}';
if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) {
    return;
}
$key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';
New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
        </File>
        <File path="C:\Windows\Setup\Scripts\SetColorTheme.ps1">
$lightThemeSystem = 0;
$lightThemeApps = 0;
$accentColorOnStart = 0;
$enableTransparency = 0;
$htmlAccentColor = '#0078D4';
&amp; {
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        Force = $true;
        Type = 'DWord';
    };
    Set-ItemProperty @params -Name 'SystemUsesLightTheme' -Value $lightThemeSystem;
    Set-ItemProperty @params -Name 'AppsUseLightTheme' -Value $lightThemeApps;
    Set-ItemProperty @params -Name 'ColorPrevalence' -Value $accentColorOnStart;
    Set-ItemProperty @params -Name 'EnableTransparency' -Value $enableTransparency;
};
&amp; {
    Add-Type -AssemblyName 'System.Drawing';
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml( $htmlAccentColor );

    function ConvertTo-DWord {
        param(
            [System.Drawing.Color]
            $Color
        );

        [byte[]]$bytes = @(
            $Color.R;
            $Color.G;
            $Color.B;
            $Color.A;
        );
        return [System.BitConverter]::ToUInt32( $bytes, 0);
    }

    $startColor = [System.Drawing.Color]::FromArgb( 0xD2, $accentColor );
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';
        Name = 'AccentPalette';
    };
    $palette = Get-ItemPropertyValue @params;
    $index = 20;
    $palette[ $index++ ] = $accentColor.R;
    $palette[ $index++ ] = $accentColor.G;
    $palette[ $index++ ] = $accentColor.B;
    $palette[ $index++ ] = $accentColor.A;
    Set-ItemProperty @params -Value $palette -Type 'Binary' -Force;
};
        </File>
        <File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
    {
        reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f;
    };
    {
        net.exe accounts /maxpwage:UNLIMITED;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f;
        [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );
    };
    {
        Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw );
    };
    {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
    };
    {
        Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetStartPins.ps1';
    };
    {
        reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
    {
        [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );
    };
    {
        Remove-Item -Path "${env:USERPROFILE}\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
        Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
    };
    {
        $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
        if( Test-Path $taskbarPath ) {
            Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force;
        }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesRemovedChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetColorTheme.ps1';
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /v Enabled /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v AllAppsViewMode /t REG_DWORD /d 2 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_AccountNotifications /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowAllPinsList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowFrequentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowRecentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f;
    };
    {
        Restart-Computer -Force;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "$env:TEMP\UserOnce.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
    {
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f;
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f;
    };
    {
        foreach( $root in 'Registry::HKU\.DEFAULT', 'Registry::HKU\DefaultUser' ) {
          Set-ItemProperty -LiteralPath "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'String' -Value 2 -Force;
        }
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
    {
        Remove-Item -LiteralPath @(
          'C:\Windows\Panther\unattend.xml';
          'C:\Windows\Panther\unattend-original.xml';
          'C:\Windows\Setup\Scripts\Wifi.xml';
          'C:\Windows.old';
        ) -Recurse -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f;
        reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
        $services = @{ BITS = 'Manual'; wuauserv = 'Manual'; UsoSvc = 'Automatic'; WaaSMedicSvc = 'Manual' };
        foreach ($name in $services.Keys) {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction SilentlyContinue;
        }
    };
    {
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /v IsEducationEnvironment /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
    };
    {
        $recallFeature = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -like 'Recall' };
        if( $recallFeature ) {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -ErrorAction SilentlyContinue;
        }
    };
    {
        $viveDir = Join-Path $env:TEMP 'ViVeTool';
        $viveZip = Join-Path $env:TEMP 'ViVeTool.zip';
        Invoke-WebRequest 'https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip' -OutFile $viveZip;
        Expand-Archive -Path $viveZip -DestinationPath $viveDir -Force;
        Remove-Item -Path $viveZip -Force;
        Start-Process -FilePath (Join-Path $viveDir 'ViVeTool.exe') -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow;
        Remove-Item -Path $viveDir -Recurse -Force;
    };
    {
        Start-Process C:\Windows\System32\OneDriveSetup.exe -ArgumentList /uninstall
    };
    {
        if( (Get-BitLockerVolume -MountPoint $Env:SystemDrive).ProtectionStatus -eq 'On' ) {
            Disable-BitLocker -MountPoint $Env:SystemDrive;
        }
    };
    {
        if( (bcdedit | Select-String 'path').Count -eq 2 ) {
            bcdedit /set `{bootmgr`} timeout 0;
        }
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
        </File>
    </Extensions>
</unattend>

'@
Write-Host @"
    CCCCCCCCCCCCCTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
 CCC::::::::::::CT:::::::::::::::::::::TT:::::::::::::::::::::T
CC:::::::::::::::CT:::::::::::::::::::::TT:::::::::::::::::::::T
C:::::CCCCCCCC::::CT:::::TT:::::::TT:::::TT:::::TT:::::::TT:::::T
C:::::C       CCCCCCTTTTTT  T:::::T  TTTTTTTTTTTT  T:::::T  TTTTTT
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C       CCCCCC        T:::::T                T:::::T
C:::::CCCCCCCC::::C      TT:::::::TT            TT:::::::TT
CC:::::::::::::::C       T:::::::::T            T:::::::::T
CCC::::::::::::C         T:::::::::T            T:::::::::T
  CCCCCCCCCCCCC          TTTTTTTTTTT            TTTTTTTTTTT

====Chris Titus Tech=====
=====Windows Toolbox=====
"@

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}
$sync.preferences.theme = "Auto"
$sync.preferences.packagemanager = "Winget"

if ($Preset) {
    Initialize-WinUtilRunspacePool | Out-Null

    # Selects the tweaks from $Preset varible
    Update-WinUtilSelections -flatJson $sync.configs.preset.$Preset

    # Run tweaks that were selected by Update-WinUtilSelections
    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

if ($Config) {
    Initialize-WinUtilRunspacePool | Out-Null

    Invoke-WPFImpex -type "import" -Config $Config

    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting WinUtil..." -ForegroundColor Red
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        $null = $hwnd, $wParam, $lParam
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Build only the default tab before first paint; other tabs initialize on first activation.
$sync.InitializedTabs = @{}
Initialize-WinUtilTabContent -TabName "Install"

# Future implementation: Add Windows Version to updates panel
#Invoke-WPFUIElements -configVariable $sync.configs.updates -targetGridName "updatespanel" -columncount 1

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Choco"
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Winget"
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

        if ($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "TextBlock") {
            if ($sync["$psitem"].Name.EndsWith("Link")) {
                $sync["$psitem"].Add_MouseUp({
                    [System.Object]$Sender = $args[0]
                    Start-Process $Sender.ToolTip -ErrorAction Stop
                })
            }

        }
    }
}

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        $keyEventArgs = $_
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
    $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
        $keyEventArgs = $_
        switch ($_.Key) {
            { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
            { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
$sync["Form"].Add_PreviewMouseWheel({
    if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
})

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        }
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications."

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "Offline mode detected - Install tab disabled." -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab2BT"  # Switch to Tweaks tab instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true }) | Out-Null
})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "AppX" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

$sync["Form"].Add_Loaded({
    param($e)
    $null = $e
    $sync.Form.MinWidth = "1000"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
Author   : <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
UI       : <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace : <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>
GitHub   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Version  : <a href="https://github.com/ChrisTitusTech/winutil/releases/tag/$($sync.version)">$($sync.version)</a>
"@
    Show-CustomDialog -Title "About" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://winutil.christitus.com/"
})
$sync["SponsorMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">Current sponsors for ChrisTitusTech:</a>
"@
    $authorInfo += "`n"
    try {
        $sponsors = Invoke-WinUtilSponsors
        foreach ($sponsor in $sponsors) {
            $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
        }
    } catch {
        $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
    }
    Show-CustomDialog -Title "Sponsors" -Message $authorInfo -EnableScroll $true
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# ── Win11ISO Tab button handlers ──────────────────────────────────────────────

$sync["WPFWin11ISOBrowseButton"].Add_Click({
    Invoke-WinUtilISOBrowse
})

$sync["WPFWin11ISODownloadLink"].Add_Click({
    Start-Process "https://www.microsoft.com/software-download/windows11"
})

$sync["WPFWin11ISOMountButton"].Add_Click({
    Invoke-WinUtilISOMountAndVerify
})

$sync["WPFWin11ISOModifyButton"].Add_Click({
    Invoke-WinUtilISOModify
})

$sync["WPFWin11ISOChooseISOButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
    Invoke-WinUtilISOExport
})

$sync["WPFWin11ISOChooseUSBButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISORefreshUSBButton"].Add_Click({
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISOWriteUSBButton"].Add_Click({
    Invoke-WinUtilISOWriteUSB
})

$sync["WPFWin11ISOCleanResetButton"].Add_Click({
    Invoke-WinUtilISOCleanAndReset
})

# ──────────────────────────────────────────────────────────────────────────────

$sync["Form"].ShowDialog() | out-null
Stop-Transcript

