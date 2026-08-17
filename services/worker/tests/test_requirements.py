"""requirements.txt must match what the worker actually imports -- in both directions.

Same guard as the backend's copy of this test, deliberately duplicated rather than shared: backend
and worker are separate Docker build contexts with no shared Python package (see CLAUDE.md), so a
shared helper would have to live somewhere neither build context can reach.

The worker's case differs in one way worth knowing: boto3 IS a real dependency here (SNS milestone
alerts, S3 snapshot export), unlike the backend, where it was dead weight. Only pytest moved out.
"""
import ast
import pathlib
import sys

SRC_DIR = pathlib.Path(__file__).resolve().parent.parent

# Distribution name -> the name you actually `import`. Only needed where they differ.
IMPORT_NAME = {'psycopg2-binary': 'psycopg2', 'prometheus-client': 'prometheus_client'}

# Nothing here is invoked as a binary rather than imported.
RUNTIME_ONLY = set()  # the worker is a plain `python worker.py` loop, no binary-only deps


def _declared():
    reqs = {}
    for line in (SRC_DIR / 'requirements.txt').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith(('#', '-r')):
            continue
        dist = line.split('==')[0].split('[')[0].strip().lower()
        reqs[dist] = IMPORT_NAME.get(dist, dist)
    return reqs


def _local_modules():
    return {p.stem for p in SRC_DIR.glob('*.py')}


def _imported_third_party():
    local, stdlib = _local_modules(), sys.stdlib_module_names
    found = set()
    for path in SRC_DIR.glob('*.py'):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                # level > 0 is a relative import, always local
                names = [node.module] if node.module and node.level == 0 else []
            else:
                continue
            for name in names:
                root = name.split('.')[0]
                if root and root not in local and root not in stdlib:
                    found.add(root.lower())
    return found


def test_no_declared_dependency_is_unused():
    unused = {
        dist for dist, mod in _declared().items()
        if dist not in RUNTIME_ONLY and mod not in _imported_third_party()
    }
    assert not unused, (
        f'requirements.txt declares {sorted(unused)}, which the worker never imports. '
        'Remove them, or add to RUNTIME_ONLY if invoked as a binary rather than imported.'
    )


def test_no_imported_dependency_is_undeclared():
    declared = set(_declared().values())
    undeclared = _imported_third_party() - declared
    assert not undeclared, (
        f'{sorted(undeclared)} are imported by the worker but not in requirements.txt. '
        'Do not rely on another package pulling them in transitively.'
    )


def test_pytest_is_not_a_production_dependency():
    """It belongs in requirements-dev.txt; the Dockerfile installs requirements.txt only."""
    assert 'pytest' not in _declared(), 'pytest must not ship in the production image'
    assert 'pytest' in (SRC_DIR / 'requirements-dev.txt').read_text()
