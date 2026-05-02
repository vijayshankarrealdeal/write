"""Set a user's password by email.

Bcrypt-hashes the supplied password using the same CryptContext the
auth router uses, then writes it to users.password_hash.

Usage (from the production VM):

    docker compose exec fastapi python /app/scripts/set_user_password.py \
        --email inkspacex@inkspacex.com \
        --password 'the-new-plaintext'

Read the password from a file/stdin instead of an arg if you don't want
it landing in shell history:

    docker compose exec -T fastapi python /app/scripts/set_user_password.py \
        --email inkspacex@inkspacex.com --stdin <<<"the-new-plaintext"
"""

from __future__ import annotations

import argparse
import asyncio
import sys


def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Set users.password_hash by email.")
    p.add_argument("--email", required=True)
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--password", help="Plaintext password (visible in argv).")
    g.add_argument("--stdin", action="store_true", help="Read password from stdin.")
    return p.parse_args()


async def _main() -> int:
    args = _parse_args()
    plaintext = sys.stdin.read().rstrip("\n") if args.stdin else args.password
    if not plaintext:
        print("Empty password.", file=sys.stderr)
        return 2

    sys.path.insert(0, "/app")

    from passlib.context import CryptContext
    from sqlalchemy import select
    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from app.config import settings
    from app.models.user import User

    pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
    new_hash = pwd_context.hash(plaintext)

    engine = create_async_engine(settings.database_url, future=True)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as db:
        user = (
            await db.execute(select(User).where(User.email == args.email))
        ).scalar_one_or_none()
        if user is None:
            print(f"No user with email {args.email!r}", file=sys.stderr)
            return 1
        user.password_hash = new_hash
        await db.commit()
        print(f"[db] password updated for user_id={user.id} email={args.email}")

    await engine.dispose()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(_main()))
