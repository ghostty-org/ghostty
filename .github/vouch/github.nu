# GitHub API utilities for Nu scripts

# Make a GitHub API request with proper headers
export def api [
  method: string,  # HTTP method (get, post, patch, etc.)
  endpoint: string # API endpoint (e.g., /repos/owner/repo/issues/1/comments)
  body?: record    # Optional request body
] {
  let url = $"https://api.github.com($endpoint)"
  let headers = [
    Authorization $"Bearer (get-token)"
    Accept "application/vnd.github+json"
    X-GitHub-Api-Version "2022-11-28"
  ]

  match $method {
    "get" => { http get $url --headers $headers },
    "post" => { http post $url --headers $headers $body },
    "patch" => { http patch $url --headers $headers $body },
    _ => { error make { msg: $"Unsupported HTTP method: ($method)" } }
  }
}

# Get GitHub token from environment or gh CLI (cached in env)
def get-token [] {
  if ($env.GITHUB_TOKEN? | is-not-empty) {
    return $env.GITHUB_TOKEN
  }

  $env.GITHUB_TOKEN = (gh auth token | str trim)
  $env.GITHUB_TOKEN
}
