{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Synthesis.SuperExtract
-- Description : Extracts super-instructions from the AST after 'assignSuperNames' (names s0, s1, ...).
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Walks the program AST, collecting unique 'SuperSpec's (by name).

module Synthesis.SuperExtract
  ( SuperSpec(..)
  , collectSupers
  ) where

import Syntax
import Data.List (nubBy)

-- | Minimal metadata needed to emit the supers module.
data SuperSpec = SuperSpec
  { ssName :: Ident        -- ^ \"s0\", \"s1\", …
  , ssKind :: SuperKind    -- ^ metadata (not used by the ABI)
  , ssInp  :: Ident        -- ^ logical input name
  , ssOut  :: Ident        -- ^ logical output name
  , ssBody :: String       -- ^ textual body stored in the AST (declarations/expression)
  }

-- | Remove duplicates by name (if a Super appears multiple times in the AST).
dedupByName :: [SuperSpec] -> [SuperSpec]
dedupByName = nubBy (\a b -> ssName a == ssName b)

-- | Collect all 'SuperSpec's from a 'Program', deduplicated by name.
collectSupers :: Program -> [SuperSpec]
collectSupers (Program decls) = dedupByName (concatMap declSupers decls)
  where
    declSupers :: Decl -> [SuperSpec]
    declSupers (FunDecl _ _ e) = exprSupers e

    exprSupers :: Expr -> [SuperSpec]
    exprSupers = \case
      Var _            -> []
      Lit _            -> []
      Lambda _ b       -> exprSupers b
      If a b c         -> exprSupers a ++ exprSupers b ++ exprSupers c
      Case scr alts    -> exprSupers scr ++ concat [ exprSupers rhs | (_pat, rhs) <- alts ]
      Let ds body      -> concatMap declSupers ds ++ exprSupers body
      App f x          -> exprSupers f ++ exprSupers x
      BinOp _ l r      -> exprSupers l ++ exprSupers r
      UnOp  _ e        -> exprSupers e
      List xs          -> concatMap exprSupers xs
      Tuple xs         -> concatMap exprSupers xs
      Cons h t         -> exprSupers h ++ exprSupers t
      Super nm k i o s -> [ SuperSpec nm k i o s ]
