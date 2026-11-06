"""YAML loader that understands CloudFormation short tags (!Ref, !Sub, ...)."""
import yaml


class CfnLoader(yaml.SafeLoader):
    pass


def _multi(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node, deep=True)
    else:
        value = loader.construct_mapping(node, deep=True)
    if tag_suffix == "Ref":
        return {"Ref": value}
    if tag_suffix == "Condition":
        return {"Condition": value}
    if tag_suffix == "GetAtt" and isinstance(value, str):
        value = value.split(".", 1)
    return {"Fn::" + tag_suffix: value}


CfnLoader.add_multi_constructor("!", _multi)


def load_template(path):
    with open(path, encoding="utf-8") as handle:
        return yaml.load(handle, Loader=CfnLoader)  # noqa: S506 (safe subclass)
