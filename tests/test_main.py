from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


def test_reexpress():
    r = client.post("/reexpress", json={"expression": "y=a*x+b", "variable": "x"})
    assert r.status_code == 200
    assert r.json() == {"expression": "(y - b)/a"}
