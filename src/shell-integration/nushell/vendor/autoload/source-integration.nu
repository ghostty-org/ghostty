# Sourcing the `ghostty-integration.nu` cant be on the
# `bootstrap-integration.nu` file because it tries to resolve the `sourced`
# file at parsing time, which would make it source nothing.

# But here we rely on the fact that `boostrap-integration.nu` gets parsed
# and executed first, and then we can count on `ssh_integration_file` being available

#https://www.nushell.sh/book/thinking_in_nu.html#example-dynamically-generating-source

const ssh_integration_file = $nu.data-dir | path join "ghostty-ssh-integration.nu"
source (if ($ssh_integration_file | path exists) { $ssh_integration_file } else { null })
