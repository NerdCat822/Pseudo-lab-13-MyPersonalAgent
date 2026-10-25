"""ensure_columns keeps an old dev database usable after model changes."""

import sqlite3
from pathlib import Path

from sqlalchemy import inspect

from app.db import create_tables, make_engine


def test_missing_columns_are_added_with_defaults(tmp_path: Path) -> None:
    db_path = tmp_path / "old.db"
    con = sqlite3.connect(db_path)
    # a meetings table as it existed before template/folder were added
    con.executescript(
        """
        CREATE TABLE meetings (
            id VARCHAR(36) PRIMARY KEY, title VARCHAR(255), created_at DATETIME,
            duration_sec FLOAT, status VARCHAR(16), error TEXT, failed_step VARCHAR(32),
            expected_segments INTEGER
        );
        INSERT INTO meetings (id, title, status) VALUES ('m1', '예전 회의', 'done');
        """
    )
    con.commit()
    con.close()

    engine = make_engine(f"sqlite:///{db_path}")
    create_tables(engine)
    columns = {c["name"] for c in inspect(engine).get_columns("meetings")}
    assert {"template", "folder"} <= columns
    with engine.connect() as conn:
        row = conn.exec_driver_sql("SELECT title, template, folder FROM meetings").one()
    assert tuple(row) == ("예전 회의", "meeting", None)
    assert "chat_messages" in inspect(engine).get_table_names()
    create_tables(engine)  # idempotent
    engine.dispose()
