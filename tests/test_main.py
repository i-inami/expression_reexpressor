from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_reexpress_single_solution():
    r = client.post("/reexpress", json={"expression": "y=a*x+b", "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expressions": ["(y - b)/a"]}


def test_reexpress_multiple_solutions():
    r = client.post("/reexpress", json={"expression": "x**2=4", "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expressions": ["-2", "2"]}


def test_reexpress_no_solution():
    r = client.post("/reexpress", json={"expression": "x=x+1", "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expressions": []}
