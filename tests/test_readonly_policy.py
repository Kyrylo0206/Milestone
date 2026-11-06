"""Offline checks for infra/iam-readonly.yaml. Run: python3 -m pytest tests"""
import fnmatch
import os

from cfn_yaml import load_template

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(ROOT, "infra", "iam-readonly.yaml")
OK_VERBS = ("Describe", "List", "Get", "View")
REQUIRED_DENY = {"s3:GetObject", "dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan",
                 "secretsmanager:GetSecretValue", "kms:Decrypt", "lambda:InvokeFunction"}


def statements():
    t = load_template(TEMPLATE)
    doc = t["Resources"]["ReadOnlyViewPolicy"]["Properties"]["PolicyDocument"]
    allow = [s for s in doc["Statement"] if s["Effect"] == "Allow"]
    deny = [s for s in doc["Statement"] if s["Effect"] == "Deny"]
    assert len(allow) == 1 and len(deny) == 1
    return allow[0]["Action"], deny[0]["Action"]


def test_allowed_verbs_are_read_only():
    allow, _ = statements()
    for action in allow:
        service, verb = action.split(":")
        assert action == "apigateway:GET" or verb.startswith(OK_VERBS), action


def test_no_allow_overlaps_deny():
    allow, deny = statements()
    for a in allow:
        for d in deny:
            assert not fnmatch.fnmatchcase(d.lower(), a.lower()), f"{a} covers denied {d}"
            assert not fnmatch.fnmatchcase(a.lower(), d.lower()), f"{d} covers allowed {a}"


def test_s3_get_wildcards_absent():
    allow, _ = statements()
    assert not [a for a in allow if a.startswith("s3:Get") and a.endswith("*")]
    assert not [a for a in allow if a in ("*", "s3:*")]


def test_required_denies_present():
    _, deny = statements()
    assert REQUIRED_DENY <= set(deny)


def test_trust_policy_shape():
    t = load_template(TEMPLATE)
    role = t["Resources"]["ReadOnlyViewRole"]["Properties"]
    st = role["AssumeRolePolicyDocument"]["Statement"]
    assert len(st) == 1 and st[0]["Effect"] == "Allow" and st[0]["Action"] == "sts:AssumeRole"
    assert st[0]["Principal"] == {"AWS": {"Ref": "TrustedPrincipalArn"}}
    cond = st[0]["Condition"]["Fn::If"]
    assert cond[0] == "RequireMfaCondition"
    with_mfa, without_mfa = cond[1], cond[2]
    assert without_mfa == {"StringEquals": {"sts:ExternalId": {"Ref": "ExternalId"}}}
    assert with_mfa["StringEquals"] == without_mfa["StringEquals"]
    assert with_mfa["Bool"] == {"aws:MultiFactorAuthPresent": "true"}


def test_boundary_and_attachment_are_the_same_policy():
    role = load_template(TEMPLATE)["Resources"]["ReadOnlyViewRole"]["Properties"]
    assert role["PermissionsBoundary"] == {"Ref": "ReadOnlyViewPolicy"}
    assert role["ManagedPolicyArns"] == [{"Ref": "ReadOnlyViewPolicy"}]


def test_policy_fits_managed_policy_size_limit():
    # A customer managed policy may have at most 6144 characters, whitespace not counted.
    import json
    doc = load_template(TEMPLATE)["Resources"]["ReadOnlyViewPolicy"]["Properties"]["PolicyDocument"]
    assert len(json.dumps(doc, separators=(",", ":"))) <= 6144


def test_trusted_principal_pattern_rejects_wildcards():
    import re
    pattern = load_template(TEMPLATE)["Parameters"]["TrustedPrincipalArn"]["AllowedPattern"]
    good = ["arn:aws:iam::123456789012:root", "arn:aws:iam::123456789012:role/audit",
            "arn:aws:iam::123456789012:role/team/audit-viewer", "arn:aws:iam::123456789012:user/alice"]
    bad = ["*", "arn:aws:iam::123456789012:role/*", "arn:aws:iam::*:root",
           "arn:aws:iam::123456789012:user/a*", "arn:aws:iam::12345678901:root"]
    for arn in good:
        assert re.match(pattern, arn), arn
    for arn in bad:
        assert not re.match(pattern, arn), arn


def test_max_session_duration_range_matches_iam():
    p = load_template(TEMPLATE)["Parameters"]["MaxSessionDuration"]
    assert p["MinValue"] == 3600 and p["MaxValue"] == 43200
