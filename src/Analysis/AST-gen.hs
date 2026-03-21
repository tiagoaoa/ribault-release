{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{-|
Module      : Analysis.ASTGen
Description : DOT graph generator for the core AST, covering all language constructors (patterns and expressions), including TALM-style 'Super'.
Maintainer  : ricardofilhoschool@gmail.com
Stability   : experimental
Portability : portable

## Overview

This module traverses the core 'Syntax' AST and emits a Graphviz DOT
representation suitable for quick visualization and debugging. It covers
**all** pattern and expression constructors currently used by the language,
including the 'Super' extension node for coarse-grained super-instructions.

## Notes

- Node identifiers are allocated from a monotonically increasing counter kept
  in the state monad.
- Edges are emitted as the traversal discovers parent–child relationships.
- Labels are escaped to keep the DOT output valid (quotes, backslashes, newlines).

## Covered constructors

- Patterns: 'PWildcard', 'PVar', 'PLit', 'PList', 'PTuple', 'PCons'
- Expressions: 'Var', 'Lit', 'Lambda', 'If', 'Cons', 'Case', 'Let', 'App',
  'BinOp', 'UnOp', 'List', 'Tuple', 'Super'
-}

module Analysis.ASTGen
  ( astToDot       -- Program -> Text
  , programToDot   -- synonym
  ) where

import Syntax
import Data.List (intercalate)
import Control.Monad.State
import Control.Monad (when)
import qualified Data.Text.Lazy as TL

-- -----------------------------------------------------------------------------
-- DOT generation infrastructure
-- -----------------------------------------------------------------------------

-- | Opaque numeric node identifier for DOT nodes.
type NodeId = Int

-- | Accumulated DOT output state.
data G = G { gid :: !Int, out :: [String] }

-- | State monad used by the DOT generator.
type M a = State G a

-- | Append a single DOT line to the output buffer (no trailing newline needed).
push :: String -> M ()
push s = modify $ \g -> g{ out = s : out g }

-- | Generate a fresh 'NodeId'.
fresh :: M NodeId
fresh = do
  i <- gets gid
  modify $ \g -> g{ gid = i + 1 }
  pure i

-- | Emit a DOT node with a given textual label (properly escaped).
emitNode :: NodeId -> String -> M ()
emitNode n label =
  push $ show n ++ " [shape=box,label=\"" ++ esc label ++ "\"];"

-- | Emit a DOT edge from the first node to the second.
emitEdge :: NodeId -> NodeId -> M ()
emitEdge a b = push $ show a ++ " -> " ++ show b ++ ";"

-- | Escape a label string for inclusion in DOT source.
--
-- Escapes quotes, backslashes, and newlines.
esc :: String -> String
esc = concatMap f
  where
    f '"'  = "\\\""
    f '\\' = "\\\\"
    f '\n' = "\\n"
    f c    = [c]

-- | Run a generator action producing the root node and collect the full DOT file.
--
-- The resulting text includes a header, node defaults, all emitted lines,
-- and the closing brace.
runM :: M NodeId -> TL.Text
runM m =
  let g0  = G 0 []
      (_root, g1) = runState m g0
      ls = [ "digraph AST {"
           , "  rankdir=TB;"
           , "  node [shape=box,fontname=\"monospace\"];"
           ] ++ map ("  "++) (reverse (out g1))
             ++ ["}"]
  in TL.unlines (map TL.pack ls)

-- -----------------------------------------------------------------------------
-- API
-- -----------------------------------------------------------------------------

-- | Convert a 'Program' into DOT text (alias of 'programToDot').
--
-- === __Returns__
-- A lazy 'TL.Text' containing the full DOT source.
astToDot :: Program -> TL.Text
astToDot = programToDot

-- | Convert a 'Program' into DOT text.
--
-- === __Returns__
-- A lazy 'TL.Text' containing the full DOT source.
programToDot :: Program -> TL.Text
programToDot p = runM (visitProgram p)

-- -----------------------------------------------------------------------------
-- Visitors
-- -----------------------------------------------------------------------------

-- | Visit the root 'Program' and emit a \"Program\" node with edges to each declaration.
visitProgram :: Program -> M NodeId
visitProgram (Program ds) = do
  me <- fresh
  emitNode me "Program"
  mapM_ (\d -> visitDecl d >>= emitEdge me) ds
  pure me

-- | Visit a function declaration node, emitting:
--
-- * A \"FunDecl <name>\" node
-- * An optional \"Params ...\" child (if non-empty)
-- * An edge to the function body expression
visitDecl :: Decl -> M NodeId
visitDecl (FunDecl f ps e) = do
  me <- fresh
  emitNode me ("FunDecl " ++ f)
  -- params
  when (not (null ps)) $ do
    pnode <- fresh
    emitNode pnode ("Params " ++ intercalate " " ps)
    emitEdge me pnode
  -- body
  be <- visitExpr e
  emitEdge me be
  pure me

-- | Visit an expression and emit the corresponding subgraph.
--
-- Covers: 'Var', 'Lit', 'Lambda', 'If', 'Cons', 'Case', 'Let', flattened
-- multi-arg 'App', 'BinOp', 'UnOp', 'List', 'Tuple', and 'Super'.
visitExpr :: Expr -> M NodeId
visitExpr = \case
  Var x -> leaf ("Var " ++ x)
  Lit l -> leaf ("Lit " ++ showLit l)

  Lambda ps b -> do
    me <- fresh
    emitNode me ("Lambda " ++ intercalate " " ps)
    b' <- visitExpr b
    emitEdge me b'
    pure me

  If c t e -> do
    me <- fresh
    emitNode me "If"
    c' <- visitExpr c; emitEdge me c'
    t' <- visitExpr t; emitEdge me t'
    e' <- visitExpr e; emitEdge me e'
    pure me

  Cons h t -> do
    me <- fresh
    emitNode me "Cons (:)"
    h' <- visitExpr h; emitEdge me h'
    t' <- visitExpr t; emitEdge me t'
    pure me

  Case scr alts -> do
    me <- fresh
    emitNode me "Case"
    s' <- visitExpr scr
    emitEdge me s'
    -- alternatives
    mapM_ (\(p,bd) -> do
              altN <- fresh
              emitNode altN "Alt"
              pn <- visitPat p
              bn <- visitExpr bd
              emitEdge altN pn
              emitEdge altN bn
              emitEdge me altN
          ) alts
    pure me

  Let ds e -> do
    me <- fresh
    emitNode me "Let"
    dsN <- fresh
    emitNode dsN "Decls"
    emitEdge me dsN
    mapM_ (\d -> visitDecl d >>= emitEdge dsN) ds
    e' <- visitExpr e
    emitEdge me e'
    pure me

  -- n-ary application flattened to (function, args)
  e0@(App _ _) -> do
    let (f, xs) = flattenApp e0
    me <- fresh
    emitNode me "App"
    fn <- visitExpr f
    emitEdge me fn
    mapM_ (\a -> visitExpr a >>= emitEdge me) xs
    pure me

  BinOp op l r -> do
    me <- fresh
    emitNode me ("BinOp " ++ showBin op)
    l' <- visitExpr l; emitEdge me l'
    r' <- visitExpr r; emitEdge me r'
    pure me

  UnOp op x -> do
    me <- fresh
    emitNode me ("UnOp " ++ showUn op)
    x' <- visitExpr x
    emitEdge me x'
    pure me

  List xs -> do
    me <- fresh
    emitNode me "List"
    mapM_ (\a -> visitExpr a >>= emitEdge me) xs
    pure me

  Tuple xs -> do
    me <- fresh
    emitNode me ("Tuple/" ++ show (length xs))
    mapM_ (\a -> visitExpr a >>= emitEdge me) xs
    pure me

  -- <<< SUPER-INSTRUCTION SUPPORT >>>
  Super nm kind inp out _body -> do
    me <- fresh
    let k = case kind of { SuperSingle -> "single"; SuperParallel -> "parallel" }
    emitNode me ("Super[" ++ k ++ "]\\nname=" ++ nm
                 ++ "\\ninput=" ++ inp ++ "\\noutput=" ++ out)
    pure me
  where
    -- | Emit a leaf node with a given label and return its 'NodeId'.
    leaf :: String -> M NodeId
    leaf s = do n <- fresh; emitNode n s; pure n

-- | Helper: flatten an application tree into @(function, [args])@, left to right.
flattenApp :: Expr -> (Expr, [Expr])
flattenApp (App f x) = let (fn, xs) = flattenApp f in (fn, xs ++ [x])
flattenApp e         = (e, [])

-- | Visit a pattern and emit the corresponding subgraph.
visitPat :: Pattern -> M NodeId
visitPat = \case
  PWildcard   -> leaf "PWildcard"
  PVar x      -> leaf ("PVar " ++ x)
  PLit l      -> leaf ("PLit " ++ showLit l)
  PList ps    -> do
    me <- fresh
    emitNode me "PList"
    mapM_ (\p -> visitPat p >>= emitEdge me) ps
    pure me
  PTuple ps   -> do
    me <- fresh
    emitNode me ("PTuple/" ++ show (length ps))
    mapM_ (\p -> visitPat p >>= emitEdge me) ps
    pure me
  -- cons pattern (x:xs)
  PCons p ps  -> do
    me <- fresh
    emitNode me "PCons (:)"
    a <- visitPat p
    b <- visitPat ps
    emitEdge me a
    emitEdge me b
    pure me
  where
    -- | Emit a leaf node with a given label and return its 'NodeId'.
    leaf s = do n <- fresh; emitNode n s; pure n

-- -----------------------------------------------------------------------------
-- Pretty-printing of literals and operators (for labels)
-- -----------------------------------------------------------------------------

-- | Show a 'Literal' in a compact, label-friendly way.
showLit :: Literal -> String
showLit = \case
  LInt n    -> show n
  LFloat f  -> show f
  LBool b   -> show b
  LChar c   -> show c
  LString s -> show s

-- | Show a 'BinOperator' as its surface symbol.
showBin :: BinOperator -> String
showBin = \case
  Add -> "+"; Sub -> "-"; Mul -> "*"; Div -> "/"; Mod -> "%"
  Eq  -> "=="; Neq -> "/="; Lt  -> "<"; Le -> "<="; Gt -> ">"; Ge -> ">="
  And -> "&&"; Or  -> "||"

-- | Show a 'UnOperator' as its surface symbol or name.
showUn :: UnOperator -> String
showUn = \case
  Neg -> "negate"
  Not -> "not"
