# This script is loaded automatically when shell-integrations are enabled.
# It will load instead of the `$PROFILE` and, unless `-NoProfile` was passed to the process,
# load the `$PROFILE` itself.
#
# To load shell-integrations in other scripts, include the following in your scripts:
#
#   if ($env:GHOSTTY_RESOURCES_DIR) {
#     source "${env:GHOSTTY_RESOURCES_DIR}/shell-integration/pwsh/ghostty.ps1"
#   }

function Test-Feature([string] $Feature) {
    ($env:GHOSTTY_SHELL_FEATURES -split ',') -contains $Feature
}

function Test-Interactive {
    try {
        if (-not $Host.UI.RawUI) {
            return $false
        }

        if (-not [Environment]::UserInteractive) {
            return $false
        }

        if ([Console]::IsOutputRedirected) {
            return $false
        }

        $true
    }
    catch {
        $false
    }
}
