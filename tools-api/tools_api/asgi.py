"""Production ASGI entry point; environment variables are read only here."""

from .main import create_app


app = create_app()

