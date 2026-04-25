import httpx
from google.auth.transport import requests as google_requests
from google.oauth2 import id_token

from app.config import settings


async def verify_google_id_token(token: str) -> dict | None:
    """Verify a Google ID token and return the user info payload."""
    try:
        idinfo = id_token.verify_oauth2_token(
            token,
            google_requests.Request(),
            settings.google_client_id,
        )

        if idinfo["iss"] not in ("accounts.google.com", "https://accounts.google.com"):
            return None

        return {
            "email": idinfo["email"],
            "name": idinfo.get("name"),
            "photo_url": idinfo.get("picture"),
        }
    except ValueError:
        return None
