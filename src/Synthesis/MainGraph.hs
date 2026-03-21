{-# LANGUAGE OverloadedStrings #-}
module Main where

-- |
-- Module      : Main
-- Description : Front-end (lexer/parser/semantic check) → Dataflow builder → GraphViz DOT.
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Reads a source file (or STDIN), lexes/parses it into an AST, runs semantic
-- checks, and—if successful—builds a dataflow graph and pretty-prints it
-- as GraphViz DOT to STDOUT. On semantic or lexical errors, prints them to
-- STDERR and exits with failure.
--
-- Usage:
--
-- > lambdaflow-df [file]
--
-- If @file@ is omitted, input is read from STDIN.

----------------------------------------------------------------------
-- Standard libraries
----------------------------------------------------------------------
import Prelude            hiding (readFile, getContents)
import System.Environment (getArgs)
import System.IO          (readFile, getContents, hPutStrLn, stderr)
import System.Exit        (exitFailure)

import qualified Data.Text.Lazy.IO as TLIO

----------------------------------------------------------------------
-- Front-end
----------------------------------------------------------------------
import Analysis.Lexer    (Token, scanAll)
import Analysis.Parser   (parse)
import Semantic          (checkAll)
import Syntax            (Program)

----------------------------------------------------------------------
-- Back-end: Builder → DOT
----------------------------------------------------------------------
import qualified Synthesis.Builder  as DF  -- buildProgram :: Program -> DFG
import qualified Synthesis.GraphViz as GV  -- toDot / toCleanDot :: DFG -> Text

----------------------------------------------------------------------
-- | Main entry point. See module header for behavior and usage.
----------------------------------------------------------------------
main :: IO ()
main = do
  args <- getArgs
  let (full, files) = case args of
        ("--full":rest) -> (True,  rest)
        other           -> (False, other)
  let render = if full then GV.toDot else GV.toCleanDot

  src <- case files of
    [file] -> readFile file
    []     -> getContents
    _      -> hPutStrLn stderr "Usage: lambdaflow-df [--full] [file]" >> exitFailure

  tokens <- case scanAll src of
    Left err -> hPutStrLn stderr ("Lexical error: " ++ err) >> exitFailure
    Right ts -> pure ts

  let ast :: Program
      ast = parse tokens

  case checkAll ast of
    []   -> TLIO.putStr . render $ DF.buildProgram ast
    errs -> mapM_ (hPutStrLn stderr . show) errs >> exitFailure
