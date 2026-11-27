# Ghostty shell integration for PowerShell (Windows PowerShell and PowerShell 7).
#
# It marks where each prompt starts and ends, which lets Ghostty jump between
# prompts and tell commands from their output, and it reports the current
# folder so new tabs and splits can start there.
#
# Ghostty loads this by itself when it starts PowerShell. To load it by hand,
# add this line to your profile:
#
#   if ($env:TERM_PROGRAM -eq 'ghostty') { . 'path\to\ghostty-integration.ps1' }

# Load it once per session, and only inside Ghostty.
if ($env:TERM_PROGRAM -ne 'ghostty') { return }
if ($global:__GhosttyIntegrationLoaded) { return }
$global:__GhosttyIntegrationLoaded = $true

# The shell speaks to the terminal through escape sequences. OSC 133 marks
# prompts and OSC 7 reports the folder.
$global:__GhosttyEsc = [char]27
$global:__GhosttyOriginalPrompt = $function:prompt
$global:__GhosttyPromptShown = $false

# Ghostty wants the folder as a file URL with the computer's name in it.
function global:__GhosttyFolderUrl {
    $location = $executionContext.SessionState.Path.CurrentLocation
    if ($location.Provider.Name -ne 'FileSystem') { return $null }

    $path = $location.ProviderPath
    # Only local drives. Network folders have no URL form that fits here.
    if ($path -notmatch '^[A-Za-z]:') { return $null }

    $parts = ($path -replace '\\', '/') -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }
    return 'file://' + $env:COMPUTERNAME + '/' + ($parts -join '/')
}

function global:prompt {
    # The result of the command that just ran has to be read before anything
    # else in here changes it.
    $succeeded = $?
    $exitCode = if ($succeeded) { 0 } elseif ($null -ne $global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) { $global:LASTEXITCODE } else { 1 }
    $esc = $global:__GhosttyEsc

    $marks = ''
    # D closes the previous command and carries its exit status.
    if ($global:__GhosttyPromptShown) { $marks += "$esc]133;D;$exitCode$esc\" }
    $global:__GhosttyPromptShown = $true

    $url = __GhosttyFolderUrl
    if ($url) { $marks += "$esc]7;$url$esc\" }

    # A starts the prompt.
    $marks += "$esc]133;A$esc\"

    $text = & $global:__GhosttyOriginalPrompt
    # B ends it, which is where what the user types begins.
    return $marks + $text + "$esc]133;B$esc\"
}

# C marks the start of a command's output. It has to be sent when the line is
# accepted, which only the line editor knows about.
if (Get-Module -ListAvailable PSReadLine) {
    try {
        Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
            [Console]::Out.Write("$($global:__GhosttyEsc)]133;C$($global:__GhosttyEsc)\")
            [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
        }
    } catch {
        # Without the marks for the start of output everything else still works.
    }
}
