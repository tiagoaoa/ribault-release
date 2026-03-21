# tests/test_graphs.py
import subprocess
import pathlib
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]       # diretório do repo
TEST_DIR   = ROOT / "test"
GOLDEN_AST = TEST_DIR / "golden-ast"
GOLDEN_DF  = TEST_DIR / "golden-df"
GOLDEN_TALM = TEST_DIR / "golden-talm"   # <- novos goldens do assembly

AST_EXE    = ROOT / "analysis-ast"   # bin gerado pela MainAST.hs
DF_EXE     = ROOT / "analysis"       # bin gerado pela Main.hs (GraphGen)
ASM_EXE    = ROOT / "codegen"        # bin gerado pelo Codegen (FlowASM)

# ----------------------------------------------------------------------
# UTIL
# ----------------------------------------------------------------------
def run_compiler(exe: pathlib.Path, src: pathlib.Path) -> str:
    """Roda o compilador e devolve a saída textual (DOT/ASM) em stdout."""
    return subprocess.check_output([exe, src], text=True)

def ensure_dir(d: pathlib.Path):
    d.mkdir(parents=True, exist_ok=True)

# ----------------------------------------------------------------------
# BUSCA todos os arquivos .hsk do diretório de teste
# ----------------------------------------------------------------------
hsk_files = sorted(TEST_DIR.glob("*.hsk"))

@pytest.mark.parametrize("hsk_path", hsk_files, ids=lambda p: p.stem)
def test_ast_dot(hsk_path: pathlib.Path):
    """AST .dot deve coincidir com o golden."""
    ensure_dir(GOLDEN_AST)
    gold = GOLDEN_AST / f"{hsk_path.stem}.dot"

    generated = run_compiler(AST_EXE, hsk_path)
    if not gold.exists():  # primeira vez: grava golden
        gold.write_text(generated)
        pytest.skip(f"golden criado: {gold.relative_to(ROOT)}")
    else:
        assert generated == gold.read_text()

@pytest.mark.parametrize("hsk_path", hsk_files, ids=lambda p: p.stem)
def test_dataflow_dot(hsk_path: pathlib.Path):
    """Data-flow .dot deve coincidir com o golden."""
    ensure_dir(GOLDEN_DF)
    gold = GOLDEN_DF / f"{hsk_path.stem}.dot"

    generated = run_compiler(DF_EXE, hsk_path)
    if not gold.exists():  # primeira vez: grava golden
        gold.write_text(generated)
        pytest.skip(f"golden criado: {gold.relative_to(ROOT)}")
    else:
        assert generated == gold.read_text()

@pytest.mark.parametrize("hsk_path", hsk_files, ids=lambda p: p.stem)
def test_talm_assembly(hsk_path: pathlib.Path):
    """FlowASM (.fl) textual deve coincidir com o golden."""
    ensure_dir(GOLDEN_TALM)
    gold = GOLDEN_TALM / f"{hsk_path.stem}.fl"

    generated = run_compiler(ASM_EXE, hsk_path)
    if not gold.exists():  # primeira vez: grava golden
        gold.write_text(generated)
        pytest.skip(f"golden criado: {gold.relative_to(ROOT)}")
    else:
        assert generated == gold.read_text()
