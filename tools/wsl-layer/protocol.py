from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from typing import Any


@dataclass
class Request:
    op: str
    command: str | None = None
    path: str | None = None
    timeout: float | None = None

    @staticmethod
    def from_json(line: str) -> "Request":
        data = json.loads(line)
        return Request(
            op=data["op"],
            command=data.get("command"),
            path=data.get("path"),
            timeout=data.get("timeout"),
        )


@dataclass
class Event:
    type: str
    data: str | None = None
    stream: str | None = None
    exit_code: int | None = None
    cwd: str | None = None
    message: str | None = None
    pid: int | None = None

    def to_line(self) -> str:
        payload: dict[str, Any] = {"type": self.type}
        for key, value in asdict(self).items():
            if key == "type" or value is None:
                continue
            payload[key] = value
        return json.dumps(payload, ensure_ascii=False)

    @staticmethod
    def from_json(line: str) -> "Event":
        data = json.loads(line)
        return Event(
            type=data["type"],
            data=data.get("data"),
            stream=data.get("stream"),
            exit_code=data.get("exit_code"),
            cwd=data.get("cwd"),
            message=data.get("message"),
            pid=data.get("pid"),
        )


def encode_request(req: Request) -> str:
    payload: dict[str, Any] = {"op": req.op}
    if req.command is not None:
        payload["command"] = req.command
    if req.path is not None:
        payload["path"] = req.path
    if req.timeout is not None:
        payload["timeout"] = req.timeout
    return json.dumps(payload, ensure_ascii=False)
