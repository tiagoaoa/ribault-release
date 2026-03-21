{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Main
Description : CLI entry point that parses, semantically checks, and renders the AST to Graphviz DOT.
Maintainer  : ricardofilhoschool@gmail.com
Stability   : experimental
Portability : portable
-}
module Main where

import System.Environment (getArgs)
import System.IO          (readFile, getContents, hPutStrLn, stderr)
import System.Exit        (exitFailure)
import qualified Data.Text.Lazy.IO as TLIO

import Analysis.Lexer     (scanAll)
import Analysis.Parser    (parse)
import Syntax             (Program)
import Semantic           (checkAll, assignSuperNames)
import Analysis.ASTGen    (programToDot)

main :: IO ()
main = do
  args  <- getArgs
  input <- case args of
    [file] -> readFile file
    []     -> getContents
    _      -> hPutStrLn stderr "Usage: lambdaflow-ast [file]" >> exitFailure

  case scanAll input of
    Left err -> hPutStrLn stderr ("Lexer error: " ++ err) >> exitFailure
    Right toks -> do
      let ast0 :: Program
          ast0 = parse toks
          ast  = assignSuperNames ast0

      case checkAll ast of
        []   -> TLIO.putStr (programToDot ast)
        errs -> mapM_ (hPutStrLn stderr . show) errs >> exitFailure
