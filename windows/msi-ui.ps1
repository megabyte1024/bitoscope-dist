# SPDX-License-Identifier: MIT

Set-StrictMode -Version 3

function New-MsiUiTables($Product, [string]$PerMachine) {
    $dialog = New-MsiTable 'Dialog' @('Dialog', 'HCentering', 'VCentering', 'Width', 'Height', 'Attributes', 'Title', 'Control_First',
        'Control_Default', 'Control_Cancel') @('s72', 'i2', 'i2', 'i2', 'i2', 'I4', 'L128', 's50', 'S50', 'S50') @('Dialog')
    $control = New-MsiTable 'Control' @('Dialog_', 'Control', 'Type', 'X', 'Y', 'Width', 'Height', 'Attributes', 'Property', 'Text',
        'Control_Next', 'Help') @('s72', 's50', 's20', 'i2', 'i2', 'i2', 'i2', 'I4', 'S50', 'L0', 'S50', 'L50') @('Dialog_', 'Control')
    $event = New-MsiTable 'ControlEvent' @('Dialog_', 'Control_', 'Event', 'Argument', 'Condition', 'Ordering') `
        @('s72', 's50', 's50', 's255', 'S255', 'I2') @('Dialog_', 'Control_', 'Event', 'Argument', 'Condition')
    $mapping = New-MsiTable 'EventMapping' @('Dialog_', 'Control_', 'Event', 'Attribute') @('s72', 's50', 's50', 's50') `
        @('Dialog_', 'Control_', 'Event')
    $radio = New-MsiTable 'RadioButton' @('Property', 'Order', 'Value', 'X', 'Y', 'Width', 'Height', 'Text', 'Help') `
        @('s72', 'i2', 's64', 'i2', 'i2', 'i2', 'i2', 'L0', 'L50') @('Property', 'Order')
    $style = New-MsiTable 'TextStyle' @('TextStyle', 'FaceName', 'Size', 'Color', 'StyleBits') @('s72', 's32', 'i2', 'I4', 'I2') @('TextStyle')
    $actionText = New-MsiTable 'ActionText' @('Action', 'Description', 'Template') @('s72', 'L64', 'L128') @('Action')

    function Add-Dialog($name, $width, $height, $attributes, $title, $first, $default, $cancel) {
        Add-MsiRow $dialog @($name, 50, 50, $width, $height, $attributes, $title, $first, $default, $cancel)
    }
    function Add-Control($dialogName, $id, $type, $x, $y, $width, $height, $attributes, $property, $text, $next) {
        Add-MsiRow $control @($dialogName, $id, $type, $x, $y, $width, $height, $attributes, $property, $text, $next, $null)
    }
    function Add-Event($dialogName, $controlName, $name, $argument, $condition, $order) {
        Add-MsiRow $event @($dialogName, $controlName, $name, $argument, $condition, $order)
    }
    function Add-Frame($dialogName, $title, $text) {
        Add-Control $dialogName 'Title' 'Text' 15 12 340 24 3 $null "{\Title}$title" $null
        Add-Control $dialogName 'Intro' 'Text' 15 44 340 30 3 $null $text $null
        Add-Control $dialogName 'Line' 'Line' 0 234 370 0 1 $null $null $null
    }
    function Add-Button($dialogName, $id, $x, $text, $next) {
        Add-Control $dialogName $id 'PushButton' $x 243 $(if ($x -eq 300) { 56 } else { 62 }) 17 3 $null $text $next
    }

    Add-MsiRow $style @('DefaultFont', 'Tahoma', 8, 0, 0)
    Add-MsiRow $style @('Title', 'Tahoma', 12, 0, 1)

    Add-Dialog 'ScopeDlg' 370 270 3 '[ProductName] Setup' 'Choice' 'Next' 'Cancel'
    Add-Frame 'ScopeDlg' 'Install [ProductName] [ProductVersion]' 'Choose who will use [ProductName].'
    Add-Control 'ScopeDlg' 'Choice' 'RadioButtonGroup' 25 85 320 52 3 'INSTALLSCOPE' $null 'Next'
    Add-MsiRow $radio @('INSTALLSCOPE', 1, 'perUser', 0, 0, 320, 22, 'Only for me (no administrator rights needed)', $null)
    Add-MsiRow $radio @('INSTALLSCOPE', 2, 'perMachine', 0, 28, 320, 22, 'All users of this computer (needs administrator rights)', $null)
    Add-Button 'ScopeDlg' 'Next' 232 '&Next >' 'Cancel'
    Add-Button 'ScopeDlg' 'Cancel' 300 'Cancel' 'Choice'
    Add-Event 'ScopeDlg' 'Next' '[ALLUSERS]' '1' 'INSTALLSCOPE="perMachine"' 1
    Add-Event 'ScopeDlg' 'Next' '[MSIINSTALLPERUSER]' '{}' 'INSTALLSCOPE="perMachine"' 2
    Add-Event 'ScopeDlg' 'Next' '[ALLUSERS]' '2' 'INSTALLSCOPE="perUser"' 3
    Add-Event 'ScopeDlg' 'Next' '[MSIINSTALLPERUSER]' '1' 'INSTALLSCOPE="perUser"' 4
    Add-Event 'ScopeDlg' 'Next' 'DoAction' 'SetInstallFolderPerMachine' 'INSTALLSCOPE="perMachine"' 5
    Add-Event 'ScopeDlg' 'Next' 'DoAction' 'SetInstallFolderPerUser' 'INSTALLSCOPE="perUser"' 6
    Add-Event 'ScopeDlg' 'Next' 'NewDialog' 'FolderDlg' '1' 7
    Add-Event 'ScopeDlg' 'Cancel' 'SpawnDialog' 'CancelDlg' '1' 1

    Add-Dialog 'FolderDlg' 370 270 3 '[ProductName] Setup' 'Folder' 'Install' 'Cancel'
    Add-Frame 'FolderDlg' 'Install folder' 'Setup installs [ProductName] into this folder:'
    Add-Control 'FolderDlg' 'Folder' 'Edit' 25 90 245 18 3 'INSTALLFOLDER' '{260}' 'Browse'
    Add-Control 'FolderDlg' 'Browse' 'PushButton' 278 89 70 19 3 $null 'B&rowse...' 'Back'
    Add-Button 'FolderDlg' 'Back' 164 '< &Back' 'Install'
    Add-Button 'FolderDlg' 'Install' 232 '&Install' 'Cancel'
    Add-Button 'FolderDlg' 'Cancel' 300 'Cancel' 'Folder'
    Add-Event 'FolderDlg' 'Back' 'NewDialog' 'ScopeDlg' '1' 1
    Add-Event 'FolderDlg' 'Browse' '[_BrowseProperty]' 'INSTALLFOLDER' '1' 1
    Add-Event 'FolderDlg' 'Browse' 'SpawnDialog' 'BrowseDlg' '1' 2
    Add-Event 'FolderDlg' 'Install' 'SetTargetPath' 'INSTALLFOLDER' '1' 1
    Add-Event 'FolderDlg' 'Install' 'EndDialog' 'Return' '1' 2
    Add-Event 'FolderDlg' 'Cancel' 'SpawnDialog' 'CancelDlg' '1' 1

    Add-Dialog 'BrowseDlg' 370 270 3 '[ProductName] Setup' 'PathEdit' 'OK' 'Cancel'
    Add-Frame 'BrowseDlg' 'Choose folder' 'Look in:'
    Add-Control 'BrowseDlg' 'DirectoryCombo' 'DirectoryCombo' 25 70 250 80 917515 '_BrowseProperty' $null 'Up'
    Add-Control 'BrowseDlg' 'Up' 'PushButton' 285 69 30 17 3 $null 'Up' 'NewFolder'
    Add-Control 'BrowseDlg' 'NewFolder' 'PushButton' 320 69 40 17 3 $null 'New' 'DirectoryList'
    Add-Control 'BrowseDlg' 'DirectoryList' 'DirectoryList' 25 95 335 95 15 '_BrowseProperty' $null 'PathEdit'
    Add-Control 'BrowseDlg' 'PathLabel' 'Text' 25 196 335 12 3 $null 'Folder name:' $null
    Add-Control 'BrowseDlg' 'PathEdit' 'PathEdit' 25 210 335 18 15 '_BrowseProperty' $null 'OK'
    Add-Button 'BrowseDlg' 'OK' 232 'OK' 'Cancel'
    Add-Button 'BrowseDlg' 'Cancel' 300 'Cancel' 'DirectoryCombo'
    Add-Event 'BrowseDlg' 'Up' 'DirectoryListUp' '0' '1' 1
    Add-Event 'BrowseDlg' 'NewFolder' 'DirectoryListNew' '0' '1' 1
    Add-Event 'BrowseDlg' 'OK' 'SetTargetPath' '[_BrowseProperty]' '1' 1
    Add-Event 'BrowseDlg' 'OK' 'EndDialog' 'Return' '1' 2
    Add-Event 'BrowseDlg' 'Cancel' 'EndDialog' 'Return' '1' 1

    Add-Dialog 'ProgressDlg' 370 270 5 '[ProductName] Setup' 'Cancel' 'Cancel' 'Cancel'
    Add-Frame 'ProgressDlg' 'Setup of [ProductName]' 'Please wait while setup runs.'
    Add-Control 'ProgressDlg' 'ActionText' 'Text' 25 95 320 14 3 $null 'Starting...' $null
    Add-Control 'ProgressDlg' 'ProgressBar' 'ProgressBar' 25 115 320 10 65537 $null 'Progress done' $null
    Add-Button 'ProgressDlg' 'Cancel' 300 'Cancel' 'Cancel'
    Add-MsiRow $mapping @('ProgressDlg', 'ActionText', 'ActionText', 'Text')
    Add-MsiRow $mapping @('ProgressDlg', 'ProgressBar', 'SetProgress', 'Progress')
    Add-Event 'ProgressDlg' 'Cancel' 'SpawnDialog' 'CancelDlg' '1' 1

    Add-Dialog 'CancelDlg' 260 85 3 '[ProductName] Setup' 'No' 'No' 'No'
    Add-Control 'CancelDlg' 'Text' 'Text' 48 15 194 30 3 $null 'Cancel setup?' $null
    Add-Control 'CancelDlg' 'No' 'PushButton' 132 57 56 17 3 $null '&No' 'Yes'
    Add-Control 'CancelDlg' 'Yes' 'PushButton' 72 57 56 17 3 $null '&Yes' 'No'
    Add-Event 'CancelDlg' 'Yes' 'EndDialog' 'Exit' '1' 1
    Add-Event 'CancelDlg' 'No' 'EndDialog' 'Return' '1' 1

    foreach ($end in @(
            @('ExitDialog', 'Setup finished', 'Setup of [ProductName] is complete.', 'Return'),
            @('FatalError', 'Setup failed', '[ProductName] setup ended before it finished. Changes were rolled back.', 'Exit'),
            @('UserExit', 'Setup cancelled', 'Setup of [ProductName] was cancelled. Changes were rolled back.', 'Exit'))) {
        Add-Dialog $end[0] 370 270 3 '[ProductName] Setup' 'Finish' 'Finish' 'Finish'
        Add-Frame $end[0] $end[1] $end[2]
        Add-Button $end[0] 'Finish' 300 '&Finish' 'Finish'
        Add-Event $end[0] 'Finish' 'EndDialog' $end[3] '1' 1
    }

    foreach ($row in @(
            @('InstallFiles', 'Copying files', 'File: [1], Directory: [9], Size: [6]'),
            @('RemoveFiles', 'Removing files', 'File: [1], Directory: [9]'),
            @('CreateShortcuts', 'Creating shortcuts', 'Shortcut: [1]'),
            @('RemoveShortcuts', 'Removing shortcuts', 'Shortcut: [1]'),
            @('RegisterProduct', 'Registering product', '[1]'),
            @('PublishProduct', 'Publishing product information', $null),
            @('InstallValidate', 'Validating install', $null),
            @('CostFinalize', 'Computing space requirements', $null))) {
        Add-MsiRow $actionText $row
    }

    return [pscustomobject]@{
        Tables = @($dialog, $control, $event, $mapping, $radio, $style, $actionText)
        Properties = @(, @('DefaultUIFont', 'DefaultFont'))
        CustomActions = @(
            , @('SetScopeChoicePerMachine', 51, 'INSTALLSCOPE', 'perMachine', $null)
            , @('SetScopeChoicePerUser', 51, 'INSTALLSCOPE', 'perUser', $null))
        Sequence = @(
            , @('SetScopeChoicePerMachine', 720, $PerMachine)
            , @('SetScopeChoicePerUser', 730, "NOT ($PerMachine)")
            , @('FatalError', -3, $null)
            , @('UserExit', -2, $null)
            , @('ExitDialog', -1, $null)
            , @('ScopeDlg', 1230, 'NOT Installed')
            , @('ProgressDlg', 1280, $null))
    }
}
