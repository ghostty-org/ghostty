let enable_integration = $env.GHOSTTY_SHELL_FEATURES | split row ',' 
  | where ($it in ["ssh-env" "ssh-terminfo"]) 
  | is-not-empty

let ghostty_ssh_file = $env.GHOSTTY_RESOURCES_DIR
  | path join "shell-integration" "nushell" "ghostty-ssh-integration.nu"

let ssh_integration_file = $nu.data-dir | path join "ghostty-ssh-integration.nu"
let ssh_file_exists = $ssh_integration_file | path exists

# TOD0: In case of an update to the `ghostty-ssh-integration.nu` file
# the file wont be updated here, so we need to support
# saving the new file once there is an update

match [$enable_integration $ssh_file_exists] {
  [true false] => {
    # $nu.data-dir is not created by default
    # https://www.nushell.sh/book/configuration.html#startup-variables
    $nu.data-dir | path exists | if (not $in) { mkdir $nu.data-dir }
    open $ghostty_ssh_file | save $ssh_integration_file
  }
  [false true] => {
    # We need to check if the user disabled `ssh-integration` and thus
    # the integration file needs to be removed so it doesnt get sourced by
    # the `source-integration.nu` file
    rm $ssh_integration_file
  }
  _ => { }
}
