import io

import numpy as np
import open_clip
import torch
from PIL import Image

from app.config import ServerConfig


class OpenClipEncoder:
    def __init__(self, config: ServerConfig) -> None:
        self._config = config
        self._device = torch.device(config.device)
        model, _, preprocess = open_clip.create_model_and_transforms(
            config.arch, pretrained=config.pretrained
        )
        model.eval()
        model.to(self._device)
        self._model = model
        self._preprocess = preprocess
        self._tokenizer = open_clip.get_tokenizer(config.arch)
        self._validate_dimension()
        self._warmup()

    def _validate_dimension(self) -> None:
        probe = self.encode_texts(["dimension probe"])[0]
        if len(probe) != self._config.dimension:
            raise RuntimeError(
                f"Model '{self._config.model_name}' produces {len(probe)}-dim embeddings "
                f"but MULTIMODAL_DIMENSION={self._config.dimension}. Set "
                f"MULTIMODAL_DIMENSION={len(probe)}, recreate the content_vector index, and re-crawl."
            )

    def _warmup(self) -> None:
        buffer = io.BytesIO()
        Image.new("RGB", (224, 224), (0, 0, 0)).save(buffer, format="PNG")
        self.encode_images([buffer.getvalue()])

    @property
    def info(self) -> dict:
        return {
            "model": self._config.model_name,
            "dimension": self._config.dimension,
            "device": self._config.device,
        }

    def encode_texts(self, texts: list[str]) -> list[list[float]]:
        tokens = self._tokenizer(texts).to(self._device)
        with torch.no_grad():
            features = self._model.encode_text(tokens)
            features = features / features.norm(dim=-1, keepdim=True)
        return features.cpu().numpy().astype(np.float32).tolist()

    def encode_images(self, images: list[bytes]) -> list[list[float]]:
        tensors = [
            self._preprocess(Image.open(io.BytesIO(raw)).convert("RGB")) for raw in images
        ]
        batch = torch.stack(tensors).to(self._device)
        with torch.no_grad():
            features = self._model.encode_image(batch)
            features = features / features.norm(dim=-1, keepdim=True)
        return features.cpu().numpy().astype(np.float32).tolist()
