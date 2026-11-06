"""Offline checks for infra/network.yaml and its params file. Run: python3 -m pytest tests"""
import ipaddress
import json
import os

from cfn_yaml import load_template

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "infra", "network.yaml")
PARAMS = os.path.join(ROOT, "infra", "params", "network-sandbox.json")
KEYS = ["VpcCidr", "PublicSubnet1Cidr", "PublicSubnet2Cidr", "PrivateSubnet1Cidr", "PrivateSubnet2Cidr"]
RESERVED = ["10.20.2.0/24", "10.20.48.0/20", "10.20.64.0/18", "10.20.128.0/17"]


def defaults():
    params = load_template(TEMPLATE)["Parameters"]
    return {k: params[k]["Default"] for k in KEYS}


def from_params_file():
    with open(PARAMS, encoding="utf-8") as handle:
        return {p["ParameterKey"]: p["ParameterValue"] for p in json.load(handle)}


def check(values):
    vpc = ipaddress.ip_network(values["VpcCidr"])
    subs = [ipaddress.ip_network(values[k]) for k in KEYS[1:]]
    reserved = [ipaddress.ip_network(r) for r in RESERVED]
    for s in subs:
        assert s.subnet_of(vpc), f"{s} not inside {vpc}"
        for r in reserved:
            assert not s.overlaps(r), f"{s} overlaps reserved {r}"
    for i, a in enumerate(subs):
        for b in subs[i + 1:]:
            assert not a.overlaps(b), f"{a} overlaps {b}"


def test_defaults():
    check(defaults())


def test_params_file():
    values = from_params_file()
    check(values)
    assert values == {**defaults(), **{k: v for k, v in values.items() if k not in KEYS}}


def test_no_iam_resources():
    resources = load_template(TEMPLATE)["Resources"]
    bad = [n for n, r in resources.items() if r["Type"].startswith("AWS::IAM::")]
    assert not bad, bad


def test_expected_exports():
    outputs = load_template(TEMPLATE)["Outputs"]
    exported = {k for k, v in outputs.items() if "Export" in v}
    expected = {"VpcId", "VpcCidr", "PublicSubnet1Id", "PublicSubnet2Id", "PrivateSubnet1Id",
                "PrivateSubnet2Id", "PublicSubnetIds", "PrivateSubnetIds", "AvailabilityZones",
                "PublicRouteTableId", "PrivateRouteTable1Id", "PrivateRouteTable2Id",
                "S3GatewayEndpointId"}
    assert exported == expected
    assert "Export" not in outputs["NatGatewayId"]


def test_nat_resources_are_conditional():
    resources = load_template(TEMPLATE)["Resources"]
    for name in ["NatEip", "NatGateway", "PrivateDefaultRoute1", "PrivateDefaultRoute2"]:
        assert resources[name].get("Condition") == "CreateNat"


TAGGABLE = {"AWS::EC2::VPC", "AWS::EC2::InternetGateway", "AWS::EC2::Subnet", "AWS::EC2::RouteTable",
            "AWS::EC2::VPCEndpoint", "AWS::EC2::EIP", "AWS::EC2::NatGateway"}


def test_every_taggable_resource_has_name_tag():
    resources = load_template(TEMPLATE)["Resources"]
    for name, r in resources.items():
        if r["Type"] in TAGGABLE:
            keys = [t["Key"] for t in r["Properties"].get("Tags", [])]
            assert "Name" in keys, name


def test_private_route_tables_have_no_unconditional_default_route():
    resources = load_template(TEMPLATE)["Resources"]
    for name, r in resources.items():
        if r["Type"] != "AWS::EC2::Route":
            continue
        rt = r["Properties"]["RouteTableId"]
        if rt in ({"Ref": "PrivateRouteTable1"}, {"Ref": "PrivateRouteTable2"}):
            assert r.get("Condition") == "CreateNat", name
            assert "GatewayId" not in r["Properties"], name
