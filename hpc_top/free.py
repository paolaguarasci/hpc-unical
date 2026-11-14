"""`hpc free`: the resource classes with a free GPU slice right now, per node."""

import subprocess

from hpc_top.data import NODES_COMMAND, Cluster, Node, free_text, parse_node, target


def report(nodes: tuple[Node, ...]) -> str:
    return "\n".join(f"{node.name}  {free_text(node)}" for node in nodes)


def main() -> None:
    try:
        output = Cluster(target()).run(NODES_COMMAND)
    except subprocess.CalledProcessError as error:
        raise SystemExit(error.stderr.strip())
    print(report(tuple(parse_node(line) for line in output.splitlines())))
