"""Acquire one photographer-published RAW fixture for Apple decoder verification."""
from pathlib import Path
import hashlib,urllib.request

target=Path(__file__).resolve().parents[1]/'HassyNaturalTests/Fixtures/Public17Pro.dng'
target.parent.mkdir(parents=True,exist_ok=True)
source='https://drive.usercontent.google.com/download?id=1kjgznTM6BTnkBLQ3e5It2gYF8RyBQhrO&export=download&authuser=0'
expected='3a536b32798c2fc34a07529722c23b30b5a2d1c86a63ef92c2fed52e4756e5d6'
if not target.exists():
 with urllib.request.urlopen(source,timeout=90) as response:target.write_bytes(response.read(30*1024*1024))
assert hashlib.sha256(target.read_bytes()).hexdigest()==expected,'Public RAW fixture identity mismatch'
print('Verified Alex Armitage public iPhone 17 Pro DNG; Lightroom-rewritten, exact source identity pinned')
