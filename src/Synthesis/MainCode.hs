{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Main
-- Description : Entry point to generate TALM assembly from the same pipeline as MainGraph.
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Pipeline:
--
--  1. Read Haskell-subset source (file or STDIN)
--  2. Lex, parse, and run semantic checks
--  3. Build the dataflow graph (Inst-level)
--  4. Convert the graph to TALM assembly and print to STDOUT
--
-- Build example:
--
-- > ghc -O2 -isrc -o lambdaflow-asm src/Synthesis/MainCode.hs
--
-- Usage:
--
-- > lambdaflow-asm program.hsk
-- > cat prog.hsk | lambdaflow-asm
-----------------------------------------------------------------------------
module Main where

import System.Environment (getArgs)
import System.IO          (readFile, getContents, hPutStrLn, stderr)
import System.Exit        (exitFailure)

import qualified Data.Text       as TS
import qualified Data.Text.Lazy  as TL
import qualified Data.Text.Lazy.IO as TLIO

-- Front-end ---------------------------------------------------------------
import Analysis.Lexer  (Token, scanAll)
import Analysis.Parser (parse)
import Syntax          (Program)
import Semantic        (checkAll)

-- Back-end ----------------------------------------------------------------
import qualified Synthesis.Builder as DF  -- AST → DGraph
import qualified Synthesis.Codegen as CG  -- DGraph → TALM assembly (strict Text)

-----------------------------------------------------------------------------
-- | Main executable. See module header for behavior and usage.
-----------------------------------------------------------------------------
main :: IO ()
main = do
  src <- getArgs >>= \case
           [file] -> readFile file
           []     -> getContents
           _      -> hPutStrLn stderr "Usage: lambdaflow-asm [file]" >> exitFailure

  tokens <- case scanAll src of
    Left err -> hPutStrLn stderr ("Lexical error: " ++ err) >> exitFailure
    Right ts -> pure ts

  let ast :: Program
      ast = parse tokens

  case checkAll ast of
    [] -> do
      let df      = DF.buildProgram ast
          asmText = TL.fromStrict (CG.assemble df)
      TLIO.putStr asmText
    errs -> mapM_ (hPutStrLn stderr . show) errs >> exitFailure
