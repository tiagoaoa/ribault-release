{-# LANGUAGE LambdaCase, FlexibleContexts #-}

{-|
Module      : Syntax
Description : Core Abstract Syntax Tree (AST) for a small, strict, purely functional language with extensions for TALM-style super blocks.
Copyright   :
License     :
Maintainer  : ricardofilhoschool@gmail.com
Stability   : experimental
Portability : portable

## Overview

This module defines the /Abstract Syntax Tree (AST)/ used across the compiler
pipeline (lexing → parsing → semantic analysis → code generation). It models
identifiers, top-level declarations, expressions (including lists, tuples,
pattern matching, and function application), patterns, literals, and basic
operators. It also contains an extension node ('Super') to represent
coarse-grained /super-instructions/ (i.e., serial regions) suitable for TALM
(Trebuchet) backends.

## Design Notes

- The language is first-order at the top level (only function declarations),
  but expressions support lambdas for local functional values.
- AST nodes do not carry source spans here; attach them in a parallel metadata
  structure if needed.
- The 'Super' constructor is a syntactic placeholder for “/execute this region
  as a super-instruction/”; backends may lower or interpret it specially.
- Operators are syntactic only; precedence/associativity is resolved in the
  parser, while types are assigned during semantic analysis.

## Invariants

- 'Program' groups a list of top-level 'Decl's; evaluation starts from a
  designated entry function (e.g., @main@) determined outside this module.
- 'Case' alternatives are matched top-to-bottom, first match wins.
- 'Let' binds only function declarations (no mutually recursive @let@-bound
  values beyond functions in this core AST).
- Lists are right-associated via 'Cons' during normalization (if performed).

-}
module Syntax where

-- | Identifier for variables and function names.
--
-- Typical examples include @\"x\"@, @\"map\"@, or @\"main\"@.
type Ident = String

-- | A complete program as a list of top-level declarations (functions only).
--
-- === Notes
-- The ordering of declarations is not semantically significant; dependency
-- resolution is handled in later phases.
data Program = Program [Decl]
  deriving (Show)

-- | A top-level declaration (currently only function declarations).
data Decl
  = -- | Function declaration with:
    --
    -- * Function name ('Ident')
    -- * Formal parameter names (left-to-right order)
    -- * Function body ('Expr')
    --
    -- The arity of the function is given by the length of the parameter list.
    FunDecl Ident [Ident] Expr
  deriving (Show)

-- | Kind of /super block/ to guide coarse-grained execution strategies.
--
-- Used by the 'Super' expression to hint whether the block is to be run
-- as a single serial region or in a parallel layout.
data SuperKind
  = -- | Single (serial) super-instruction region.
    SuperSingle
  | -- | Parallel super-instruction region (semantics defined by backend).
    SuperParallel
  deriving (Show)

-- | Core expressions of the language.
data Expr
  = -- | Variable reference.
    Var Ident
  | -- | Literal.
    Lit Literal
  | -- | Lambda abstraction with a (possibly empty) parameter list and a body.
    Lambda [Ident] Expr
  | -- | Conditional expression: @If cond thenBranch elseBranch@.
    If Expr Expr Expr
  | -- | Case analysis over a scrutinee, evaluated against ordered alternatives.
    Case Expr [(Pattern, Expr)]
  | -- | Local function declarations (possibly mutually recursive) with a body.
    --
    -- Only function declarations are permitted in this 'Let' form.
    Let [Decl] Expr
  | -- | Function application: left-associative.
    App Expr Expr
  | -- | Binary operator application with explicit operator node.
    BinOp BinOperator Expr Expr
  | -- | Unary operator application with explicit operator node.
    UnOp  UnOperator  Expr
  | -- | List literal.
    List  [Expr]
  | -- | Tuple literal (arity ≥ 2 is expected by later phases).
    Tuple [Expr]
  | -- | Cons cell: @Cons head tail@; typically normalized from list sugar.
    Cons  Expr Expr
  -- --------------- NEW ----------------
  | -- | Super-instruction block: @Super name kind inputVar outputVar body@.
    --
    -- === Semantics (frontend-level)
    -- This node marks a region intended for coarse-grained execution (e.g.,
    -- as a TALM super-instruction). Backends are free to lower/inline/emit
    -- metadata for this node according to their execution model.
    --
    -- === Parameters
    -- * @name@: symbolic tag (logical name) of the super block
    -- * @kind@: see 'SuperKind' ('SuperSingle' or 'SuperParallel')
    -- * @inputVar@: identifier that names the input port / view
    -- * @outputVar@: identifier that names the output port / view
    -- * @body@: backend-oriented payload (opaque string with the body between
    --   @#BEGINSUPER@ / @#ENDSUPER@ in the source), kept verbatim
    --
    -- === Notes
    -- - This constructor is intentionally opaque to the pure core language:
    --   semantic checking may only validate the surrounding wiring.
    -- - The backend decides how to bind @inputVar@ and @outputVar@ to its
    --   dataflow ports. The 'body' string is not interpreted here.
    Super Ident SuperKind Ident Ident String   -- ^ super <kind> input(x) output(y) BODY
  ----------------------------------------
  deriving (Show)

-- | Patterns permitted in 'Case' alternatives.
--
-- Matching proceeds top-down. List and cons patterns follow the usual
-- right-associated list structure.
data Pattern
  = -- | Wildcard (matches anything; binds no variable).
    PWildcard
  | -- | Variable pattern (binds the identifier to the matched value).
    PVar Ident
  | -- | Literal pattern (matches equal literal).
    PLit Literal
  | -- | List pattern: matches lists of the same length and recursively matches elements.
    PList  [Pattern]
  | -- | Tuple pattern: arity must match the scrutinee tuple.
    PTuple [Pattern]
  | -- | Cons pattern: @PCons head tail@.
    PCons  Pattern Pattern
  deriving (Show)

-- | Literal values supported by the language.
data Literal
  = -- | Machine integer literal (front-end normalized).
    LInt Int
  | -- | Double-precision floating-point literal.
    LFloat Double
  | -- | Character literal.
    LChar Char
  | -- | String literal (sequence of characters).
    LString String
  | -- | Boolean literal.
    LBool Bool
  deriving (Show)

-- | Binary operators.
--
-- Exact typing and desugaring of these operators is determined during
-- semantic analysis and/or desugaring phases.
data BinOperator
  = -- | Numeric addition or concatenation (if defined in later phases).
    Add
  | -- | Numeric subtraction.
    Sub
  | -- | Numeric multiplication.
    Mul
  | -- | Numeric division (exact semantics depend on type).
    Div
  | -- | Modulo / remainder.
    Mod
  | -- | Equality test.
    Eq
  | -- | Inequality test.
    Neq
  | -- | Less-than comparison.
    Lt
  | -- | Less-than-or-equal comparison.
    Le
  | -- | Greater-than comparison.
    Gt
  | -- | Greater-than-or-equal comparison.
    Ge
  | -- | Short-circuiting logical AND.
    And
  | -- | Short-circuiting logical OR.
    Or
  deriving (Show)

-- | Unary operators.
data UnOperator
  = -- | Arithmetic negation.
    Neg
  | -- | Logical negation.
    Not
  deriving (Show)
