#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.65.2"]
# ///
"""Saves the ShipTok key Revyl sessions and tests sign in with, in the organization's launch variable
SHIPTOK_LAUNCH_SIGN_IN_REVYL_API_KEY (secret, readable by automated runs).

It signs ShipTok in to Revyl the way the app does: Revyl's web sign-in page in Google Chrome, then the code redeemed
with its PKCE verifier for a ShipTok key. Chrome opens in a window: sign it in to Revyl as the test account when the
page asks, and press Continue to ShipTok. With --sign-in-link-file, it first opens the one-time Revyl sign-in link that
file holds and runs headless. --backend-url names the backend the key is for, the one the session's build points at
(SHIPTOK_REVYL_BACKEND_URL). Run it from the repository root with a member's own Revyl login or personal API key,
which the variable's mark needs. Signing ShipTok out with this key, in the app or a session, deletes it, so save a new
one after that.

Nothing this prints holds a link, code or key.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from playwright.sync_api import Request, sync_playwright

DEFAULT_SHIPTOK_REVYL_BACKEND_URL = "https://backend.revyl.ai"
SIGN_IN_CALLBACK_URL_PREFIX = "shiptok://revyl-sign-in-callback"
REVYL_API_KEY_LAUNCH_VARIABLE_KEY = "SHIPTOK_LAUNCH_SIGN_IN_REVYL_API_KEY"
DEVICE_LABEL = "Revyl sessions and tests"
PAGE_TIMEOUT_MILLISECONDS = 60_000
CALLBACK_WAIT_SECONDS = 600
REVYL_COMMAND_TIMEOUT_SECONDS = 45
REQUEST_TIMEOUT_SECONDS = 30
# Revyl's edge refuses Python's default User-Agent.
HTTP_USER_AGENT = "ShipTok-save-session-sign-in"


class KeyNotSaved(Exception):
    pass


def base64_url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def request_json(url: str, *, method: str = "GET", body: dict[str, str] | None = None, bearer_token: str | None = None) -> dict[str, object]:
    headers = {"Accept": "application/json", "User-Agent": HTTP_USER_AGENT}
    if body is not None:
        headers["Content-Type"] = "application/json"
    if bearer_token is not None:
        headers["Authorization"] = f"Bearer {bearer_token}"
    request = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise KeyNotSaved(f"{urllib.parse.urlsplit(url).netloc} answered {error.code} to {method} {urllib.parse.urlsplit(url).path}") from None


def sign_in_callback_url(authorization_url: str, sign_in_link: str | None) -> str:
    callback_urls: list[str] = []

    # The page sends the browser on to the app's URL scheme. Chrome can't open the scheme but still requests it, so the code is read from that request.
    def read_sign_in_callback(request: Request) -> None:
        if request.url.startswith(SIGN_IN_CALLBACK_URL_PREFIX):
            callback_urls.append(request.url)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome", headless=sign_in_link is not None)
        try:
            page = browser.new_page()
            page.set_default_timeout(PAGE_TIMEOUT_MILLISECONDS)
            page.on("request", read_sign_in_callback)
            if sign_in_link is not None:
                page.goto(sign_in_link)
                page.wait_for_load_state("networkidle")
            page.goto(authorization_url)
            continue_button = page.get_by_role("button", name="Continue to ShipTok")
            if sign_in_link is not None:
                continue_button.click()
            else:
                print("Sign the Chrome window in to Revyl as the test account, then press Continue to ShipTok.")
            deadline_unix_seconds = time.time() + (CALLBACK_WAIT_SECONDS if sign_in_link is None else PAGE_TIMEOUT_MILLISECONDS / 1000)
            while not callback_urls and time.time() < deadline_unix_seconds:
                page.wait_for_timeout(1_000)
            if not callback_urls:
                raise KeyNotSaved(f"Revyl's sign-in didn't return to ShipTok; the browser stopped on {urllib.parse.urlsplit(page.url).path}")
            return callback_urls[0]
        finally:
            browser.close()


def run_revyl(arguments: list[str]) -> bool:
    try:
        return subprocess.run(["revyl", *arguments], capture_output=True, text=True, timeout=REVYL_COMMAND_TIMEOUT_SECONDS).returncode == 0
    except subprocess.TimeoutExpired:
        raise KeyNotSaved(f"saving {REVYL_API_KEY_LAUNCH_VARIABLE_KEY} timed out") from None


def save_launch_variable(revyl_api_key: str) -> None:
    secret_flags = ["--secret", "--readable-by-automated-runs"]
    if run_revyl(["global", "launch-var", "get", REVYL_API_KEY_LAUNCH_VARIABLE_KEY]):
        saved = run_revyl(["global", "launch-var", "update", REVYL_API_KEY_LAUNCH_VARIABLE_KEY, "--value", revyl_api_key, *secret_flags])
    else:
        saved = run_revyl(["global", "launch-var", "create", f"{REVYL_API_KEY_LAUNCH_VARIABLE_KEY}={revyl_api_key}", *secret_flags])
    if not saved:
        raise KeyNotSaved(f"saving {REVYL_API_KEY_LAUNCH_VARIABLE_KEY} failed")


def main() -> int:
    parser = argparse.ArgumentParser(description="Save the ShipTok key Revyl sessions and tests sign in with.")
    parser.add_argument("--backend-url", default=DEFAULT_SHIPTOK_REVYL_BACKEND_URL)
    parser.add_argument("--sign-in-link-file", type=Path)
    arguments = parser.parse_args()
    backend_url = arguments.backend_url.rstrip("/")
    try:
        sign_in_link = arguments.sign_in_link_file.read_text().strip() if arguments.sign_in_link_file else None
        state = base64_url(secrets.token_bytes(32))
        code_verifier = base64_url(secrets.token_bytes(48))
        code_challenge = base64_url(hashlib.sha256(code_verifier.encode()).digest())
        authorization_url = str(request_json(
            f"{backend_url}/api/v1/shiptok/revyl-sign-in/authorization-url?"
            + urllib.parse.urlencode({"state": state, "code_challenge": code_challenge})
        )["authorization_url"])
        callback_query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(sign_in_callback_url(authorization_url, sign_in_link)).query))
        if callback_query.get("state") != state:
            raise KeyNotSaved("Revyl returned another sign-in's state")
        if not callback_query.get("code"):
            raise KeyNotSaved("Revyl returned no code")
        revyl_api_key = str(request_json(
            f"{backend_url}/api/v1/shiptok/revyl-sign-in/api-keys",
            method="POST",
            body={"code": callback_query["code"], "code_verifier": code_verifier, "device_label": DEVICE_LABEL},
        )["revyl_api_key"])
        revyl_account = request_json(f"{backend_url}/api/v1/shiptok/revyl-account", bearer_token=revyl_api_key)
        save_launch_variable(revyl_api_key)
    except KeyNotSaved as failure:
        print(f"Key not saved: {failure}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"Key not saved: failed with {type(error).__name__}", file=sys.stderr)
        return 1
    print(f"Saved {revyl_account['email']}'s ShipTok key for {urllib.parse.urlsplit(backend_url).netloc} in {REVYL_API_KEY_LAUNCH_VARIABLE_KEY}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
