#!/usr/bin/env python3

import base64
import os
import subprocess
import sys

try:
    from nacl.signing import SigningKey
except ImportError:
    print("Error: PyNaCl is required. Install it with: python3 -m pip install pynacl", file=sys.stderr)
    sys.exit(1)


KEYCHAIN_SERVICE = "https://sparkle-project.org"
KEYCHAIN_ACCOUNT = "ed25519"


def usage() -> int:
    print(f"Usage: {os.path.basename(sys.argv[0])} <path-to-dmg>", file=sys.stderr)
    return 1


def load_private_key() -> bytes:
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                KEYCHAIN_ACCOUNT,
                "-w",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print("Error: security command not found", file=sys.stderr)
        sys.exit(1)
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        message = stderr or "failed to read Sparkle EdDSA key from Keychain"
        print(f"Error: {message}", file=sys.stderr)
        sys.exit(1)

    encoded_key = result.stdout.strip()
    try:
        key_data = base64.b64decode(encoded_key, validate=True)
    except Exception as exc:
        print(f"Error: invalid base64 key data from Keychain: {exc}", file=sys.stderr)
        sys.exit(1)

    if len(key_data) != 96:
        print(
            f"Error: expected 96 decoded key bytes from Keychain, got {len(key_data)}",
            file=sys.stderr,
        )
        sys.exit(1)

    return key_data[:64]


def sign_file(path: str, private_key: bytes) -> tuple[str, int]:
    try:
        with open(path, "rb") as handle:
            payload = handle.read()
    except OSError as exc:
        print(f"Error: unable to read DMG file: {exc}", file=sys.stderr)
        sys.exit(1)

    seed = private_key[:32]
    signing_key = SigningKey(seed)
    signature = signing_key.sign(payload).signature
    return base64.b64encode(signature).decode("ascii"), len(payload)


def main() -> int:
    if len(sys.argv) != 2:
        return usage()

    dmg_path = sys.argv[1]
    if not os.path.isfile(dmg_path):
        print(f"Error: file not found: {dmg_path}", file=sys.stderr)
        return 1

    private_key = load_private_key()
    signature, file_size = sign_file(dmg_path, private_key)

    print(f'sparkle:edSignature="{signature}" length="{file_size}"')
    print(signature)
    return 0


if __name__ == "__main__":
    sys.exit(main())
