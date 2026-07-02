from app.config import load_config, parse_model_name


def test_parse_model_name_with_pretrained():
    assert parse_model_name("xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k") == (
        "xlm-roberta-base-ViT-B-32",
        "laion5b-s13b-b90k",
    )


def test_parse_model_name_without_pretrained():
    assert parse_model_name("ViT-B-32") == ("ViT-B-32", None)


def test_load_config_defaults(monkeypatch):
    monkeypatch.delenv("CLIP_MODEL_NAME", raising=False)
    monkeypatch.setenv("CLIP_DEVICE", "cpu")
    monkeypatch.setenv("MULTIMODAL_DIMENSION", "512")
    cfg = load_config()
    assert cfg.arch == "xlm-roberta-base-ViT-B-32"
    assert cfg.pretrained == "laion5b-s13b-b90k"
    assert cfg.dimension == 512
    assert cfg.device == "cpu"
    assert cfg.port == 51000
