#!/usr/bin/env python3
"""The signed-in session profile: starts a Revyl session's ShipTok signed in to Revyl, on RevylAI/kyle-expo's feed.

Revyl runs this before the app launches (.revyl/config.yaml, session.profiles). It reads the organization's two ShipTok
launch variables, the test account's ShipTok key (secret, readable by automated runs) and the feed's repository, and
hands them to the app as launch values (ShipTok/Auth/LaunchArgumentSignIn.swift). The tests attach the same launch
variables, and a raw session takes them with --launch-var. scripts/revyl/save-session-sign-in.py saves the key.

Nothing this prints holds the key.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

REVYL_API_KEY_LAUNCH_VARIABLE_KEY = "SHIPTOK_LAUNCH_SIGN_IN_REVYL_API_KEY"
FEED_REPOSITORY_LAUNCH_VARIABLE_KEY = "SHIPTOK_LAUNCH_SIGN_IN_FEED_REPOSITORY_FULL_NAME"
REVYL_COMMAND_TIMEOUT_SECONDS = 45
SAVE_KEY_COMMAND = "scripts/revyl/save-session-sign-in.py"


class SessionProfileFailure(Exception):
    pass


def launch_variable_value(launch_variable_key: str) -> str:
    try:
        result = subprocess.run(
            ["revyl", "global", "launch-var", "get", launch_variable_key, "--reveal", "--json"],
            capture_output=True,
            text=True,
            timeout=REVYL_COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        raise SessionProfileFailure(f"reading {launch_variable_key} timed out") from None
    value = json.loads(result.stdout).get("value") if result.returncode == 0 else None
    if not value:
        raise SessionProfileFailure(f"{launch_variable_key} isn't set, or this start's credential can't read it; a member saves the key with {SAVE_KEY_COMMAND}")
    return value.strip()


def append_launch_value(output_file_environment_variable_name: str, key: str, value: str) -> None:
    if "\n" in value or "\r" in value:
        raise SessionProfileFailure(f"{key} doesn't fit on one line")
    with open(os.environ[output_file_environment_variable_name], "a", encoding="utf-8") as output_file:
        output_file.write(f"{key}={value}\n")


def main() -> int:
    try:
        if os.environ.get("REVYL_PLATFORM") != "ios":
            raise SessionProfileFailure("ShipTok is an iOS app, so this profile signs in only iOS sessions")
        append_launch_value("REVYL_SECRET_LAUNCH_ENV_FILE", REVYL_API_KEY_LAUNCH_VARIABLE_KEY, launch_variable_value(REVYL_API_KEY_LAUNCH_VARIABLE_KEY))
        append_launch_value("REVYL_LAUNCH_ENV_FILE", FEED_REPOSITORY_LAUNCH_VARIABLE_KEY, launch_variable_value(FEED_REPOSITORY_LAUNCH_VARIABLE_KEY))
    except SessionProfileFailure as failure:
        print(f"signed-in session profile: {failure}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"signed-in session profile: failed with {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
