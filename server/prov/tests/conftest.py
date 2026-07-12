import sys
from pathlib import Path

# Put <repo>/server on the path so `import prov.<module>` resolves when pytest
# is run from anywhere in the repo.
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
