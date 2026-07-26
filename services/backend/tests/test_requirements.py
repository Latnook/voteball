"""requirements.txt must match what the app actually imports -- in both directions.

This exists because both mistakes had already happened here (found 2026-07-26):

  * DECLARED BUT UNUSED -- pydantic, boto3 and pytest were in requirements.txt and shipped into the
    production image. ~40MB of packages the backend never imports, each one more surface for the
    Trivy gate to fail on for reasons nobody introduced.
  * USED BUT UNDECLARED -- werkzeug (admin password hashing) and itsdangerous (session tokens) were
    imported directly while relying on Flask to pull them in transitively. That works right up
    until a Flask release drops one, and then it breaks at *login*, not at install.

Neither is caught by the normal suite: the venv has everything installed either way, so tests pass
while the built image is wrong. Only comparing the declared list against the source catches it.
"""
import ast
import pathlib
import sys

SRC_DIR = pathlib.Path(__file__).resolve().parent.parent

# Distribution name -> the name you actually `import`. Only needed where they differ.
IMPORT_NAME = {'psycopg2-binary': 'psycopg2'}

# Declared, never imported, and correct anyway: the Dockerfile's CMD runs it as a binary.
RUNTIME_ONLY = {'gunicorn'}


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
        f'requirements.txt declares {sorted(unused)}, which the backend never imports. '
        'Remove them, or add to RUNTIME_ONLY if invoked as a binary rather than imported.'
    )


def test_no_imported_dependency_is_undeclared():
    declared = set(_declared().values())
    undeclared = _imported_third_party() - declared
    assert not undeclared, (
        f'{sorted(undeclared)} are imported by the backend but not in requirements.txt. '
        'Do not rely on another package pulling them in transitively.'
    )


def test_pytest_is_not_a_production_dependency():
    """It belongs in requirements-dev.txt; the Dockerfile installs requirements.txt only."""
    assert 'pytest' not in _declared(), 'pytest must not ship in the production image'
    assert 'pytest' in (SRC_DIR / 'requirements-dev.txt').read_text()
