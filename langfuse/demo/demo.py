import os

from langfuse import Langfuse

langfuse = Langfuse(
    public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
    secret_key=os.environ["LANGFUSE_SECRET_KEY"],
    host=os.environ.get("LANGFUSE_HOST", "http://localhost:3000"),
)

trace = langfuse.trace(name="chat-demo")

generation = trace.generation(name="gpt4")
generation.end(
    input="Explain Kubernetes",
    output="Kubernetes is a container orchestration platform.",
)

langfuse.flush()

print("Done")
