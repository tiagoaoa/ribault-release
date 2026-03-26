# ──────────────────────────────────────────────────────────────
# Ribault + TALM — Top-level Makefile
# ──────────────────────────────────────────────────────────────
#
# Workflow:
#   ./configure          # check dependencies, generate config.mk
#   make                 # build compiler + Trebuchet interpreter
#   make test            # correctness tests (compile-only)
#   make test-execute    # correctness tests + Trebuchet execution
#   make bench           # performance benchmarks
#   sudo make install    # install to PREFIX
#

# ── Include configure output (if present) ────────────────────
-include config.mk

# ── Defaults (if ./configure was not run) ────────────────────
GHC          ?= ghc
ALEX         ?= alex
HAPPY        ?= happy
DOT          ?= dot
GCC          ?= gcc
CC           ?= $(GCC)
PYTHON3      ?= python3
PREFIX       ?= /usr/local
TALM_DIR     ?= ./TALM
SUPERS_RTS_A ?= 256m

BINDIR       := $(PREFIX)/bin
LIBDIR       := $(PREFIX)/lib/ribault
DATADIR      := $(PREFIX)/share/ribault

SHELL        := /bin/bash

# ── Warn if not configured ───────────────────────────────────
ifndef CONFIGURED
$(warning *** ./configure has not been run — using defaults. Run ./configure first.)
endif

# ════════════════════════════════════════════════════════════════
# Source layout
# ════════════════════════════════════════════════════════════════
SRC_DIR      := src
TEST_DIR     := test

# Generated outputs
DF_OUT_DIR   := $(TEST_DIR)/df-output
DF_IMG_DIR   := $(TEST_DIR)/df-images
AST_OUT_DIR  := $(TEST_DIR)/ast-output
AST_IMG_DIR  := $(TEST_DIR)/ast-images
CODE_OUT_DIR := $(TEST_DIR)/talm

# ── Ribault compiler sources ─────────────────────────────────
LEXER_SRC    := $(SRC_DIR)/Analysis/Lexer.x
PARSER_SRC   := $(SRC_DIR)/Analysis/Parser.y
LEXER_HS     := $(SRC_DIR)/Analysis/Lexer.hs
PARSER_HS    := $(SRC_DIR)/Analysis/Parser.hs
SYNTAX_HS    := $(SRC_DIR)/Analysis/Syntax.hs
SEMANTIC_HS  := $(SRC_DIR)/Analysis/Semantic.hs
ASTGEN_HS    := $(SRC_DIR)/Analysis/AST-gen.hs

BUILDER_HS   := $(SRC_DIR)/Synthesis/Builder.hs
GRAPHVIZ_HS  := $(SRC_DIR)/Synthesis/GraphViz.hs
CODEGEN_HS   := $(SRC_DIR)/Synthesis/Codegen.hs
UNIQUE_HS    := $(SRC_DIR)/Synthesis/Unique.hs
TYPES_HS     := $(SRC_DIR)/Synthesis/Types.hs
PORT_HS      := $(SRC_DIR)/Synthesis/Port.hs
NODE_HS      := $(SRC_DIR)/Synthesis/Node.hs

MAIN_CODE_HS := $(SRC_DIR)/Synthesis/MainCode.hs
MAIN_DF_HS   := $(SRC_DIR)/Synthesis/MainGraph.hs
MAIN_AST_HS  := $(SRC_DIR)/Analysis/MainAST.hs

MAIN_SUPERS_HS := $(SRC_DIR)/Synthesis/MainSupers.hs
SUPERS_EXTRACT := $(SRC_DIR)/Synthesis/SuperExtract.hs
SUPERS_EMIT    := $(SRC_DIR)/Synthesis/SupersEmit.hs
SUPERS_DIR     := $(TEST_DIR)/supers

# ── Executables ──────────────────────────────────────────────
EXE_AST      := analysis
EXE_DF       := synthesis
EXE_CODE     := codegen
EXE_SUPERS   := supersgen
EXE_RIBAULT  := ribault-bin

MAIN_RIBAULT_HS := $(SRC_DIR)/Synthesis/MainRibault.hs

# GHC flags
GHC_PKGS     := -package mtl -package array -package containers -package text
GHC_FLAGS    := -O2 $(GHC_PKGS)

# ── Test programs ────────────────────────────────────────────
TESTS        := $(wildcard $(TEST_DIR)/*.hss)

DF_DOTS      := $(patsubst $(TEST_DIR)/%.hss,$(DF_OUT_DIR)/%.dot,$(TESTS))
DF_IMGS      := $(patsubst $(DF_OUT_DIR)/%.dot,$(DF_IMG_DIR)/%.png,$(DF_DOTS))
AST_DOTS     := $(patsubst $(TEST_DIR)/%.hss,$(AST_OUT_DIR)/%.dot,$(TESTS))
AST_IMGS     := $(patsubst $(AST_OUT_DIR)/%.dot,$(AST_IMG_DIR)/%.png,$(AST_DOTS))
CODE_FL      := $(patsubst $(TEST_DIR)/%.hss,$(CODE_OUT_DIR)/%.fl,$(TESTS))

# ── Supers config ────────────────────────────────────────────
GHC_VER             ?= $(shell $(GHC) --numeric-version 2>/dev/null)
GHC_MAJOR           := $(shell echo $(GHC_VER) | cut -d. -f1)
SHIM_DIR            := build/ghc-shim
SUPERS_THREADED     ?= 1
SUPERS_WRAPPERS_MAX ?= 256

# ════════════════════════════════════════════════════════════════
# HIGH-LEVEL TARGETS
# ════════════════════════════════════════════════════════════════
.PHONY: all compiler interp test test-execute bench \
        df ast code supers install uninstall dist clean help

all: compiler interp

compiler: $(EXE_AST) $(EXE_DF) $(EXE_CODE) $(EXE_SUPERS) $(EXE_RIBAULT)
	@echo ""
	@echo "Ribault compiler built: $(EXE_AST) $(EXE_DF) $(EXE_CODE) $(EXE_SUPERS) $(EXE_RIBAULT)"

help:
	@echo "Ribault + TALM build system"
	@echo ""
	@echo "  ./configure        Check dependencies and generate config.mk"
	@echo ""
	@echo "  make               Build compiler + Trebuchet interpreter"
	@echo "  make compiler      Build Ribault compiler only"
	@echo "  make interp        Build Trebuchet interpreter only"
	@echo "  make test          Correctness tests (compile all test/*.hss)"
	@echo "  make test-execute  Correctness tests + execute on Trebuchet"
	@echo "  make supers        Build super-instruction libraries for tests"
	@echo "  make df            Generate dataflow .dot + .png for tests"
	@echo "  make ast           Generate AST .dot + .png for tests"
	@echo "  make code          Generate TALM .fl for tests"
	@echo "  make bench         Run performance benchmarks"
	@echo "  make install       Install to PREFIX (default /usr/local)"
	@echo "  make uninstall     Remove installed files"
	@echo "  make dist          Create source tarball"
	@echo "  make clean         Remove all build artifacts"

# ════════════════════════════════════════════════════════════════
# TREBUCHET INTERPRETER
# ════════════════════════════════════════════════════════════════
interp:
	@if [ -x "$(TALM_DIR)/interp/interp" ]; then \
		echo "Trebuchet interpreter already built."; \
	elif [ -f "$(TALM_DIR)/interp/Makefile" ]; then \
		echo "[MAKE] Building Trebuchet interpreter..."; \
		$(MAKE) -C "$(TALM_DIR)/interp"; \
	else \
		echo "ERROR: $(TALM_DIR)/interp/Makefile not found"; \
		exit 1; \
	fi

# ════════════════════════════════════════════════════════════════
# LEXER / PARSER GENERATION
# ════════════════════════════════════════════════════════════════
$(LEXER_HS): $(LEXER_SRC)
	@echo "[ALEX ] $<"
	$(ALEX) $<

$(PARSER_HS): $(PARSER_SRC)
	@echo "[HAPPY] $<"
	$(HAPPY) --ghc -o $@ $<

# ════════════════════════════════════════════════════════════════
# COMPILER EXECUTABLES
# ════════════════════════════════════════════════════════════════
$(EXE_AST): $(LEXER_HS) $(PARSER_HS) $(SYNTAX_HS) $(SEMANTIC_HS) \
            $(ASTGEN_HS) $(MAIN_AST_HS)
	@echo "[GHC  ] $@"
	@mkdir -p $(EXE_AST).obj $(EXE_AST).hi
	$(GHC) $(GHC_FLAGS) \
	  -odir $(EXE_AST).obj -hidir $(EXE_AST).hi \
	  -o $@ \
	  $(MAIN_AST_HS) $(LEXER_HS) $(PARSER_HS) \
	  $(SYNTAX_HS) $(SEMANTIC_HS) $(ASTGEN_HS)

$(EXE_DF): $(LEXER_HS) $(PARSER_HS) $(SYNTAX_HS) $(SEMANTIC_HS) \
           $(BUILDER_HS) $(GRAPHVIZ_HS) $(MAIN_DF_HS) $(UNIQUE_HS) \
           $(TYPES_HS) $(PORT_HS) $(NODE_HS)
	@echo "[GHC  ] $@"
	@mkdir -p $(EXE_DF).obj $(EXE_DF).hi
	$(GHC) $(GHC_FLAGS) \
	  -odir $(EXE_DF).obj -hidir $(EXE_DF).hi \
	  -o $@ \
	  $(MAIN_DF_HS) $(LEXER_HS) $(PARSER_HS) \
	  $(SYNTAX_HS) $(SEMANTIC_HS) $(UNIQUE_HS) \
	  $(TYPES_HS) $(PORT_HS) $(NODE_HS) \
	  $(BUILDER_HS) $(GRAPHVIZ_HS)

$(EXE_CODE): $(LEXER_HS) $(PARSER_HS) $(SYNTAX_HS) $(SEMANTIC_HS) \
             $(BUILDER_HS) $(CODEGEN_HS) $(MAIN_CODE_HS) $(UNIQUE_HS) \
             $(TYPES_HS) $(PORT_HS) $(NODE_HS)
	@echo "[GHC  ] $@"
	@mkdir -p $(EXE_CODE).obj $(EXE_CODE).hi
	$(GHC) $(GHC_FLAGS) \
	  -odir $(EXE_CODE).obj -hidir $(EXE_CODE).hi \
	  -o $@ \
	  $(MAIN_CODE_HS) $(LEXER_HS) $(PARSER_HS) \
	  $(SYNTAX_HS) $(SEMANTIC_HS) \
	  $(BUILDER_HS) $(CODEGEN_HS) $(UNIQUE_HS) \
	  $(TYPES_HS) $(PORT_HS) $(NODE_HS)

$(EXE_SUPERS): $(LEXER_HS) $(PARSER_HS) $(SYNTAX_HS) $(SEMANTIC_HS) \
               $(UNIQUE_HS) $(TYPES_HS) $(PORT_HS) $(NODE_HS) \
               $(SUPERS_EXTRACT) $(SUPERS_EMIT) $(MAIN_SUPERS_HS)
	@echo "[GHC  ] $@"
	@mkdir -p $(EXE_SUPERS).obj $(EXE_SUPERS).hi
	GHC_ENVIRONMENT=- $(GHC) $(GHC_FLAGS) \
	  -odir $(EXE_SUPERS).obj -hidir $(EXE_SUPERS).hi \
	  -o $@ \
	  $(MAIN_SUPERS_HS) $(LEXER_HS) $(PARSER_HS) \
	  $(SYNTAX_HS) $(SEMANTIC_HS) $(UNIQUE_HS) \
	  $(TYPES_HS) $(PORT_HS) $(NODE_HS) \
	  $(SUPERS_EXTRACT) $(SUPERS_EMIT)
	@chmod +x $@

$(EXE_RIBAULT): $(LEXER_HS) $(PARSER_HS) $(SYNTAX_HS) $(SEMANTIC_HS) \
                $(BUILDER_HS) $(CODEGEN_HS) $(UNIQUE_HS) \
                $(TYPES_HS) $(PORT_HS) $(NODE_HS) \
                $(MAIN_RIBAULT_HS)
	@echo "[GHC  ] $@"
	@mkdir -p $(EXE_RIBAULT).obj $(EXE_RIBAULT).hi
	$(GHC) $(GHC_FLAGS) -package process -package directory -package filepath -package text \
	  -odir $(EXE_RIBAULT).obj -hidir $(EXE_RIBAULT).hi \
	  -o $@ \
	  $(MAIN_RIBAULT_HS) $(LEXER_HS) $(PARSER_HS) \
	  $(SYNTAX_HS) $(SEMANTIC_HS) \
	  $(BUILDER_HS) $(CODEGEN_HS) $(UNIQUE_HS) \
	  $(TYPES_HS) $(PORT_HS) $(NODE_HS)

# ════════════════════════════════════════════════════════════════
# SUPERS (GHC shim + libsupers.so for test programs)
# ════════════════════════════════════════════════════════════════
.PHONY: supers_prepare supers

supers_prepare:
	@set -eu; \
	echo "[shim] Preparing GHC shim in $(SHIM_DIR)"; \
	mkdir -p "$(SHIM_DIR)/rts"; \
	RTS_DIR="$$($(GHC_PKG) field rts library-dirs --simple-output 2>/dev/null || echo '$(RTS_LIBDIR)')"; \
	BASE_DIR="$$(dirname "$$RTS_DIR")"; \
	RTS_SO="$$(ls "$$BASE_DIR"/libHSrts*thr*ghc$(GHC_VER).so 2>/dev/null | grep -v '_debug' | head -n1 || true)"; \
	[ -z "$$RTS_SO" ] && RTS_SO="$$(ls "$$BASE_DIR"/libHSrts*ghc$(GHC_VER).so 2>/dev/null | grep -v '_debug' | head -n1 || true)"; \
	[ -z "$$RTS_SO" ] && RTS_SO="$$(ls "$$RTS_DIR"/libHSrts*ghc$(GHC_VER).so 2>/dev/null | grep -v '_debug' | head -n1 || true)"; \
	test -n "$$RTS_SO" || { echo "[shim] ERROR: libHSrts*ghc$(GHC_VER).so not found"; exit 2; }; \
	ln -sfn "$$RTS_SO" "$(SHIM_DIR)/rts/libHSrts-ghc$(GHC_VER).so"; \
	echo "[shim] RTS → $$RTS_SO"; \
	for pkg in base ghc-prim integer-gmp; do \
	  dir="$$($(GHC_PKG) field $$pkg library-dirs --simple-output 2>/dev/null || true)"; \
	  [ -d "$$dir" ] && ln -sfn "$$dir" "$(SHIM_DIR)/$$(basename "$$dir")" || true; \
	done; \
	if $(GHC_PKG) field ghc-bignum library-dirs --simple-output >/dev/null 2>&1; then \
	  dir="$$($(GHC_PKG) field ghc-bignum library-dirs --simple-output)"; \
	  [ -d "$$dir" ] && ln -sfn "$$dir" "$(SHIM_DIR)/$$(basename "$$dir")" || true; \
	fi; \
	INC_DIRS="$$($(GHC_PKG) field rts include-dirs --simple-output 2>/dev/null || true)"; \
	CPP=""; CP=""; \
	for d in $$INC_DIRS; do CPP="$$CPP -I$$d"; CP="$$CP:$$d"; done; \
	printf "%s" "$$CPP" > "$(SHIM_DIR)/.cppflags"; \
	printf "%s" "$${CP#:}" > "$(SHIM_DIR)/.cpath"

ifeq ($(GHC_MAJOR),8)
  SUPERS_BIGNUM_PKG :=
  SUPERS_BIGNUM_PATTERN :=
else
  SUPERS_BIGNUM_PKG := -package ghc-bignum
  SUPERS_BIGNUM_PATTERN := ghc-bignum-*/libHSghc-bignum-*.so
endif

DEPS_PATTERNS := \
  rts/libHSrts*.so \
  x86_64-linux-ghc-$(GHC_VER)/libHSrts*.so \
  ghc-prim-*/libHSghc-prim-*.so \
  base-*/libHSbase-*.so \
  integer-gmp-*/libHSinteger-gmp-*.so \
  $(SUPERS_BIGNUM_PATTERN)

GMP_CANDIDATES := /usr/lib64/libgmp.so.10 /usr/lib/libgmp.so.10

SUPERS_LINK_FLAGS := -O2 -shared -dynamic -fPIC -no-hs-main \
  -hide-all-packages \
  -package base -package ghc-prim -package integer-gmp $(SUPERS_BIGNUM_PKG) \
  -no-user-package-db -package-env - \
  -optl -Wl,--disable-new-dtags \
  -optl -Wl,-z,noexecstack \
  -optl -Wl,-rpath,'$$ORIGIN/ghc-deps:$$ORIGIN' \
  -optl -Wl,--no-as-needed

supers: supers_prepare $(EXE_SUPERS)
	@mkdir -p $(SUPERS_DIR)
	@EXE_SUPERS="./$(EXE_SUPERS)" \
	 SUPERS_THREADED='$(SUPERS_THREADED)' \
	 SUPERS_WRAPPERS_MAX='$(SUPERS_WRAPPERS_MAX)' \
	 GHC="$(GHC)" \
	 GHC_LIBDIR="$(SHIM_DIR)" \
	 GHC_RTS_DIR="$(SHIM_DIR)/rts" \
	 RTS_SO="$(abspath $(SHIM_DIR)/rts/libHSrts-ghc$(GHC_VER).so)" \
	 CPPFLAGS="$$(cat $(SHIM_DIR)/.cppflags)" \
	 C_INCLUDE_PATH="$$(cat $(SHIM_DIR)/.cpath)" \
	 CPATH="$$(cat $(SHIM_DIR)/.cpath)" \
	 SUPERS_DIR="$(SUPERS_DIR)" \
	 DEPS_PATTERNS='$(DEPS_PATTERNS)' \
	 SUPERS_LINK_FLAGS='$(SUPERS_LINK_FLAGS)' \
	 PY_ALIAS="tools/alias_supers.py" \
	 PY_FIX="tools/fix_execstack.py" \
	 GMP_CANDIDATES='$(GMP_CANDIDATES)' \
	 TESTS='$(TESTS)' \
	 bash tools/build_supers.sh

# ════════════════════════════════════════════════════════════════
# ARTIFACT GENERATION (df, ast, code)
# ════════════════════════════════════════════════════════════════
df: $(DF_DOTS) $(DF_IMGS)
ast: $(AST_DOTS) $(AST_IMGS)
code: $(CODE_FL)

$(DF_OUT_DIR)/%.dot: $(TEST_DIR)/%.hss | $(EXE_DF)
	@mkdir -p $(DF_OUT_DIR)
	@echo "[DF   ] $< → $@"
	./$(EXE_DF) $< > $@

$(DF_IMG_DIR)/%.png: $(DF_OUT_DIR)/%.dot
	@mkdir -p $(DF_IMG_DIR)
	@echo "[PNG  ] $< → $@"
	$(DOT) -Tpng $< -o $@

$(AST_OUT_DIR)/%.dot: $(TEST_DIR)/%.hss | $(EXE_AST)
	@mkdir -p $(AST_OUT_DIR)
	@echo "[AST  ] $< → $@"
	./$(EXE_AST) $< > $@

$(AST_IMG_DIR)/%.png: $(AST_OUT_DIR)/%.dot
	@mkdir -p $(AST_IMG_DIR)
	@echo "[PNG  ] $< → $@"
	$(DOT) -Tpng $< -o $@

$(CODE_OUT_DIR)/%.fl: $(TEST_DIR)/%.hss | $(EXE_CODE)
	@mkdir -p $(CODE_OUT_DIR)
	@echo "[TALM ] $< → $@"
	./$(EXE_CODE) $< > $@

# ════════════════════════════════════════════════════════════════
# TESTS
# ════════════════════════════════════════════════════════════════
test: $(EXE_AST) $(EXE_DF) $(EXE_CODE)
	@echo ""
	@echo "══════════════════════════════════════════════════════"
	@echo " Ribault Correctness Tests"
	@echo "══════════════════════════════════════════════════════"
	@PASS=0; FAIL=0; \
	for hsk in $(TEST_DIR)/*.hss; do \
		[ -f "$$hsk" ] || continue; \
		name=$$(basename "$$hsk" .hss); \
		printf "  %-40s " "$$name"; \
		tmp=$$(mktemp -d); \
		if ./$(EXE_AST) "$$hsk" > "$$tmp/ast.dot" 2>/dev/null \
		   && ./$(EXE_DF) "$$hsk" > "$$tmp/df.dot" 2>/dev/null \
		   && ./$(EXE_CODE) "$$hsk" > "$$tmp/code.fl" 2>/dev/null; then \
			printf "PASS\n"; PASS=$$((PASS+1)); \
		else \
			printf "FAIL\n"; FAIL=$$((FAIL+1)); \
		fi; \
		rm -rf "$$tmp"; \
	done; \
	echo ""; \
	echo "══════════════════════════════════════════════════════"; \
	printf " %d passed, %d failed\n" "$$PASS" "$$FAIL"; \
	echo "══════════════════════════════════════════════════════"; \
	[ "$$FAIL" -eq 0 ] || exit 1

test-execute: $(EXE_AST) $(EXE_DF) $(EXE_CODE) $(EXE_SUPERS) interp
	@if [ -x benchmarks/run_tests.sh ]; then \
		./benchmarks/run_tests.sh --execute --talm-dir "$(TALM_DIR)"; \
	else \
		echo "benchmarks/run_tests.sh not found"; exit 1; \
	fi

# ════════════════════════════════════════════════════════════════
# BENCHMARKS
# ════════════════════════════════════════════════════════════════
bench: $(EXE_CODE) $(EXE_SUPERS) interp
	@if [ -x benchmarks/run_benchmarks.sh ]; then \
		./benchmarks/run_benchmarks.sh --talm-dir "$(TALM_DIR)"; \
	else \
		echo "benchmarks/run_benchmarks.sh not found"; exit 1; \
	fi

# ════════════════════════════════════════════════════════════════
# INSTALL / UNINSTALL
# ════════════════════════════════════════════════════════════════
install: compiler
	@echo "Installing Ribault to $(PREFIX) ..."
	install -d $(BINDIR) $(LIBDIR)/asm $(LIBDIR)/tools $(DATADIR)/test $(DATADIR)/benchmarks
	install -m 755 $(EXE_AST) $(EXE_DF) $(EXE_CODE) $(EXE_SUPERS) $(BINDIR)/
	install -m 755 ribault $(BINDIR)/ribault 2>/dev/null || true
	install -m 644 $(TALM_DIR)/asm/*.py $(LIBDIR)/asm/ 2>/dev/null || true
	@if [ -x $(TALM_DIR)/interp/interp ]; then \
		install -m 755 $(TALM_DIR)/interp/interp $(BINDIR)/trebuchet; \
	fi
	install -m 755 tools/*.sh $(LIBDIR)/tools/ 2>/dev/null || true
	install -m 644 tools/*.py $(LIBDIR)/tools/ 2>/dev/null || true
	install -m 644 tools/*.c  $(LIBDIR)/tools/ 2>/dev/null || true
	install -m 644 $(TEST_DIR)/*.hss $(DATADIR)/test/ 2>/dev/null || true
	install -m 755 benchmarks/*.sh $(DATADIR)/benchmarks/ 2>/dev/null || true
	@echo "Done. Binaries in $(BINDIR)/, libraries in $(LIBDIR)/"

uninstall:
	rm -f $(BINDIR)/analysis $(BINDIR)/synthesis $(BINDIR)/codegen
	rm -f $(BINDIR)/supersgen $(BINDIR)/trebuchet $(BINDIR)/ribault
	rm -rf $(LIBDIR) $(DATADIR)
	@echo "Uninstalled from $(PREFIX)"

# ════════════════════════════════════════════════════════════════
# DISTRIBUTION
# ════════════════════════════════════════════════════════════════
VERSION := 1.0.0
DIST_NAME := ribault-$(VERSION)

dist:
	@echo "Creating $(DIST_NAME).tar.gz ..."
	@rm -rf /tmp/$(DIST_NAME)
	@mkdir -p /tmp/$(DIST_NAME)
	@cp -a configure Makefile ribault LICENSE README.md .gitignore \
	       src/ test/ tools/ benchmarks/ results/ TALM/ /tmp/$(DIST_NAME)/ 2>/dev/null || true
	@tar czf $(DIST_NAME).tar.gz -C /tmp $(DIST_NAME)
	@rm -rf /tmp/$(DIST_NAME)
	@echo "→ $(DIST_NAME).tar.gz"

# ════════════════════════════════════════════════════════════════
# CLEAN
# ════════════════════════════════════════════════════════════════
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(EXE_AST) $(EXE_DF) $(EXE_CODE) $(EXE_SUPERS) $(EXE_RIBAULT)
	@rm -rf $(EXE_AST).obj $(EXE_AST).hi $(EXE_DF).obj $(EXE_DF).hi
	@rm -rf $(EXE_CODE).obj $(EXE_CODE).hi $(EXE_SUPERS).obj $(EXE_SUPERS).hi
	@rm -rf $(EXE_RIBAULT).obj $(EXE_RIBAULT).hi
	@rm -f $(LEXER_HS) $(PARSER_HS)
	@rm -rf $(SRC_DIR)/Analysis/*.hi $(SRC_DIR)/Analysis/*.o
	@rm -rf $(SRC_DIR)/Synthesis/*.hi $(SRC_DIR)/Synthesis/*.o
	@rm -f Supers.hs supers_rts_init.o perf.data tools/supers_rts_init.o
	@rm -rf $(DF_OUT_DIR) $(AST_OUT_DIR) $(CODE_OUT_DIR) $(SUPERS_DIR) build
	@rm -f config.mk
	@echo "Done."

distclean: clean
	@rm -f config.mk
	@$(MAKE) -C $(TALM_DIR)/interp clean 2>/dev/null || true
