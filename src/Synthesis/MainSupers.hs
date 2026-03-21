{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : CLI that extracts supers from a program and emits a Supers.hs module.
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Pipeline:
--   1. Read Haskell-subset source (file or stdin)
--   2. Lex and parse into AST
--   3. Assign symbolic names to Super nodes (s0, s1, ...)
--   4. Collect super specifications
--   5. Emit a Haskell module (Supers.hs) with FFI exports
--
-- Note: this tool does NOT run semantic/type checks. That is done in the
-- synthesis/codegen pipeline; here we only need a structurally valid AST
-- to extract supers and generate the FFI shim.
module Main where

import System.Environment (getArgs)
import System.Exit        (exitFailure)
import System.FilePath    (takeBaseName)
import System.IO          (readFile, getContents, hPutStrLn, stderr)

import qualified Analysis.Lexer         as L
import qualified Analysis.Parser        as P
import qualified Syntax        as S
import qualified Semantic      as Sem
import qualified Synthesis.SuperExtract as SE
import qualified Synthesis.SupersEmit   as SEt

main :: IO ()
main = do
  args  <- getArgs
  input <- case args of
    [file] -> readFile file
    []     -> getContents
    _      -> do
      hPutStrLn stderr "Usage: supersgen <file.hsk>"
      exitFailure

  -- Lexing
  toks <- case L.scanAll input of
    Left err -> do
      hPutStrLn stderr ("Lexical error: " ++ err)
      exitFailure
    Right ts -> pure ts

  -- Parsing + assign super names
  let ast0 :: S.Program
      ast0 = P.parse toks
      ast  = Sem.assignSuperNames ast0

  -- Collect supers and emit Supers.hs source
  let baseName = case args of
        [file] -> takeBaseName file
        []     -> "stdin"
      specs = SE.collectSupers ast
      hsSrc = SEt.emitSupersModule baseName specs

  putStr hsSrc
