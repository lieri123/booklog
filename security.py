"""Password hashing, JWT issue/verify, and the auth dependency."""

from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

import config

_hasher = PasswordHasher()

UNAUTHORIZED = HTTPException(
    401, "Not authenticated", headers={"WWW-Authenticate": "Bearer"}
)


def hash_password(plain: str) -> str:
    return _hasher.hash(plain)


def verify_password(plain: str, hashed: str) -> bool:
    """Returns False rather than raising, so callers can't leak which failure
    mode occurred through differing error responses."""
    try:
        _hasher.verify(hashed, plain)
        return True
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def create_access_token(user_id: int) -> str:
    now = datetime.now(timezone.utc)
    return jwt.encode(
        {
            "sub": str(user_id),
            "iat": now,
            "exp": now + timedelta(minutes=config.JWT_EXPIRE_MINUTES),
        },
        config.JWT_SECRET,
        algorithm=config.JWT_ALGORITHM,
    )


def decode_access_token(token: str) -> int | None:
    """Expiry, bad signature, and malformed tokens all collapse to None on
    purpose - the caller returns an identical 401 for each, so an attacker
    learns nothing from the difference."""
    try:
        payload = jwt.decode(
            token, config.JWT_SECRET, algorithms=[config.JWT_ALGORITHM]
        )
        sub = payload.get("sub")
        return int(sub) if sub is not None else None
    except (jwt.PyJWTError, ValueError, TypeError):
        return None


_bearer = HTTPBearer(auto_error=False)


async def current_user_id(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> int:
    if creds is None or not creds.credentials:
        raise UNAUTHORIZED
    uid = decode_access_token(creds.credentials)
    if uid is None:
        raise UNAUTHORIZED
    return uid
