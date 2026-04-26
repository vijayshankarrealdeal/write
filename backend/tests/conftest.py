"""Shared pytest fixtures.

The app's `Settings` model requires JWT + admin creds at import time. Tests
don't talk to the network, but they import `app.config` transitively (via
models), so we satisfy the schema with placeholders before any test
collects.
"""
import os

os.environ.setdefault(
    "JWT_SECRET",
    "test-secret-not-for-production-padded-to-meet-32-char-min-length",
)
os.environ.setdefault("ADMIN_USERNAME", "test-admin")
os.environ.setdefault("ADMIN_PASSWORD", "test-admin-password")
