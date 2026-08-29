#!/usr/bin/env python3
"""Upsert the single AI Phone model profile in an offline Open WebUI SQLite DB."""

from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import sqlite3
import sys
import time


MODEL_ID = "qwen3.8-uncensored-agent"
BASE_MODEL_ID = "qwen3.8-uncensored"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--database",
        type=pathlib.Path,
        default=pathlib.Path("/workspace/open-webui-data/webui.db"),
    )
    parser.add_argument(
        "--system-prompt",
        type=pathlib.Path,
        default=pathlib.Path(__file__).with_name("system-prompt.txt"),
    )
    parser.add_argument(
        "--backup-dir",
        type=pathlib.Path,
        default=pathlib.Path("/workspace/open-webui-data/backups"),
    )
    return parser.parse_args()


def table_columns(connection: sqlite3.Connection, table: str) -> set[str]:
    return {str(row[1]) for row in connection.execute(f"PRAGMA table_info({table!r})")}


def main() -> int:
    args = parse_args()
    if not args.database.is_file():
        raise RuntimeError(f"base Open WebUI absente: {args.database}")
    prompt = args.system_prompt.read_text(encoding="utf-8").strip()
    if len(prompt) < 100:
        raise RuntimeError("prompt système absent ou trop court")

    args.backup_dir.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
    backup = args.backup_dir / f"webui-before-ai-phone-{stamp}.db"
    shutil.copy2(args.database, backup)

    connection = sqlite3.connect(args.database, timeout=30)
    try:
        connection.execute("PRAGMA foreign_keys = ON")
        user_columns = table_columns(connection, "user")
        model_columns = table_columns(connection, "model")
        required_user = {"id", "role"}
        required_model = {
            "id",
            "user_id",
            "base_model_id",
            "name",
            "params",
            "meta",
            "is_active",
            "updated_at",
            "created_at",
        }
        if not required_user.issubset(user_columns) or not required_model.issubset(
            model_columns
        ):
            raise RuntimeError("schéma Open WebUI inattendu; aucune modification appliquée")

        admin = connection.execute(
            "SELECT id FROM user WHERE role = 'admin' ORDER BY created_at LIMIT 1"
        ).fetchone()
        if not admin:
            raise RuntimeError("aucun compte administrateur Open WebUI")

        params = {
            "system": prompt,
            "function_calling": "native",
            "temperature": 0.7,
            "top_p": 0.9,
        }
        meta = {
            "description": (
                "Qwen3.8 27B local avec recherche web, Python, GitHub et FLUX 720p"
            ),
            "capabilities": {
                "file_context": True,
                "file_upload": True,
                "web_search": True,
                "image_generation": True,
                "code_interpreter": True,
                "citations": True,
                "status_updates": True,
                "usage": True,
                "builtin_tools": True,
            },
            "tags": [{"name": "local"}, {"name": "agent"}],
            "toolIds": ["server:ai_phone"],
            "defaultFeatureIds": [
                "web_search",
                "code_interpreter",
                "image_generation",
            ],
            "builtinTools": {
                "web_search": True,
                "code_interpreter": True,
            },
        }
        now = int(time.time())
        connection.execute(
            """
            INSERT INTO model (
                id, user_id, base_model_id, name, params, meta,
                is_active, updated_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                user_id = excluded.user_id,
                base_model_id = excluded.base_model_id,
                name = excluded.name,
                params = excluded.params,
                meta = excluded.meta,
                is_active = 1,
                updated_at = excluded.updated_at
            """,
            (
                MODEL_ID,
                str(admin[0]),
                BASE_MODEL_ID,
                "Qwen3.8 27B — Agent mobile",
                json.dumps(params, ensure_ascii=False),
                json.dumps(meta, ensure_ascii=False),
                now,
                now,
            ),
        )
        connection.commit()
        row = connection.execute(
            "SELECT id, base_model_id, is_active FROM model WHERE id = ?", (MODEL_ID,)
        ).fetchone()
        if row != (MODEL_ID, BASE_MODEL_ID, 1):
            raise RuntimeError("vérification du profil modèle échouée")
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

    print(
        json.dumps(
            {
                "status": "ok",
                "model_id": MODEL_ID,
                "base_model_id": BASE_MODEL_ID,
                "backup": str(backup),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, sqlite3.Error) as exc:
        print(json.dumps({"status": "error", "error": str(exc)}), file=sys.stderr)
        raise SystemExit(1) from exc
