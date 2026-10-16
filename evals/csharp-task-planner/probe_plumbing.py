"""Check that a follow-up message in a multi-turn request actually reaches each model.

The repair round sends [task, the model's own reply, compiler feedback]. If a
server dropped or ignored the later messages, every "repair" would just be the
first answer again, and the comparison would be measuring plumbing. This sends the
same three-message shape with a last message that cannot be mistaken for the task,
and checks the reply obeys it.
"""

import json
import sys
import urllib.request

import generate as g
import repair as r

MARKER = "PLUMBING-OK"
LAST = f"Ignore all the code above. Reply with exactly the single word {MARKER} and nothing else."
SHORT_PROMPT = "Write a one-line C# statement that prints hello."
messages = [
    {"role": "user", "content": SHORT_PROMPT},
    {"role": "assistant", "content": '```csharp\nConsole.WriteLine("hello");\n```'},
    {"role": "user", "content": LAST},
]


def main() -> int:
    ok = True
    reply, _ = r.chat("7b", messages, 1)
    print(f"7B  (Foundry HTTP): {reply.strip()[:80]!r}  -> {'reaches the model' if MARKER in reply else 'IGNORED'}")
    ok &= MARKER in reply

    server = r.start_server()
    try:
        reply, _ = r.chat("30b", messages, 1)
    finally:
        r.stop_server(server)
    print(f"30B (geniex serve): {reply.strip()[:80]!r}  -> {'reaches the model' if MARKER in reply else 'IGNORED'}")
    ok &= MARKER in reply
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
