#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["playwright==1.65.2"]
# ///
"""Saves the GitHub grant the signed-in session profile hands out (scripts/revyl/signed-in-session-profile.py).

It signs in to GitHub as revyl-shiptok-tests through ShipTok's own GitHub sign-in, in headless Google Chrome,
redeems the code through Revyl's backend as the app does, checks that the tokens belong to revyl-shiptok-tests,
and saves them as the two Revyl global variables the profile reads. Run it from the repository root with a
member's own Revyl login or personal API key, which the variables' secrets and mark need. It is a sign-in as
revyl-shiptok-tests, so it never overlaps another one (AGENTS.md, "Revyl").

Nothing this prints holds a password, code or token.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import Request, sync_playwright

SHIPTOK_REVYL_BACKEND_URL = "https://backend.revyl.ai"
SIGN_IN_CALLBACK_URL_PREFIX = "shiptok://github-sign-in-callback"
USERNAME_GLOBAL_VARIABLE_NAME = "shiptok-github-sign-in-username"
PASSWORD_GLOBAL_VARIABLE_NAME = "shiptok-github-sign-in-password"
TOTP_SECRET_GLOBAL_VARIABLE_NAME = "shiptok-github-sign-in-totp-secret"
ACCESS_TOKEN_GLOBAL_VARIABLE_NAME = "shiptok-revyl-shiptok-tests-github-user-access-token"
REFRESH_TOKEN_GLOBAL_VARIABLE_NAME = "shiptok-revyl-shiptok-tests-github-refresh-token"
EXPECTED_GITHUB_LOGIN = "revyl-shiptok-tests"
PAGE_TIMEOUT_MILLISECONDS = 30_000
CALLBACK_WAIT_SECONDS = 60
REVYL_COMMAND_TIMEOUT_SECONDS = 45
REQUEST_TIMEOUT_SECONDS = 30
# Revyl's edge refuses Python's default User-Agent.
HTTP_USER_AGENT = "ShipTok-save-test-account-github-sign-in"


class GrantNotSaved(Exception):
    pass


def base64_url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def run_revyl(arguments: list[str]) -> str:
    try:
        result = subprocess.run(["revyl", *arguments], capture_output=True, text=True, timeout=REVYL_COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        raise GrantNotSaved(f"revyl global var {arguments[2]} {arguments[3].split('=')[0]} timed out") from None
    if result.returncode != 0:
        raise GrantNotSaved(f"revyl global var {arguments[2]} {arguments[3].split('=')[0]} failed")
    return result.stdout


def reveal_global_variable(variable_name: str) -> str:
    value = json.loads(run_revyl(["global", "var", "get", variable_name, "--reveal", "--json"])).get("variable_value")
    if not value:
        raise GrantNotSaved(f"{variable_name} is empty")
    return value


def current_totp_code(totp_secret: str) -> str:
    normalized_secret = "".join(totp_secret.split()).replace("-", "").upper()
    key = base64.b32decode(normalized_secret + "=" * (-len(normalized_secret) % 8))
    # A code typed in a period's last seconds can arrive after it changes, so this waits for a fresh period.
    if 30 - time.time() % 30 < 10:
        time.sleep(30 - time.time() % 30 + 1)
    digest = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    return f"{(struct.unpack('>I', digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000:06d}"


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
        raise GrantNotSaved(f"{urllib.parse.urlsplit(url).netloc} answered {error.code} to {method} {urllib.parse.urlsplit(url).path}") from None


def github_sign_in_callback_url(authorization_url: str, username: str, password: str, totp_secret: str) -> str:
    callback_urls: list[str] = []

    # GitHub sends the browser on to the app's URL scheme by a redirect or by the script on its "You are being redirected" page. Chrome can't open the scheme but still requests it, so the code is read from that request.
    def read_sign_in_callback(request: Request) -> None:
        if request.url.startswith(SIGN_IN_CALLBACK_URL_PREFIX):
            callback_urls.append(request.url)

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(channel="chrome", headless=True)
        try:
            context = browser.new_context(user_agent=browser.new_page().evaluate("navigator.userAgent").replace("HeadlessChrome", "Chrome"))
            page = context.new_page()
            page.set_default_timeout(PAGE_TIMEOUT_MILLISECONDS)
            page.on("request", read_sign_in_callback)
            page.goto(authorization_url)
            page.fill("#login_field", username)
            page.fill("#password", password)
            page.click("input[name='commit']")
            page.wait_for_selector("#app_totp")
            page.fill("#app_totp", current_totp_code(totp_secret))
            # GitHub submits a typed code by itself and takes each code once, so Verify is pressed only once, and only if the page is still waiting on it.
            verify_pressed = False
            deadline_unix_seconds = time.time() + CALLBACK_WAIT_SECONDS
            while not callback_urls and time.time() < deadline_unix_seconds:
                page.wait_for_timeout(3_000)
                try:
                    verify_button = page.locator("form:has(#app_totp) button[type='submit']")
                    if not verify_pressed and verify_button.count() and verify_button.first.is_visible():
                        verify_pressed = True
                        verify_button.first.click()
                        continue
                    # Revyl's App may need authorizing, with a button that starts disabled, and GitHub may offer a passkey.
                    for button in (
                        page.locator("button[name='authorize'][value='1']"),
                        page.locator("button:has-text('Ask me later'), a:has-text('Ask me later'), button:has-text('Not now')"),
                    ):
                        if button.count() and button.first.is_visible() and button.first.is_enabled():
                            button.first.click()
                            break
                except PlaywrightError:
                    continue
            if not callback_urls:
                try:
                    page_labels = [" ".join(text.split())[:80] for text in page.locator("h1:visible, h2:visible, h3:visible, button:visible").all_inner_texts()][:8]
                except PlaywrightError:
                    page_labels = []
                raise GrantNotSaved(f"GitHub didn't return to ShipTok; the browser stopped on {urllib.parse.urlsplit(page.url).path}, showing {page_labels}")
            return callback_urls[0]
        finally:
            browser.close()


def main() -> int:
    try:
        username = reveal_global_variable(USERNAME_GLOBAL_VARIABLE_NAME)
        if username.lower() != EXPECTED_GITHUB_LOGIN:
            raise GrantNotSaved(f"{USERNAME_GLOBAL_VARIABLE_NAME} names another account")
        password = reveal_global_variable(PASSWORD_GLOBAL_VARIABLE_NAME)
        totp_secret = reveal_global_variable(TOTP_SECRET_GLOBAL_VARIABLE_NAME)
        state = base64_url(secrets.token_bytes(32))
        code_verifier = base64_url(secrets.token_bytes(48))
        code_challenge = base64_url(hashlib.sha256(code_verifier.encode()).digest())
        authorization_url = str(request_json(
            f"{SHIPTOK_REVYL_BACKEND_URL}/api/v1/shiptok/github-sign-in/authorization-url?"
            + urllib.parse.urlencode({"state": state, "code_challenge": code_challenge})
        )["authorization_url"])
        # GitHub keeps ten tokens per user, App and scope and revokes the least recently used beyond that, so the grant asks for offline_access, the one scope a GitHub App takes, to stay apart from the journeys' sign-ins.
        authorization_url += "&" + urllib.parse.urlencode({"scope": "offline_access"})
        callback_query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(github_sign_in_callback_url(authorization_url, username, password, totp_secret)).query))
        if callback_query.get("state") != state:
            raise GrantNotSaved("GitHub returned another sign-in's state")
        if not callback_query.get("code"):
            raise GrantNotSaved("GitHub returned no code")
        received_at_unix_seconds = time.time()
        tokens = request_json(
            f"{SHIPTOK_REVYL_BACKEND_URL}/api/v1/shiptok/github-sign-in/user-access-tokens",
            method="POST",
            body={"code": callback_query["code"], "code_verifier": code_verifier},
        )
        access_token = str(tokens["access_token"])
        signed_in_login = str(request_json("https://api.github.com/user", bearer_token=access_token)["login"])
        if signed_in_login.lower() != EXPECTED_GITHUB_LOGIN:
            raise GrantNotSaved("the tokens belong to another GitHub account")
        if not tokens.get("refresh_token"):
            raise GrantNotSaved("GitHub issued no refresh token, so the grant couldn't be renewed")
        expires_in_seconds = tokens.get("access_token_expires_in_seconds")
        # The refresh token goes first: the profile renews from it, and an access token saved without it would expire with nothing to renew it.
        run_revyl(["global", "var", "set", f"{REFRESH_TOKEN_GLOBAL_VARIABLE_NAME}={tokens['refresh_token']}", "--secret", "--readable-by-automated-runs=false"])
        run_revyl([
            "global", "var", "set",
            f"{ACCESS_TOKEN_GLOBAL_VARIABLE_NAME}=" + json.dumps({
                "access_token": access_token,
                "access_token_expires_at_unix_seconds": None if expires_in_seconds is None else int(received_at_unix_seconds + float(expires_in_seconds)),
            }),
            "--secret", "--readable-by-automated-runs",
        ])
    except GrantNotSaved as failure:
        print(f"Grant not saved: {failure}", file=sys.stderr)
        return 1
    except Exception as error:
        print(f"Grant not saved: failed with {type(error).__name__}", file=sys.stderr)
        return 1
    print(f"Saved {EXPECTED_GITHUB_LOGIN}'s GitHub grant in {ACCESS_TOKEN_GLOBAL_VARIABLE_NAME} and {REFRESH_TOKEN_GLOBAL_VARIABLE_NAME}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
