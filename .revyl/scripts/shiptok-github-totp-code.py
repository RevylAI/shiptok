import base64
import hashlib
import hmac
import os
import struct
import sys
import time

PERIOD_SECONDS = 30
DIGITS = 6
MIN_SECONDS_LEFT_IN_PERIOD = 25

secret_base32 = "".join(os.environ["REVYL_VAR_shiptok_github_sign_in_totp_secret"].split()).replace("-", "").upper()
key = base64.b32decode(secret_base32 + "=" * (-len(secret_base32) % 8))
# GitHub accepts each code once, so a retry after a refused code waits for the next one.
previously_typed_code = os.environ.get("REVYL_VAR_github_totp_code", "")


def code_for_period(counter: int) -> str:
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF) % 10**DIGITS
    return f"{code:0{DIGITS}d}"


while True:
    now = time.time()
    seconds_left_in_period = PERIOD_SECONDS - now % PERIOD_SECONDS
    code = code_for_period(int(now) // PERIOD_SECONDS)
    if seconds_left_in_period >= MIN_SECONDS_LEFT_IN_PERIOD and code != previously_typed_code:
        break
    time.sleep(seconds_left_in_period + 0.5)

sys.stdout.write(code)
