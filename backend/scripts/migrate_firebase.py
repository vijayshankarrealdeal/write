#!/usr/bin/env python3
"""
One-time migration script: Firebase (Firestore + Storage) → PostgreSQL + MinIO.

Prerequisites:
  pip install firebase-admin sqlalchemy asyncpg miniopy-async

Usage:
  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/serviceAccountKey.json
  export DATABASE_URL=postgresql+asyncpg://inkspacex:changeme@localhost:5432/inkspacex
  export MINIO_ENDPOINT=localhost:9000
  export MINIO_ACCESS_KEY=minioadmin
  export MINIO_SECRET_KEY=minioadmin

  python migrate_firebase.py
"""

import asyncio
import os
import uuid
from datetime import datetime, timezone
from io import BytesIO

import firebase_admin
from firebase_admin import credentials, firestore, storage
from miniopy_async import Minio
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

DATABASE_URL = os.environ.get(
    "DATABASE_URL",
    "postgresql+asyncpg://inkspacex:changeme@localhost:5432/inkspacex",
)
MINIO_ENDPOINT = os.environ.get("MINIO_ENDPOINT", "localhost:9000")
MINIO_ACCESS_KEY = os.environ.get("MINIO_ACCESS_KEY", "minioadmin")
MINIO_SECRET_KEY = os.environ.get("MINIO_SECRET_KEY", "minioadmin")
MINIO_BUCKET = os.environ.get("MINIO_BUCKET", "inkspacex")
MINIO_PUBLIC_URL = os.environ.get("MINIO_PUBLIC_URL", "http://localhost:9000")
FIREBASE_STORAGE_BUCKET = os.environ.get(
    "FIREBASE_STORAGE_BUCKET", "booky-4eb2c.firebasestorage.app"
)

# ---------------------------------------------------------------------------
# Initialize Firebase
# ---------------------------------------------------------------------------

cred = credentials.ApplicationDefault()
firebase_admin.initialize_app(cred, {"storageBucket": FIREBASE_STORAGE_BUCKET})
db_firestore = firestore.client()
bucket = storage.bucket()

# ---------------------------------------------------------------------------
# Initialize PostgreSQL + MinIO
# ---------------------------------------------------------------------------

engine = create_async_engine(DATABASE_URL, echo=False)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=False,
)


def ts_to_dt(val) -> datetime | None:
    """Convert Firestore Timestamp or ISO string to Python datetime."""
    if val is None:
        return None
    if hasattr(val, "seconds"):
        # Firestore Timestamp
        return datetime.fromtimestamp(val.seconds + val.nanos / 1e9, tz=timezone.utc)
    if isinstance(val, str):
        try:
            return datetime.fromisoformat(val.replace("Z", "+00:00"))
        except ValueError:
            return None
    if isinstance(val, datetime):
        return val
    return None


def ensure_uuid(val: str) -> str:
    """If val is a valid UUID, return it; otherwise generate a deterministic UUID5."""
    try:
        uuid.UUID(val)
        return val
    except ValueError:
        return str(uuid.uuid5(uuid.NAMESPACE_URL, val))


# ---------------------------------------------------------------------------
# Migration functions
# ---------------------------------------------------------------------------


async def migrate_users(session: AsyncSession) -> dict[str, str]:
    """Migrate users collection. Returns mapping of firebase_uid → postgres_uuid."""
    print("\n[1/5] Migrating users...")
    uid_map: dict[str, str] = {}

    docs = db_firestore.collection("users").stream()
    count = 0
    for doc in docs:
        data = doc.to_dict()
        pg_id = ensure_uuid(doc.id)
        uid_map[doc.id] = pg_id

        onboarding_data = data.get("onboardingData")
        likes = data.get("likes", [])
        reading_list = data.get("readingList", [])
        saved_posts = data.get("savedPosts", [])
        favorite_posts = data.get("favoritePosts", [])
        section_bookmarks = data.get("sectionBookmarks", [])

        await session.execute(
            text("""
                INSERT INTO users (id, email, name, photo_url, onboarding_complete,
                    onboarding_data, likes, reading_list, saved_posts, favorite_posts,
                    section_bookmarks, created_at, updated_at)
                VALUES (:id, :email, :name, :photo_url, :onboarding_complete,
                    :onboarding_data::jsonb, :likes, :reading_list, :saved_posts,
                    :favorite_posts, :section_bookmarks, :created_at, :updated_at)
                ON CONFLICT (id) DO NOTHING
            """),
            {
                "id": pg_id,
                "email": data.get("email", ""),
                "name": data.get("name"),
                "photo_url": data.get("photoUrl"),
                "onboarding_complete": data.get("onboardingComplete", False),
                "onboarding_data": str(onboarding_data) if onboarding_data else None,
                "likes": likes,
                "reading_list": reading_list,
                "saved_posts": saved_posts,
                "favorite_posts": favorite_posts,
                "section_bookmarks": section_bookmarks,
                "created_at": ts_to_dt(data.get("createdAt")) or datetime.now(timezone.utc),
                "updated_at": ts_to_dt(data.get("updatedAt")) or datetime.now(timezone.utc),
            },
        )
        count += 1

    await session.commit()
    print(f"  Migrated {count} users")
    return uid_map


async def migrate_writings(session: AsyncSession, uid_map: dict[str, str]):
    """Migrate users/{uid}/writings and their sections."""
    print("\n[2/5] Migrating writings + sections...")
    writing_count = 0
    section_count = 0

    for firebase_uid, pg_uid in uid_map.items():
        writings = db_firestore.collection("users").document(firebase_uid).collection("writings").stream()

        for wdoc in writings:
            wdata = wdoc.to_dict()
            writing_id = ensure_uuid(wdoc.id)
            section_ids = wdata.get("sectionIds", [])

            await session.execute(
                text("""
                    INSERT INTO writings (id, user_id, title, author, description,
                        cover_image_path, status, writing_type, subtype, section_ids,
                        created_at, updated_at)
                    VALUES (:id, :user_id, :title, :author, :description,
                        :cover_image_path, :status, :writing_type, :subtype, :section_ids,
                        :created_at, :updated_at)
                    ON CONFLICT (id) DO NOTHING
                """),
                {
                    "id": writing_id,
                    "user_id": pg_uid,
                    "title": wdata.get("title", ""),
                    "author": wdata.get("author", ""),
                    "description": wdata.get("description", ""),
                    "cover_image_path": wdata.get("coverImagePath", ""),
                    "status": str(wdata.get("status", 0)),
                    "writing_type": str(wdata.get("writingType", 0)),
                    "subtype": wdata.get("subtype", ""),
                    "section_ids": section_ids,
                    "created_at": ts_to_dt(wdata.get("createdAt")) or datetime.now(timezone.utc),
                    "updated_at": ts_to_dt(wdata.get("updatedAt")) or datetime.now(timezone.utc),
                },
            )
            writing_count += 1

            # Sections subcollection
            sections = (
                db_firestore.collection("users")
                .document(firebase_uid)
                .collection("writings")
                .document(wdoc.id)
                .collection("sections")
                .stream()
            )
            for sdoc in sections:
                sdata = sdoc.to_dict()
                section_id = ensure_uuid(sdoc.id)

                await session.execute(
                    text("""
                        INSERT INTO sections (id, writing_id, title, content, canvas_data,
                            section_color, updated_at)
                        VALUES (:id, :writing_id, :title, :content::jsonb, :canvas_data::jsonb,
                            :section_color, :updated_at)
                        ON CONFLICT (id) DO NOTHING
                    """),
                    {
                        "id": section_id,
                        "writing_id": writing_id,
                        "title": sdata.get("title", ""),
                        "content": str(sdata.get("content")) if sdata.get("content") else None,
                        "canvas_data": str(sdata.get("canvasData")) if sdata.get("canvasData") else None,
                        "section_color": sdata.get("sectionColor"),
                        "updated_at": ts_to_dt(sdata.get("updatedAt")) or datetime.now(timezone.utc),
                    },
                )
                section_count += 1

    await session.commit()
    print(f"  Migrated {writing_count} writings, {section_count} sections")


async def migrate_feed_items(session: AsyncSession, uid_map: dict[str, str]):
    """Migrate feed_items and their comments."""
    print("\n[3/5] Migrating feed items + comments...")
    feed_count = 0
    comment_count = 0

    docs = db_firestore.collection("feed_items").stream()
    for doc in docs:
        data = doc.to_dict()
        feed_id = ensure_uuid(doc.id)
        author_id = data.get("authorId", "")
        pg_author_id = uid_map.get(author_id, ensure_uuid(author_id))

        sections_json = data.get("sections")
        import json
        sections_str = json.dumps(sections_json) if sections_json else None

        await session.execute(
            text("""
                INSERT INTO feed_items (id, title, author, author_id, description,
                    image_url, genres, writing_types, tags, likes_count, comments_count,
                    is_draft, sections, created_at, updated_at)
                VALUES (:id, :title, :author, :author_id, :description,
                    :image_url, :genres, :writing_types, :tags, :likes_count, :comments_count,
                    :is_draft, :sections::jsonb, :created_at, :updated_at)
                ON CONFLICT (id) DO NOTHING
            """),
            {
                "id": feed_id,
                "title": data.get("title", ""),
                "author": data.get("author", ""),
                "author_id": pg_author_id,
                "description": data.get("description", ""),
                "image_url": data.get("imageUrl"),
                "genres": data.get("genres", []),
                "writing_types": data.get("writingTypes", []),
                "tags": data.get("tags", []),
                "likes_count": data.get("likesCount", 0),
                "comments_count": data.get("commentsCount", 0),
                "is_draft": data.get("isDraft", False),
                "sections": sections_str,
                "created_at": ts_to_dt(data.get("createdAt")) or datetime.now(timezone.utc),
                "updated_at": ts_to_dt(data.get("updatedAt")) or datetime.now(timezone.utc),
            },
        )
        feed_count += 1

        # Comments subcollection
        comments = (
            db_firestore.collection("feed_items")
            .document(doc.id)
            .collection("comments")
            .stream()
        )
        for cdoc in comments:
            cdata = cdoc.to_dict()
            comment_id = ensure_uuid(cdoc.id)
            c_author_id = cdata.get("authorId", "")
            pg_c_author_id = uid_map.get(c_author_id, ensure_uuid(c_author_id))

            await session.execute(
                text("""
                    INSERT INTO comments (id, feed_item_id, author_id, author_name,
                        author_photo_url, text, rating, created_at)
                    VALUES (:id, :feed_item_id, :author_id, :author_name,
                        :author_photo_url, :text, :rating, :created_at)
                    ON CONFLICT (id) DO NOTHING
                """),
                {
                    "id": comment_id,
                    "feed_item_id": feed_id,
                    "author_id": pg_c_author_id,
                    "author_name": cdata.get("authorName"),
                    "author_photo_url": cdata.get("authorPhotoUrl"),
                    "text": cdata.get("text", ""),
                    "rating": cdata.get("rating"),
                    "created_at": ts_to_dt(cdata.get("createdAt")) or datetime.now(timezone.utc),
                },
            )
            comment_count += 1

    await session.commit()
    print(f"  Migrated {feed_count} feed items, {comment_count} comments")


async def migrate_user_data(session: AsyncSession, uid_map: dict[str, str]):
    """Migrate reading_progress, highlights, bookshelves for each user."""
    print("\n[4/5] Migrating reading progress, highlights, bookshelves...")
    rp_count = hl_count = bs_count = 0

    for firebase_uid, pg_uid in uid_map.items():
        user_ref = db_firestore.collection("users").document(firebase_uid)

        # Reading progress
        for doc in user_ref.collection("reading_progress").stream():
            data = doc.to_dict()
            rp_id = str(uuid.uuid4())
            feed_item_id = ensure_uuid(data.get("feedItemId", doc.id))

            await session.execute(
                text("""
                    INSERT INTO reading_progress (id, user_id, feed_item_id,
                        scroll_position, last_read_at, completed)
                    VALUES (:id, :user_id, :feed_item_id,
                        :scroll_position, :last_read_at, :completed)
                    ON CONFLICT ON CONSTRAINT uq_user_feed_item DO NOTHING
                """),
                {
                    "id": rp_id,
                    "user_id": pg_uid,
                    "feed_item_id": feed_item_id,
                    "scroll_position": data.get("scrollPosition"),
                    "last_read_at": ts_to_dt(data.get("lastReadAt")),
                    "completed": data.get("completed", False),
                },
            )
            rp_count += 1

        # Highlights
        for doc in user_ref.collection("highlights").stream():
            data = doc.to_dict()
            hl_id = ensure_uuid(doc.id)
            feed_item_id = ensure_uuid(data.get("feedItemId", ""))

            await session.execute(
                text("""
                    INSERT INTO highlights (id, user_id, feed_item_id, section_index,
                        start, length, color_hex, created_at)
                    VALUES (:id, :user_id, :feed_item_id, :section_index,
                        :start, :length, :color_hex, :created_at)
                    ON CONFLICT (id) DO NOTHING
                """),
                {
                    "id": hl_id,
                    "user_id": pg_uid,
                    "feed_item_id": feed_item_id,
                    "section_index": data.get("sectionIndex", 0),
                    "start": data.get("start", 0),
                    "length": data.get("length", 0),
                    "color_hex": data.get("colorHex", "#FFFF00"),
                    "created_at": ts_to_dt(data.get("createdAt")) or datetime.now(timezone.utc),
                },
            )
            hl_count += 1

        # Bookshelves
        for doc in user_ref.collection("bookshelves").stream():
            data = doc.to_dict()
            bs_id = ensure_uuid(doc.id)

            await session.execute(
                text("""
                    INSERT INTO bookshelves (id, user_id, name, description, is_private,
                        item_ids, cover_image_url, created_at, updated_at)
                    VALUES (:id, :user_id, :name, :description, :is_private,
                        :item_ids, :cover_image_url, :created_at, :updated_at)
                    ON CONFLICT (id) DO NOTHING
                """),
                {
                    "id": bs_id,
                    "user_id": pg_uid,
                    "name": data.get("name", ""),
                    "description": data.get("description"),
                    "is_private": data.get("isPrivate", True),
                    "item_ids": data.get("itemIds", []),
                    "cover_image_url": data.get("coverImageUrl"),
                    "created_at": ts_to_dt(data.get("createdAt")) or datetime.now(timezone.utc),
                    "updated_at": ts_to_dt(data.get("updatedAt")) or datetime.now(timezone.utc),
                },
            )
            bs_count += 1

    await session.commit()
    print(f"  Migrated {rp_count} reading progress, {hl_count} highlights, {bs_count} bookshelves")


async def migrate_storage():
    """Copy files from Firebase Storage to MinIO."""
    print("\n[5/5] Migrating storage files...")

    # Ensure bucket exists
    exists = await minio_client.bucket_exists(MINIO_BUCKET)
    if not exists:
        await minio_client.make_bucket(MINIO_BUCKET)

    blobs = bucket.list_blobs(prefix="users/")
    count = 0
    for blob in blobs:
        if blob.size == 0:
            continue
        data = blob.download_as_bytes()
        content_type = blob.content_type or "application/octet-stream"
        path = blob.name

        await minio_client.put_object(
            MINIO_BUCKET,
            path,
            BytesIO(data),
            length=len(data),
            content_type=content_type,
        )
        count += 1
        if count % 10 == 0:
            print(f"  Copied {count} files...")

    print(f"  Migrated {count} storage files")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


async def main():
    print("=" * 60)
    print("Firebase → Self-Hosted Migration")
    print("=" * 60)

    # Create tables
    async with engine.begin() as conn:
        # Import models to register them with metadata
        from app.models import Base

        await conn.run_sync(Base.metadata.create_all)
    print("Database tables created.")

    async with async_session() as session:
        uid_map = await migrate_users(session)
        await migrate_writings(session, uid_map)
        await migrate_feed_items(session, uid_map)
        await migrate_user_data(session, uid_map)

    await migrate_storage()

    print("\n" + "=" * 60)
    print("Migration complete!")
    print("=" * 60)


if __name__ == "__main__":
    asyncio.run(main())
