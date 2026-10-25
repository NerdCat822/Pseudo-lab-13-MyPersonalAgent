import logging
from collections.abc import Iterator

from fastapi import Request
from sqlalchemy import Engine, create_engine, event, text
from sqlalchemy.orm import DeclarativeBase, Session, sessionmaker

log = logging.getLogger(__name__)


class Base(DeclarativeBase):
    pass


def make_engine(database_url: str) -> Engine:
    connect_args = {"check_same_thread": False} if database_url.startswith("sqlite") else {}
    engine = create_engine(database_url, connect_args=connect_args)
    if database_url.startswith("sqlite"):

        @event.listens_for(engine, "connect")
        def _sqlite_pragmas(dbapi_connection, _record) -> None:
            cursor = dbapi_connection.cursor()
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.execute("PRAGMA busy_timeout=5000")
            cursor.close()

    return engine


def make_session_factory(engine: Engine) -> sessionmaker[Session]:
    return sessionmaker(engine, expire_on_commit=False)


def _ddl_default(column) -> str | None:
    default = column.default
    if default is None or not getattr(default, "is_scalar", False):
        return None
    value = default.arg
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int | float):
        return str(value)
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    return None


def ensure_columns(engine: Engine) -> list[str]:
    """Additive SQLite migration: add model columns that an existing table lacks.

    There is no Alembic yet. New tables come from ``create_all``; this covers the other common
    case (a new column on an existing table) so a dev database keeps its data. Columns that are
    NOT NULL without a scalar default, primary keys and type changes are not handled.
    """
    if engine.dialect.name != "sqlite":
        return []
    added: list[str] = []
    with engine.begin() as conn:
        for table in Base.metadata.sorted_tables:
            rows = conn.execute(text(f'PRAGMA table_info("{table.name}")')).all()
            if not rows:
                continue  # create_all just made it, or it does not exist
            existing = {row[1] for row in rows}
            for column in table.columns:
                if column.name in existing or column.primary_key:
                    continue
                ddl_type = column.type.compile(dialect=engine.dialect)
                default = _ddl_default(column)
                if not column.nullable and default is None:
                    log.warning("cannot add NOT NULL column %s.%s", table.name, column.name)
                    continue
                clause = f'ALTER TABLE "{table.name}" ADD COLUMN "{column.name}" {ddl_type}'
                if default is not None:
                    clause += f" DEFAULT {default}"
                if not column.nullable:
                    clause += " NOT NULL"
                conn.execute(text(clause))
                added.append(f"{table.name}.{column.name}")
    if added:
        log.info("added columns: %s", ", ".join(added))
    return added


def create_tables(engine: Engine) -> None:
    from app import models  # noqa: F401  (registers tables on Base.metadata)

    Base.metadata.create_all(engine)
    ensure_columns(engine)


def get_db(request: Request) -> Iterator[Session]:
    with request.app.state.session_factory() as session:
        yield session
