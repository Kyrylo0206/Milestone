#!/usr/bin/env python3
"""Offline check of the ADR 0003 subnet plan. Run: python3 -I scripts/test_cidr.py

Needs only the standard library. Exit code 0 means every assertion passed.
"""
import ipaddress
import sys

AWS_RESERVED = 5  # network, router, DNS, future use, broadcast

VPC = ipaddress.ip_network("10.20.0.0/16")
CREATED = {
    "public-a": ("10.20.0.0/24", 256, 251),
    "public-b": ("10.20.1.0/24", 256, 251),
    "private-a": ("10.20.16.0/20", 4096, 4091),
    "private-b": ("10.20.32.0/20", 4096, 4091),
}
RESERVED = ["10.20.2.0/24", "10.20.48.0/20", "10.20.64.0/18", "10.20.128.0/17"]


def main():
    nets = {}
    for name, (cidr, total, usable) in CREATED.items():
        net = ipaddress.ip_network(cidr)
        nets[name] = net
        assert net.subnet_of(VPC), f"{name} {net} is not inside {VPC}"
        assert net.num_addresses == total, f"{name} size {net.num_addresses} != {total}"
        assert net.num_addresses - AWS_RESERVED == usable, f"{name} usable mismatch"
        print(f"ok {name:10} {str(net):15} total {net.num_addresses:5} usable {net.num_addresses - AWS_RESERVED}")

    assert VPC.num_addresses == 65536
    names = list(nets)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            assert not nets[a].overlaps(nets[b]), f"{a} overlaps {b}"

    reserved = [ipaddress.ip_network(r) for r in RESERVED]
    for r in reserved:
        assert r.subnet_of(VPC), f"reserved {r} outside VPC"
        for name, net in nets.items():
            assert not net.overlaps(r), f"{name} overlaps reserved {r}"
    for i, a in enumerate(reserved):
        for b in reserved[i + 1:]:
            assert not a.overlaps(b), f"reserved {a} overlaps {b}"

    public_block = ipaddress.ip_network("10.20.0.0/20")
    assert nets["public-a"].subnet_of(public_block) and nets["public-b"].subnet_of(public_block)
    for name, net in nets.items():
        assert int(net.network_address) % net.num_addresses == 0, f"{name} not aligned"
    print("all assertions passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
