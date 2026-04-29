"""Local-only debug UI for the book-ingest pipeline.

Run:

    cd backend/test_model
    uvicorn studio.server:app --reload --port 8765

then open http://localhost:8765/.

Don't deploy this. It exposes the local filesystem and runs LLM-spending
work on every upload — strictly a development tool.
"""
