"""
Admin web interface — login, API key management, log viewer.

Routes:
  GET  /admin/login              → login page
  POST /admin/login              → authenticate admin
  GET  /admin/logout             → clear session, redirect to login
  GET  /admin/keys               → API key dashboard
  POST /admin/keys/create        → generate + store a new key
  POST /admin/keys/{id}/toggle   → activate / deactivate
  POST /admin/keys/{id}/delete   → hard-delete
  GET  /admin/logs               → paginated log viewer with filters

Admin credentials are read from env vars ADMIN_USERNAME / ADMIN_PASSWORD.
Sessions are secured with SESSION_SECRET via Starlette's SessionMiddleware.
"""

import os
import secrets
import datetime

from fastapi import APIRouter, Depends, Form, Request, Query
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session
from sqlalchemy import func
import math
from typing import Optional

from database import get_db
import models

router = APIRouter(prefix="/admin")
templates = Jinja2Templates(directory="templates")

_ADMIN_USER = os.environ.get("ADMIN_USERNAME", "admin")
_ADMIN_PASS = os.environ.get("ADMIN_PASSWORD", "changeme")


# ── Helpers ────────────────────────────────────────────────────────────────────

def _require_admin(request: Request):
    """Redirect to login if the admin session is not set."""
    if not request.session.get("admin_logged_in"):
        return RedirectResponse("/admin/login", status_code=303)
    return None


def _flash(request: Request, message: str, kind: str = "info"):
    request.session["flash"] = {"message": message, "type": kind}


def _pop_flash(request: Request):
    return request.session.pop("flash", None)


# ── Login / Logout ─────────────────────────────────────────────────────────────

@router.get("/login", response_class=HTMLResponse)
async def login_page(request: Request):
    if request.session.get("admin_logged_in"):
        return RedirectResponse("/admin/keys", status_code=303)
    return templates.TemplateResponse(
        request, "login.html", {"error": None}
    )


@router.post("/login", response_class=HTMLResponse)
async def login_submit(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
):
    if username == _ADMIN_USER and password == _ADMIN_PASS:
        request.session["admin_logged_in"] = True
        return RedirectResponse("/admin/keys", status_code=303)

    return templates.TemplateResponse(
        request,
        "login.html",
        {"error": "Invalid username or password."},
        status_code=401,
    )


@router.get("/logout")
async def logout(request: Request):
    request.session.clear()
    return RedirectResponse("/admin/login", status_code=303)


# ── API Key dashboard ──────────────────────────────────────────────────────────

@router.get("/keys", response_class=HTMLResponse)
async def keys_page(request: Request, db: Session = Depends(get_db)):
    redir = _require_admin(request)
    if redir:
        return redir

    keys = db.query(models.APIKey).order_by(models.APIKey.id.desc()).all()
    new_key = request.session.pop("new_key", None)
    flash = _pop_flash(request)

    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {
            "keys": keys,
            "new_key": new_key,
            "flash": flash,
        },
    )


@router.post("/keys/create")
async def keys_create(
    request: Request,
    name: str = Form(...),
    db: Session = Depends(get_db),
):
    redir = _require_admin(request)
    if redir:
        return redir

    # Generate a secure random key
    raw_key = secrets.token_urlsafe(32)

    db_key = models.APIKey(
        name=name.strip(),
        key=raw_key,
        is_active=True,
        created_at=datetime.datetime.utcnow(),
    )
    db.add(db_key)
    db.commit()

    # Store in session — shown ONCE on redirect, then cleared
    request.session["new_key"] = raw_key
    return RedirectResponse("/admin/keys", status_code=303)


@router.post("/keys/{key_id}/toggle")
async def keys_toggle(
    request: Request,
    key_id: int,
    db: Session = Depends(get_db),
):
    redir = _require_admin(request)
    if redir:
        return redir

    db_key = db.query(models.APIKey).filter(models.APIKey.id == key_id).first()
    if db_key:
        db_key.is_active = not db_key.is_active
        db.commit()
        status = "activated" if db_key.is_active else "deactivated"
        _flash(request, f"Key «{db_key.name}» {status}.", "success")

    return RedirectResponse("/admin/keys", status_code=303)


@router.post("/keys/{key_id}/delete")
async def keys_delete(
    request: Request,
    key_id: int,
    db: Session = Depends(get_db),
):
    redir = _require_admin(request)
    if redir:
        return redir

    db_key = db.query(models.APIKey).filter(models.APIKey.id == key_id).first()
    if db_key:
        name = db_key.name
        db.delete(db_key)
        db.commit()
        _flash(request, f"Key «{name}» deleted.", "error")

    return RedirectResponse("/admin/keys", status_code=303)


# ── Logs viewer ────────────────────────────────────────────────────────────────

_PAGE_SIZE = 50


@router.get("/logs", response_class=HTMLResponse)
async def logs_page(
    request: Request,
    db: Session = Depends(get_db),
    page: int = Query(1, ge=1),
    method: Optional[str] = Query(None),
    execution_mode: Optional[str] = Query(None),
    device_id: Optional[str] = Query(None),
    from_date: Optional[str] = Query(None),
    to_date: Optional[str] = Query(None),
):
    redir = _require_admin(request)
    if redir:
        return redir

    # ── Build filtered query ──────────────────────────────────────────────
    q = db.query(models.APILog)

    if method:
        q = q.filter(models.APILog.method == method)
    if execution_mode:
        q = q.filter(models.APILog.execution_mode == execution_mode)
    if device_id:
        q = q.filter(models.APILog.device_id.like(f"{device_id}%"))
    if from_date:
        try:
            dt_from = datetime.datetime.strptime(from_date, "%Y-%m-%d")
            q = q.filter(models.APILog.timestamp >= dt_from)
        except ValueError:
            pass
    if to_date:
        try:
            dt_to = datetime.datetime.strptime(to_date, "%Y-%m-%d") + datetime.timedelta(days=1)
            q = q.filter(models.APILog.timestamp < dt_to)
        except ValueError:
            pass

    total = q.count()
    total_pages = max(1, math.ceil(total / _PAGE_SIZE))
    page = min(page, total_pages)
    offset = (page - 1) * _PAGE_SIZE

    logs = q.order_by(models.APILog.timestamp.desc()).offset(offset).limit(_PAGE_SIZE).all()

    # ── Summary counts (unfiltered, for stat cards) ───────────────────────
    all_logs_q = db.query(models.APILog)
    edge_count   = all_logs_q.filter(models.APILog.execution_mode == "edge").count()
    server_count = all_logs_q.filter(models.APILog.execution_mode == "server").count()
    device_count = db.query(func.count(func.distinct(models.APILog.device_id))).scalar() or 0
    grand_total  = all_logs_q.count()

    # ── Build pagination URL helper (preserves current filters) ──────────
    def pagination_url(p: int) -> str:
        params = request.query_params._dict.copy()
        params["page"] = str(p)
        qs = "&".join(f"{k}={v}" for k, v in params.items())
        return f"/admin/logs?{qs}"

    return templates.TemplateResponse(
        request,
        "logs.html",
        {
            "logs": logs,
            "total": grand_total,
            "edge_count": edge_count,
            "server_count": server_count,
            "device_count": device_count,
            "page": page,
            "total_pages": total_pages,
            "filters": {
                "method": method or "",
                "execution_mode": execution_mode or "",
                "device_id": device_id or "",
                "from_date": from_date or "",
                "to_date": to_date or "",
            },
            "pagination_url": pagination_url,
        },
    )
