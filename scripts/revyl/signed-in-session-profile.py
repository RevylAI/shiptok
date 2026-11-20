#!/usr/bin/env python3
"""The signed-in session profile: starts a Revyl session's ShipTok signed in as Kyle Rich's GitHub account, kylexrich.

Revyl runs this before the app launches (.revyl/config.yaml, session.profiles). It hands the app a GitHub
user access token that ShipTok's own GitHub sign-in issued for kylexrich, as a secret launch argument, and
names RevylAI/cognisim-monorepo as the feed to open (ShipTok/Auth/LaunchArgumentSignIn.swift).

GitHub retires a user access token and its refresh token as soon as the refresh token is used, so one grant
serves every session only while a single chain of refreshes rotates it. Two Revyl global variables hold it:
the current access token with its expiry, which any run in the organization may read, and the refresh token,
which only a member's own login or personal API key can read. A start that can read the refresh token renews
the access token once it has less than two hours left and saves the new pair; any other start takes the saved
access token while it has at least ten minutes left. The app never receives the refresh token, so it never
rotates the grant (AGENTS.md, "Revyl").

Exit codes: 0 signed in, 2 the saved access token is too old and this start can't renew it, 1 anything else.
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

# The backend every ShipTok build signs in through (SHIPTOK_REVYL_BACKEND_URL in ShipTok.xcodeproj/project.pbxproj); only its GitHub App can refresh the tokens it issued.
SHIPTOK_REVYL_BACKEND_URL = "https://backend.revyl.ai"
ACCESS_TOKEN_GLOBAL_VARIABLE_NAME = "shiptok-kylexrich-github-user-access-token"
REFRESH_TOKEN_GLOBAL_VARIABLE_NAME = "shiptok-kylexrich-github-refresh-token"
FEED_REPOSITORY_FULL_NAME = "RevylAI/cognisim-monorepo"
RENEW_BELOW_REMAINING_SECONDS = 2 * 60 * 60
USABLE_FROM_REMAINING_SECONDS = 10 * 60
CONCURRENT_RENEWAL_WAIT_SECONDS = 60
REVYL_COMMAND_TIMEOUT_SECONDS = 45
REFRESH_REQUEST_TIMEOUT_SECONDS = 30


class SessionProfileFailure(Exception):
    def __init__(self, reason: str, exit_code: int = 1) -> None:
        super().__init__(reason)
        self.exit_code = exit_code


class StoredAccessToken:
    def __init__(self, access_token: str, expires_at_unix_seconds: float | None) -> None:
        self.access_token = access_token
        self.expires_at_unix_seconds = expires_at_unix_seconds

    def lasts_at_least(self, seconds: float) -> bool:
        return self.expires_at_unix_seconds is None or self.expires_at_unix_seconds - time.time() >= seconds


# The output stays here and a timeout is reported without the command, since both can hold a token.
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


def read_stored_access_token() -> StoredAccessToken | None:
    revealed_value = reveal_global_variable(ACCESS_TOKEN_GLOBAL_VARIABLE_NAME)
    if revealed_value is None:
        return None
    stored = json.loads(revealed_value)
    return StoredAccessToken(stored["access_token"], stored.get("access_token_expires_at_unix_seconds"))


def refresh_tokens(refresh_token: str) -> dict[str, object] | None:
    request = urllib.request.Request(
        f"{SHIPTOK_REVYL_BACKEND_URL}/api/v1/shiptok/github-sign-in/user-access-token-refreshes",
        data=json.dumps({"refresh_token": refresh_token}).encode(),
        headers={"Content-Type": "application/json"},
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


def renew_access_token(refresh_token: str, stale: StoredAccessToken | None) -> str:
    renewed_at_unix_seconds = time.time()
    tokens = refresh_tokens(refresh_token)
    if tokens is None:
        # GitHub took this refresh token once already: another start renewed the grant first and is saving the pair it got.
        deadline_unix_seconds = time.time() + CONCURRENT_RENEWAL_WAIT_SECONDS
        while time.time() < deadline_unix_seconds:
            time.sleep(5)
            stored = read_stored_access_token()
            if stored is not None and (stale is None or stored.access_token != stale.access_token) and stored.lasts_at_least(USABLE_FROM_REMAINING_SECONDS):
                return stored.access_token
        raise SessionProfileFailure("GitHub refused the saved refresh token and no other start saved a new one; sign in again as AGENTS.md says")
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
    stored = read_stored_access_token()
    if stored is not None and stored.lasts_at_least(RENEW_BELOW_REMAINING_SECONDS):
        return stored.access_token
    refresh_token = reveal_global_variable(REFRESH_TOKEN_GLOBAL_VARIABLE_NAME)
    if refresh_token is not None:
        return renew_access_token(refresh_token, stored)
    if stored is not None and stored.lasts_at_least(USABLE_FROM_REMAINING_SECONDS):
        return stored.access_token
    raise SessionProfileFailure(
        "the saved access token is too old and this start's credential can't renew it; start a session with a member's own Revyl login to renew it",
        exit_code=2,
    )


def append_launch_value(output_file_environment_variable_name: str, key: str, value: str) -> None:
    if "\n" in value or "\r" in value or not value:
        raise SessionProfileFailure(f"{key} would not fit on one line")
    with open(os.environ[output_file_environment_variable_name], "a", encoding="utf-8") as output_file:
        output_file.write(f"{key}={value}\n")


def main() -> int:
    try:
        if os.environ.get("REVYL_PLATFORM") != "ios":
            raise SessionProfileFailure("ShipTok is an iOS app, so this profile signs in only iOS sessions")
        access_token = signed_in_access_token()
        append_launch_value("REVYL_SECRET_LAUNCH_ENV_FILE", "SHIPTOK_LAUNCH_SIGN_IN_GITHUB_USER_ACCESS_TOKEN", access_token.strip())
        append_launch_value("REVYL_LAUNCH_ENV_FILE", "SHIPTOK_LAUNCH_SIGN_IN_FEED_REPOSITORY_FULL_NAME", FEED_REPOSITORY_FULL_NAME)
    except SessionProfileFailure as failure:
        print(f"signed-in session profile: {failure}", file=sys.stderr)
        return failure.exit_code
    except Exception as error:
        print(f"signed-in session profile: failed with {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
