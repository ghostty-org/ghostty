# The list of vouched (or actively denounced) users for this repository.
#
# The high-level idea is that only vouched users can participate in
# contributing to this project. And a denounced user is explicitly
# blocked from contributing (issues, PRs, etc. auto-closed). 
#
# We choose to maintain a denouncement list rather than or in addition to 
# using the platform's block features so other projects can slurp in our 
# list of denounced users if they trust us and want to adopt our prior
# knowledge about bad actors.
#
# Syntax:
#  - One handle per line (without @). Sorted alphabetically.
#  - Optionally specify platform: `platform:username` (e.g., `github:mitchellh`).
#  - To denounce a user, prefix with minus: `-username` or `-platform:username`.
#  - Optionally, add details after a space following the handle.
#
# Maintainers can vouch for new contributors by commenting "lgtm" on an
# issue by the author. Maintainers can denounce users by commenting
# "denounce" or "denounce [username]" on an issue or PR.
mitchellh
-github:badguy
-github:slopmaster3000 Submitted endless amounts of AI slop
