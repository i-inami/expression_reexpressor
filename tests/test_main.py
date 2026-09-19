from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_reexpress_rejects_code_injection():
    r = client.post(
        "/reexpress",
        json={
            "expressions": ["__import__('os').system('echo pwned')"],
            "variable": "x",
        },
    )
    assert r.status_code == 400


def test_reexpress_rejects_dunder_attribute_walk():
    r = client.post(
        "/reexpress",
        json={
            "expressions": ["().__class__.__bases__[0].__subclasses__()"],
            "variable": "x",
        },
    )
    assert r.status_code == 400


def test_reexpress_rejects_builtin_via_bare_name():
    # No underscores or quotes -- passes any character allowlist, but sympy's
    # default parse_expr namespace still resolves bare builtin names for real.
    r = client.post(
        "/reexpress",
        json={"expressions": ["eval(chr(49)+chr(43)+chr(49))"], "variable": "x"},
    )
    assert r.status_code == 400


def test_reexpress_single_solution():
    r = client.post("/reexpress", json={"expressions": ["y=a*x+b"], "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(y - b)/a"]}


def test_reexpress_multiple_solutions():
    r = client.post("/reexpress", json={"expressions": ["x**2=4"], "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expressions": ["-2", "2"]}


def test_reexpress_no_solution():
    r = client.post("/reexpress", json={"expressions": ["x=x+1"], "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expressions": []}


def test_reexpress_multiple_equations():
    r = client.post(
        "/reexpress",
        json={"expressions": ["y=a*x+b", "z=c*y"], "variable": "x"},
    )
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(y - b)/a"]}


def test_reexpress_required_substitutes_intermediate_variable():
    r = client.post(
        "/reexpress",
        json={
            "expressions": ["y=a*x+b", "z=c*y"],
            "variable": "x",
            "required": ["z"],
        },
    )
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(-b + z/c)/a"]}


def test_reexpress_required_multiple_variables_skips_substitution():
    r = client.post(
        "/reexpress",
        json={
            "expressions": ["y=a*x+b", "z=c*y"],
            "variable": "x",
            "required": ["z", "y"],
        },
    )
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(y - b)/a"]}


def test_reexpress_required_leaves_unresolvable_symbols():
    r = client.post(
        "/reexpress",
        json={
            "expressions": ["y=a*x+b"],
            "variable": "x",
            "required": ["z"],
        },
    )
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(y - b)/a"]}


def test_reexpress_required_chains_through_multiple_substitutions():
    r = client.post(
        "/reexpress",
        json={
            "expressions": ["y=a*x+b", "w=c*y", "v=d*w", "z=e*v"],
            "variable": "x",
            "required": ["z"],
        },
    )
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(-b + z/(c*d*e))/a"]}
