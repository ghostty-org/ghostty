# Ghostty Shell Integration for PowerShell
#
# This script provides terminal integration features when running inside
# Ghostty. It is automatically sourced when shell-integration is enabled.
#
# Features (controlled by $env:GHOSTTY_SHELL_FEATURES):
#   - Semantic prompt marking (OSC 133)
#   - Current working directory reporting (OSC 7)
#   - Window title updates (OSC 2)
#   - Cursor shape changes at prompt

if (-not $env:GHOSTTY_SHELL_FEATURES) { return }

$GhosttyFeatures = $env:GHOSTTY_SHELL_FEATURES -split ','

# Save the original prompt function so we can call it.
if (Test-Path Function:\prompt) {
    $Function:__ghostty_original_prompt = $Function:prompt
} else {
    function __ghostty_original_prompt { "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) " }
}

# Track prompt state for OSC 133 sequencing.
$Script:__ghostty_prompt_state = 'initial'

function prompt {
    # Capture exit code before anything else can clobber it.
    $realLASTEXITCODE = $global:LASTEXITCODE
    $cmdSuccess = $?

    # OSC 133;D — end of previous command output (with exit status).
    # Skip on the very first prompt (no command has run yet).
    if ($Script:__ghostty_prompt_state -ne 'initial') {
        $exitCode = if ($cmdSuccess) { 0 } else { if ($realLASTEXITCODE) { $realLASTEXITCODE } else { 1 } }
        [Console]::Write("`e]133;D;$exitCode`a")
    }

    # OSC 133;A — fresh line / new prompt.
    [Console]::Write("`e]133;A`a")

    # Cursor shape: blinking bar at prompt (if cursor feature enabled).
    if ($GhosttyFeatures -contains 'cursor') {
        [Console]::Write("`e[5 q")
    }

    # OSC 7 — report current working directory.
    $cwd = (Get-Location).Path -replace '\\', '/'
    # File URI: file://hostname/path
    $hostname = [System.Net.Dns]::GetHostName()
    [Console]::Write("`e]7;file://$hostname/$cwd`a")

    # OSC 2 — window title (current directory).
    if ($GhosttyFeatures -contains 'title') {
        $leaf = Split-Path -Leaf (Get-Location)
        [Console]::Write("`e]2;$leaf`a")
    }

    # Call the original prompt to get the prompt string.
    $promptText = __ghostty_original_prompt

    # OSC 133;B — end of prompt, start of user input.
    [Console]::Write("`e]133;B`a")

    $Script:__ghostty_prompt_state = 'prompt-end'

    # Restore LASTEXITCODE so the user sees the real value.
    $global:LASTEXITCODE = $realLASTEXITCODE

    return $promptText
}

# PSReadLine key handler to emit OSC 133;C when Enter is pressed
# (marks end of input, start of command output).
if (Get-Module -Name PSReadLine -ErrorAction SilentlyContinue) {
    Set-PSReadLineKeyHandler -Key Enter -ScriptBlock {
        # OSC 133;C — end of input, start of output.
        [Console]::Write("`e]133;C`a")

        # Reset cursor to default shape before command runs.
        if ($GhosttyFeatures -contains 'cursor') {
            [Console]::Write("`e[0 q")
        }

        $Script:__ghostty_prompt_state = 'pre-exec'

        [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine()
    }
}

# Clean up the integration env vars (don't leak to child processes).
Remove-Item Env:GHOSTTY_SHELL_INTEGRATION_XDG_DIR -ErrorAction SilentlyContinue
