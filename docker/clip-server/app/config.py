import os
from dataclasses import dataclass


@dataclass(frozen=True)
class ServerConfig:
    model_name: str
    arch: str
    pretrained: str | None
    dimension: int
    device: str
    port: int


def parse_model_name(model_name: str) -> tuple[str, str | None]:
    """Split an open_clip 'arch::pretrained' name into (arch, pretrained)."""
    if "::" in model_name:
        arch, pretrained = model_name.split("::", 1)
        return arch, pretrained
    return model_name, None


def resolve_device(preference: str) -> str:
    """Resolve 'auto' to cuda when available; otherwise return the preference."""
    if preference == "auto":
        import torch

        return "cuda" if torch.cuda.is_available() else "cpu"
    return preference


def load_config() -> ServerConfig:
    model_name = os.environ.get(
        "CLIP_MODEL_NAME", "xlm-roberta-base-ViT-B-32::laion5b-s13b-b90k"
    )
    arch, pretrained = parse_model_name(model_name)
    return ServerConfig(
        model_name=model_name,
        arch=arch,
        pretrained=pretrained,
        dimension=int(os.environ.get("MULTIMODAL_DIMENSION", "512")),
        device=resolve_device(os.environ.get("CLIP_DEVICE", "cpu")),
        port=int(os.environ.get("CLIP_SERVER_PORT", "51000")),
    )
