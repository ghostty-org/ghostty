# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "githubkit",
# ]
# ///

import asyncio
import os
import re
from itertools import chain

from githubkit import GitHub

ORG_NAME = "ghostty-org"
REPO_NAME = "ghostty"
ALLOWED_PARENT_TEAM = "localization"
LOCALIZATION_TEAM_NAME_PATTERN = re.compile(r"[a-z]{2}_[A-Z]{2}")

gh = GitHub(os.environ["GITHUB_TOKEN"])


async def fetch_and_parse_codeowners() -> dict[str, str]:
    content = (
        await gh.rest.repos.async_get_content(
            ORG_NAME,
            REPO_NAME,
            "CODEOWNERS",
            headers={"Accept": "application/vnd.github.raw+json"},
        )
    ).text

    codeowners: dict[str, str] = {}
    for line in content.splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        # This assumes that all entries only list one owner
        # and that this owner is a team (ghostty-org/foobar)
        path, owner = line.split()
        codeowners[path.lstrip("/")] = owner.removeprefix(f"@{ORG_NAME}/")
    return codeowners


async def get_team_members(team_name: str) -> list[str]:
    team = (await gh.rest.teams.async_get_by_name(ORG_NAME, team_name)).parsed_data
    if team.parent and team.parent.slug == ALLOWED_PARENT_TEAM:
        members = (
            await gh.rest.teams.async_list_members_in_org(ORG_NAME, team_name)
        ).parsed_data
        return [m.login for m in members]
    return []


async def get_changed_files(pr_number: int) -> list[str]:
    diff_entries = (
        await gh.rest.pulls.async_list_files(
            ORG_NAME,
            REPO_NAME,
            pr_number,
            per_page=3000,
            headers={"Accept": "application/vnd.github+json"},
        )
    ).parsed_data
    return [d.filename for d in diff_entries]


async def request_review(pr_number: int, *users: str) -> None:
    await asyncio.gather(
        *(
            gh.rest.pulls.async_request_reviewers(
                ORG_NAME,
                REPO_NAME,
                pr_number,
                headers={"Accept": "application/vnd.github+json"},
                data={"reviewers": [user]},
            )
            for user in users
        )
    )


def is_localization_team(team_name: str) -> bool:
    return LOCALIZATION_TEAM_NAME_PATTERN.fullmatch(team_name) is not None


async def main() -> None:
    pr_number = int(os.environ["PR_NUMBER"])
    changed_files = await get_changed_files(pr_number)
    localization_codewners = {
        path: owner
        for path, owner in (await fetch_and_parse_codeowners()).items()
        if is_localization_team(owner)
    }

    found_owners = set[str]()
    for file in changed_files:
        for path, owner in localization_codewners.items():
            if file.startswith(path):
                break
        else:
            continue
        found_owners.add(owner)

    members_lists = await asyncio.gather(
        *(get_team_members(owner) for owner in found_owners)
    )
    await request_review(pr_number, *chain.from_iterable(members_lists))


if __name__ == "__main__":
    asyncio.run(main())
