#!/usr/bin/env python3
"""Print a werkzeug password hash for use as ADMIN_PASSWORD_HASH in secrets.yml.

Usage: python scripts/hash_admin_password.py
Prompts for a password (not echoed), prints the resulting hash to stdout.
"""
import getpass
from werkzeug.security import generate_password_hash

if __name__ == '__main__':
    password = getpass.getpass('Admin password: ')
    print(generate_password_hash(password))
