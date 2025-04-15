# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "githubkit",
#     "loguru",
# ]
# ///

from __future__ import annotations

import asyncio
import os
import re
import sys
from collections.abc import Iterator
from contextlib import contextmanager
from itertools import chain

from githubkit import GitHub
from githubkit.exception import RequestFailed
from loguru import logger

ORG_NAME = "ghostty-org"
REPO_NAME = "ghostty"
ALLOWED_PARENT_TEAM = "localization"
LOCALIZATION_TEAM_NAME_PATTERN = re.compile(r"[a-z]{2}_[A-Z]{2}")
LEVEL_MAP = {"DEBUG": "DBG", "WARNING": "WRN", "ERROR": "ERR"}

logger.remove()
logger.add(
    sys.stderr,
    format=lambda record: (
        "<green>{time:YYYY-MM-DD HH:mm:ss.SSS}</green> | "
        f"<level>{LEVEL_MAP[record['level'].name]}</level> | "
        "<cyan>{function}</cyan>:<cyan>{line}</cyan> - "
        "<level>{message}</level>\n"
    ),
    backtrace=True,
    diagnose=True,
)


@contextmanager
def log_fail(message: str, *, die: bool = True) -> Iterator[None]:
    try:
        yield
    except RequestFailed as exc:
        logger.error(message)
        logger.error(exc)
        logger.error(exc.response.raw_response.json())
        if die:
            sys.exit(1)


gh = GitHub(os.environ["GITHUB_TOKEN"])

with log_fail("Invalid token"):
    # Do the simplest request as a test
    gh.rest.rate_limit.get()


async def fetch_and_parse_codeowners() -> dict[str, str]:
    logger.debug("Fetching CODEOWNERS file...")
    with log_fail("Failed to fetch CODEOWNERS file"):
        content = (
            await gh.rest.repos.async_get_content(
                ORG_NAME,
                REPO_NAME,
                "CODEOWNERS",
                headers={"Accept": "application/vnd.github.raw+json"},
            )
        ).text

    logger.debug("Parsing CODEOWNERS file...")
    codeowners: dict[str, str] = {}
    for line in content.splitlines():
        if not line or line.lstrip().startswith("#"):
            continue

        # This assumes that all entries only list one owner
        # and that this owner is a team (ghostty-org/foobar)
        path, owner = line.split()
        path = path.lstrip("/")
        owner = owner.removeprefix(f"@{ORG_NAME}/")

        if not is_localization_team(owner):
            logger.debug(f"Skipping non-l11n codeowner {owner!r} for {path}")
            continue

        codeowners[path] = owner
        logger.debug(f"Found codeowner {owner!r} for {path}")
    return codeowners


async def get_team_members(team_name: str) -> list[str]:
    logger.debug(f"Fetching team {team_name!r}...")
    with log_fail(f"Failed to fetch team {team_name!r}"):
        team = (await gh.rest.teams.async_get_by_name(ORG_NAME, team_name)).parsed_data

    if team.parent and team.parent.slug == ALLOWED_PARENT_TEAM:
        logger.debug(f"Fetching team {team_name!r} members...")
        with log_fail(f"Failed to fetch team {team_name!r} members"):
            resp = await gh.rest.teams.async_list_members_in_org(ORG_NAME, team_name)
            members = [m.login for m in resp.parsed_data]
        logger.debug(f"Team {team_name!r} members: {', '.join(members)}")
        return members

    logger.warning(f"Team {team_name} does not have a {ALLOWED_PARENT_TEAM!r} parent")
    return []


async def get_changed_files(pr_number: int) -> list[str]:
    logger.debug("Gathering changed files...")
    with log_fail("Failed to gather changed files"):
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


async def request_review(pr_number: int, user: str, pr_author: str) -> None:
    if user == pr_author:
        logger.debug(f"Skipping review request for {user!r} (is PR author)")
    logger.debug(f"Requesting review from {user!r}...")
    with log_fail(f"Failed to request review from {user}", die=False):
        await gh.rest.pulls.async_request_reviewers(
            ORG_NAME,
            REPO_NAME,
            pr_number,
            headers={"Accept": "application/vnd.github+json"},
            data={"reviewers": [user]},
        )


def is_localization_team(team_name: str) -> bool:
    return LOCALIZATION_TEAM_NAME_PATTERN.fullmatch(team_name) is not None


async def get_pr_author(pr_number: int) -> str:
    logger.debug("Fetching PR author...")
    with log_fail("Failed to fetch PR author"):
        resp = await gh.rest.pulls.async_get(ORG_NAME, REPO_NAME, pr_number)
        pr_author = resp.parsed_data.user.login
    logger.debug(f"Found author: {pr_author!r}")
    return pr_author


async def main() -> None:
    logger.debug("Reading PR number...")
    pr_number = int(os.environ["PR_NUMBER"])
    logger.debug(f"Starting review request process for PR #{pr_number}...")

    changed_files = await get_changed_files(pr_number)
    logger.debug(f"Changed files: {', '.join(map(repr, changed_files))}")

    pr_author = await get_pr_author(pr_number)
    codeowners = await fetch_and_parse_codeowners()

    found_owners = set[str]()
    for file in changed_files:
        logger.debug(f"Finding owner for {file!r}...")
        for path, owner in codeowners.items():
            if file.startswith(path):
                logger.debug(f"Found owner: {owner!r}")
                break
        else:
            logger.debug("No owner found")
            continue
        found_owners.add(owner)

    member_lists = await asyncio.gather(
        *(get_team_members(owner) for owner in found_owners)
    )
    await asyncio.gather(
        *(
            request_review(pr_number, user, pr_author)
            for user in chain.from_iterable(member_lists)
        )
    )


if __name__ == "__main__":
    asyncio.run(main())
