# Vouch System

This implements a system where users must be vouched prior to interacting
with certain parts of the project. The implementation in this folder is generic
and can be used by any project.

Going further, the vouch system also has an explicit **denouncement** feature,
where particularly bad actors can be explicitly denounced. This blocks
these users from interacting with the project completely but also makes
it a public record for other projects to see and use if they so wish.

The vouch list is maintained in a single flat file with a purposefully
minimal format that can be trivially parsed using standard POSIX tools and
any programming language without any external libraries.

This is based on ideas I first saw in the [Pi project](https://github.com/badlogic/pi-mono).

> [!WARNING]
>
> This is a work-in-progress and experimental system. We're going to
> continue to test this in Ghostty, refine it, and improve it over time.

## Why?

Open source has always worked on a system of _trust and verify_.

Historically, the effort required to understand a codebase, implement
a change, and submit that change for review was high enough that it
naturally filtered out many low quality contributions from unqualified people.
For over 20 years of my life, this was enough for my projects as well
as enough for most others.

Unfortunately, the landscape has changed particularly with the advent
of AI tools that allow people to trivially create plausible-looking but
extremely low-quality contributions with little to no true understanding.
Contributors can no longer be trusted based on the minimal barrier to entry
to simply submit a change.

But, open source still works on trust! And every project has a definite
group of trusted individuals (maintainers) and a larger group of probably
trusted individuals (active members of the community in any form). So,
let's move to an explicit trust model where trusted individuals can vouch
for others, and those vouched individuals can then contribute.

## Usage

The only requirement is [Nu](https://www.nushell.sh/).

### VOUCHED File

See [VOUCHED.example.td](VOUCHED.example.td) for the file format. The file is
looked up at `VOUCHED.td` or `.github/VOUCHED.td` by default. Create an
empty `VOUCHED.td` file.

Overview:

```
# Comments start with #
platform:username
-platform:denounced-user
-platform:denounced-user reason for denouncement
```

The platform prefix (e.g., `github:`) specifies where the user identity
comes from. The platform prefix is optional, since most projects exist
within the realm of a single platform. All the commands below take
`--default-platform` flags to specify what platform to assume when none
is present.

### Commands

#### Integrated Help

This is Nu, so you can get help on any command:

```bash
use vouch.nu *; help main
use vouch.nu *; help main add
use vouch.nu *; help main check
use vouch.nu *; help main denounce
use vouch.nu *; help main gh-check-pr
use vouch.nu *; help main gh-manage-by-issue
```

#### Local Commands

**Check a user's vouch status:**

```bash
./vouch.nu check <username>
```

Exit codes: 0 = vouched, 1 = denounced, 2 = unknown.

**Add a user to the vouched list:**

```bash
# Dry run (default) - see what would happen
./vouch.nu add someuser

# Actually add the user
./vouch.nu add someuser --dry-run=false
```

**Denounce a user:**

```bash
# Dry run (default)
./vouch.nu denounce badactor

# With a reason
./vouch.nu denounce badactor --reason "Submitted AI slop"

# Actually denounce
./vouch.nu denounce badactor --dry-run=false
```

#### GitHub Integration

This requires the `GITHUB_TOKEN` environment variable to be set. If
that isn't set and `gh` is available, we'll use the token from `gh`.

**Check if a PR author is vouched:**

```bash
# Check PR author status
./vouch.nu gh-check-pr 123

# Auto-close unvouched PRs (dry run)
./vouch.nu gh-check-pr 123 --auto-close

# Actually close unvouched PRs
./vouch.nu gh-check-pr 123 --auto-close --dry-run=false

# Allow unvouched users, only block denounced
./vouch.nu gh-check-pr 123 --require-vouch=false --auto-close
```

Outputs status: "skipped" (bot), "vouched", "allowed", or "closed".

**Manage contributor status via issue comments:**

```bash
# Dry run (default)
./vouch.nu gh-manage-by-issue 123 456789

# Actually perform the action
./vouch.nu gh-manage-by-issue 123 456789 --dry-run=false
```

Responds to comments:

- `lgtm` - vouches for the issue author
- `denounce` - denounces the issue author
- `denounce username` - denounces a specific user
- `denounce username reason` - denounces with a reason

Only collaborators with write access can vouch or denounce.
