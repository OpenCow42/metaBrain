#!/usr/bin/env python3
"""Prepare an offline capture plan for a supplied URL."""

import argparse
import json
from urllib.parse import parse_qsl, urlsplit


PRIVATE_PARAMETERS = {"access_token", "api_key", "apikey", "auth", "authorization", "key",
                      "password", "sig", "signature", "token", "x-goog-signature", "x-amz-signature"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    args = parser.parse_args()
    url = args.url

    try:
        if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in url):
            raise ValueError
        parts = urlsplit(url)
        port = parts.port
        if (parts.scheme not in ("http", "https") or not parts.hostname or
                parts.username is not None or "\\" in parts.netloc or port == 0):
            raise ValueError
    except ValueError:
        parser.error("Supply an absolute HTTP or HTTPS URL without credentials or whitespace.")

    if any(key.lower() in PRIVATE_PARAMETERS for key, _ in parse_qsl(parts.query, keep_blank_values=True)):
        parser.error("Supply a provenance URL without credentials or signed parameters.")

    print(json.dumps({"origin": url, "state": "requires-original",
                      "acceptedMediaTypes": ["text/html", "text/markdown"]}, sort_keys=True))


if __name__ == "__main__":
    main()
