import base64
import io

from fastapi.testclient import TestClient
from PIL import Image

from app.server import create_app


class FakeEncoder:
    def __init__(self):
        self.text_calls = []
        self.image_calls = []

    def encode_texts(self, texts):
        self.text_calls.append(texts)
        return [[float(len(t)), 0.1, 0.2] for t in texts]

    def encode_images(self, images):
        self.image_calls.append(images)
        return [[0.9, 0.8, 0.7] for _ in images]

    @property
    def info(self):
        return {"model": "fake", "dimension": 3, "device": "cpu"}


def _png_b64():
    buf = io.BytesIO()
    Image.new("RGB", (4, 4), (255, 0, 0)).save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


def test_post_text_returns_embedding_envelope():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{"text": "running dogs"}], "execEndpoint": "/"})
    assert resp.status_code == 200
    assert resp.headers["content-type"].startswith("application/json")
    body = resp.json()
    assert list(body.keys()) == ["data"]
    assert body["data"][0]["embedding"] == [12.0, 0.1, 0.2]  # len("running dogs") == 12


def test_post_blob_decodes_image_and_returns_embedding():
    enc = FakeEncoder()
    client = TestClient(create_app(enc))
    resp = client.post("/post", json={"data": [{"blob": _png_b64()}], "execEndpoint": "/"})
    assert resp.status_code == 200
    assert resp.json()["data"][0]["embedding"] == [0.9, 0.8, 0.7]
    assert len(enc.image_calls[0][0]) > 0  # server passed decoded raw bytes


def test_post_preserves_order_for_batch():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{"text": "a"}, {"text": "bb"}]})
    embs = [d["embedding"][0] for d in resp.json()["data"]]
    assert embs == [1.0, 2.0]


def test_post_missing_text_and_blob_is_400():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{}]})
    assert resp.status_code == 400


def test_post_invalid_base64_is_400():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.post("/post", json={"data": [{"blob": "!!!not-base64!!!"}]})
    assert resp.status_code == 400


def test_health_reports_ok_and_info():
    client = TestClient(create_app(FakeEncoder()))
    resp = client.get("/health")
    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "ok"
    assert body["dimension"] == 3
