import base64
import binascii
from typing import Protocol

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

from app.errors import ImageDecodeError


class Encoder(Protocol):
    def encode_texts(self, texts: list[str]) -> list[list[float]]: ...

    def encode_images(self, images: list[bytes]) -> list[list[float]]: ...

    @property
    def info(self) -> dict: ...


def create_app(encoder: Encoder) -> FastAPI:
    app = FastAPI()

    @app.get("/health")
    def health() -> dict:
        return {"status": "ok", **encoder.info}

    @app.post("/post")
    async def post(request: Request):
        payload = await request.json()
        docs = payload.get("data") or []
        results: list[dict] = []
        for doc in docs:
            text = doc.get("text")
            blob = doc.get("blob")
            if text is not None:
                embedding = (await run_in_threadpool(encoder.encode_texts, [text]))[0]
            elif blob is not None:
                try:
                    raw = base64.b64decode(blob, validate=True)
                except (binascii.Error, ValueError):
                    return JSONResponse(status_code=400, content={"error": "invalid base64 blob"})
                try:
                    embedding = (await run_in_threadpool(encoder.encode_images, [raw]))[0]
                except ImageDecodeError as exc:
                    return JSONResponse(
                        status_code=400, content={"error": f"invalid image blob: {exc}"}
                    )
            else:
                return JSONResponse(
                    status_code=400, content={"error": "each data item needs 'text' or 'blob'"}
                )
            results.append({"embedding": embedding})
        return JSONResponse(content={"data": results})

    return app


def build_encoder_from_env() -> Encoder:
    from app.config import load_config
    from app.encoder import OpenClipEncoder

    return OpenClipEncoder(load_config())


def create_production_app() -> FastAPI:
    return create_app(build_encoder_from_env())
