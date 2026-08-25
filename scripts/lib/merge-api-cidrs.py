#!/usr/bin/env python3
"""Decide what cluster_endpoint_public_access_cidrs should hold for THIS machine.

Reads IP (a bare IPv4 address) and HAVE (the whole tfvars line, or empty) from the environment.
Prints either COVERED -- the list already admits this address, change nothing -- or the
space-separated CIDRs the list should become.

Called only by scripts/refresh-api-cidr.sh --ensure; see the comment at that call site for why a
/32 is dropped while every broader entry is kept.
"""
import ipaddress
import os
import re
import sys


def network(entry):
    try:
        return ipaddress.ip_network(entry, strict=False)
    except ValueError:
        return None


def main():
    ip = ipaddress.ip_address(os.environ['IP'])
    entries = re.findall(r'"([^"]*)"', os.environ.get('HAVE', ''))

    for entry in entries:
        net = network(entry)
        if net is not None and ip in net:
            print('COVERED')
            return 0

    kept = [e for e in entries if (network(e) is None or network(e).prefixlen != 32)]
    print(' '.join(kept + [f'{ip}/32']))
    return 0


if __name__ == '__main__':
    sys.exit(main())
