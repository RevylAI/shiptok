#!/usr/bin/env python3
"""The signed-in session profile: starts a Revyl session's ShipTok signed in as revyl-shiptok-tests on RevylAI/kyle-expo.

Revyl runs this before the app launches (.revyl/config.yaml, session.profiles). It hands the app a GitHub user
access token from ShipTok's own GitHub sign-in as a secret launch argument, and names the feed to open
(ShipTok/Auth/LaunchArgumentSignIn.swift).

The grant lives in two Revyl global variables, which scripts/revyl/save-test-account-github-sign-in.py writes:
the access token with its expiry, marked readable by automated runs, and the refresh token, which only a
member's own login or personal API key can read. GitHub retires both the refresh token and the old access token
the moment the refresh token is used, so the app never receives the refresh token, and the grant is renewed only
once its access token has under five minutes left: a renewal never cuts short a session that took the old token.
A start takes the saved token only while it has at least 30 minutes left, so every session gets at least that
long, and a start in between fails and says when to try again (AGENTS.md, "Revyl").

Nothing this prints holds a token.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

# The backend every ShipTok build signs in through (SHIPTOK_REVYL_BACKEND_URL in ShipTok.xcodeproj/project.pbxproj); only its GitHub App refreshes the tokens it issued.
SHIPTOK_REVYL_BACKEND_URL = "https://backend.revyl.ai"
ACCESS_TOKEN_GLOBAL_VARIABLE_NAME = "shiptok-revyl-shiptok-tests-github-user-access-token"
REFRESH_TOKEN_GLOBAL_VARIABLE_NAME = "shiptok-revyl-shiptok-tests-github-refresh-token"
FEED_REPOSITORY_FULL_NAME = "RevylAI/kyle-expo"
MINIMUM_SESSION_SECONDS = 30 * 60
RENEW_BELOW_REMAINING_SECONDS = 5 * 60
CONCURRENT_RENEWAL_WAIT_SECONDS = 60
REVYL_COMMAND_TIMEOUT_SECONDS = 45
REFRESH_REQUEST_TIMEOUT_SECONDS = 30
SAVE_GRANT_COMMAND = "scripts/revyl/save-test-account-github-sign-in.py"
# Revyl's edge refuses Python's default User-Agent.
HTTP_USER_AGENT = "ShipTok-signed-in-session-profile"


class SessionProfileFailure(Exception):
    pass


class SavedAccessToken:
    def __init__(self, access_token: str, expires_at_unix_seconds: float | None) -> None:
        self.access_token = access_token
        self.expires_at_unix_seconds = expires_at_unix_seconds

    @property
    def remaining_seconds(self) -> float:
        return float("inf") if self.expires_at_unix_seconds is None else self.expires_at_unix_seconds - time.time()


# A command's output stays in this process and a timeout is reported without the command, since both can hold a token.
def run_revyl(arguments: list[str]) -> str | None:
    try:
        result = subprocess.run(["revyl", *arguments], capture_output=True, text=True, timeout=REVYL_COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return None
    return result.stdout if result.returncode == 0 else None


def reveal_global_variable(variable_name: str) -> str | None:
    revealed_output = run_revyl(["global", "var", "get", variable_name, "--reveal", "--json"])
    if revealed_output is None:
        return None
    return json.loads(revealed_output).get("variable_value") or None


def save_secret_global_variable(variable_name: str, value: str) -> None:
    for attempt in range(3):
        if run_revyl(["global", "var", "set", f"{variable_name}={value}", "--secret"]) is not None:
            return
        time.sleep(5 * (attempt + 1))
    raise SessionProfileFailure(f"couldn't save {variable_name}")


def read_saved_access_token() -> SavedAccessToken | None:
    revealed_value = reveal_global_variable(ACCESS_TOKEN_GLOBAL_VARIABLE_NAME)
    if revealed_value is None:
        return None
    saved = json.loads(revealed_value)
    return SavedAccessToken(saved["access_token"], saved.get("access_token_expires_at_unix_seconds"))


def refresh_tokens(refresh_token: str) -> dict[str, object] | None:
    request = urllib.request.Request(
        f"{SHIPTOK_REVYL_BACKEND_URL}/api/v1/shiptok/github-sign-in/user-access-token-refreshes",
        data=json.dumps({"refresh_token": refresh_token}).encode(),
        headers={"Content-Type": "application/json", "User-Agent": HTTP_USER_AGENT},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=REFRESH_REQUEST_TIMEOUT_SECONDS) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 401:
            return None
        raise SessionProfileFailure(f"Revyl answered {error.code} to the refresh") from None
    except (urllib.error.URLError, TimeoutError) as error:
        raise SessionProfileFailure(f"the refresh request failed ({type(error).__name__})") from None


def renew_access_token(refresh_token: str, retired: SavedAccessToken | None) -> str:
    renewed_at_unix_seconds = time.time()
    tokens = refresh_tokens(refresh_token)
    if tokens is None:
        # GitHub took this refresh token once already when another start renewed the grant first, so that start is saving the pair it got.
        deadline_unix_seconds = time.time() + CONCURRENT_RENEWAL_WAIT_SECONDS
        while time.time() < deadline_unix_seconds:
            time.sleep(5)
            saved = read_saved_access_token()
            if saved is not None and (retired is None or saved.access_token != retired.access_token) and saved.remaining_seconds >= MINIMUM_SESSION_SECONDS:
                return saved.access_token
        raise SessionProfileFailure(f"GitHub refused the saved grant; a member saves a new one with {SAVE_GRANT_COMMAND}")
    access_token = str(tokens["access_token"])
    expires_in_seconds = tokens.get("access_token_expires_in_seconds")
    # The refresh token goes first: once GitHub issued it, it is the only one that still works.
    if tokens.get("refresh_token"):
        save_secret_global_variable(REFRESH_TOKEN_GLOBAL_VARIABLE_NAME, str(tokens["refresh_token"]))
    save_secret_global_variable(
        ACCESS_TOKEN_GLOBAL_VARIABLE_NAME,
        json.dumps({
            "access_token": access_token,
            "access_token_expires_at_unix_seconds": None if expires_in_seconds is None else int(renewed_at_unix_seconds + float(expires_in_seconds)),
        }),
    )
    return access_token


def signed_in_access_token() -> str:
    saved = read_saved_access_token()
    if saved is None:
        raise SessionProfileFailure(f"no grant is saved, or this start's credential can't read it; a member saves one with {SAVE_GRANT_COMMAND}")
    if saved.remaining_seconds >= MINIMUM_SESSION_SECONDS:
        return saved.access_token
    if saved.remaining_seconds >= RENEW_BELOW_REMAINING_SECONDS:
        minutes_until_renewal = int((saved.remaining_seconds - RENEW_BELOW_REMAINING_SECONDS) // 60) + 1
        raise SessionProfileFailure(f"the saved token has under 30 minutes left and renews in {minutes_until_renewal} minutes; start again then, or start with --session-profile none")
    refresh_token = reveal_global_variable(REFRESH_TOKEN_GLOBAL_VARIABLE_NAME)
    if refresh_token is None:
        raise SessionProfileFailure("the saved token has expired, and only a member's own Revyl login or personal API key can renew it; start one session with one")
    return renew_access_token(refresh_token, saved)


def append_launch_value(output_file_environment_variable_name: str, key: str, value: str) -> None:
    if not value or "\n" in value or "\r" in value:
        raise SessionProfileFailure(f"{key} doesn't fit on one line")
    with open(os.environ[output_file_environment_variable_name], "a", encoding="utf-8") as output_file:
        output_file.write(f"{key}={value}\n")


def main() -> int:
    try:
        if os.environ.get("REVYL_PLATFORM") != "ios":
            raise SessionProfileFailure("ShipTok is an iOS app, so this profile signs in only iOS sessions")
        append_launch_value("REVYL_SECRET_LAUNCH_ENV_FILE", "SHIPTOK_LAUNCH_SIGN_IN_GITHUB_USER_ACCESS_TOKEN", signed_in_access_token().strip())
        append_launch_value("REVYL_LAUNCH_ENV_FILE", "SHIPTOK_LAUNCH_SIGN_IN_FEED_REPOSITORY_FULL_NAME", FEED_REPOSITORY_FULL_NAME)
    except SessionProfileFailure as failure:
        print(f"signed-in session profile: {failure}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"signed-in session profile: failed with {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
