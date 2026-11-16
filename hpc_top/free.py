"""`hpc free`: the resource classes with a free GPU slice right now, per node."""

import subprocess
import sys

from hpc_top.data import NODES_COMMAND, Cluster, Node, free_classes, free_text, parse_node, target


def report(nodes: tuple[Node, ...]) -> str:
    return "\n".join(f"{node.name}  {free_text(node)}" for node in nodes)


def require_free(nodes: tuple[Node, ...], name: str) -> None:
    """Exit with the report as message unless some node has a free slice of the class."""
    if not any(name in free_classes(node) for node in nodes):
        raise SystemExit(f"hpc: no free {name} slice now\n{report(nodes)}")


def main() -> None:
    try:
        output = Cluster(target()).run(NODES_COMMAND)
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr.strip())
    nodes = tuple(parse_node(line) for line in output.splitlines())
    if sys.argv[1:]:
        require_free(nodes, sys.argv[1])
    else:
        print(report(nodes))
