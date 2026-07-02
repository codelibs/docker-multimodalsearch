import io

import numpy as np
import pytest
from PIL import Image

from app.config import ServerConfig
from app.encoder import OpenClipEncoder


def _cfg(dimension: int) -> ServerConfig:
    return ServerConfig(
        model_name="xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k",
        arch="xlm-roberta-base-ViT-B-32",
        pretrained="laion5b-s13b-b90k",
        dimension=dimension,
        device="cpu",
        port=51000,
    )


def _cos(a, b):
    a, b = np.asarray(a), np.asarray(b)
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


@pytest.fixture(scope="module")
def encoder():
    return OpenClipEncoder(_cfg(512))


@pytest.mark.integration
def test_text_embedding_is_512_and_normalized(encoder):
    emb = encoder.encode_texts(["a mountain sunset"])[0]
    assert len(emb) == 512
    assert abs(np.linalg.norm(emb) - 1.0) < 1e-3


@pytest.mark.integration
def test_image_embedding_is_512(encoder):
    buf = io.BytesIO()
    Image.new("RGB", (224, 224), (10, 20, 30)).save(buf, format="PNG")
    emb = encoder.encode_images([buf.getvalue()])[0]
    assert len(emb) == 512


@pytest.mark.integration
def test_multilingual_text_projection_differentiates(encoder):
    # Regression test for the fixed bug: multilingual text embeddings must be
    # well-differentiated. Japanese "mountain sunset" must be closer to the
    # English "mountain sunset" than to "a cat".
    ja_sunset, en_sunset, cat = encoder.encode_texts(
        ["山の夕日", "a mountain sunset at dusk", "a photo of a cat"]
    )
    assert _cos(ja_sunset, en_sunset) > _cos(ja_sunset, cat)


@pytest.mark.integration
def test_dimension_mismatch_raises(encoder):
    with pytest.raises(RuntimeError):
        OpenClipEncoder(_cfg(999))
