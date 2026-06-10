import os
import random
import time

from fastapi import FastAPI
from langfuse import Langfuse

app = FastAPI()

langfuse = Langfuse(
    public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
    secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    host=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
)

@app.get("/")
def root():
    return {"message": "AI Platform OTel + Langfuse Demo"}

@app.get("/chat")
def chat(q: str = "What is Kubernetes?"):
    start = time.time()

    # Simulate LLM latency
    time.sleep(random.uniform(0.2, 0.8))

    answer = f"Simulated LLM answer for: {q}"
    latency_ms = round((time.time() - start) * 1000, 2)

    trace = langfuse.trace(
        name="chat-request",
        input={"question": q},
        metadata={
            "service": "ai-platform-demo",
            "latency_ms": latency_ms
        }
    )

    generation = trace.generation(
        name="demo-llm",
        input=q,
        output=answer,
        metadata={
            "model": "demo-llm",
            "environment": "lab"
        }
    )

    generation.end()

    langfuse.flush()

    return {
        "question": q,
        "answer": answer,
        "latency_ms": latency_ms
    }
