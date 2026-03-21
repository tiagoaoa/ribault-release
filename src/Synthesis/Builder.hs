{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-|
Module      : Synthesis.Builder
Description : Lowers the core AST to a dataflow graph (DFG) of 'DNode's, wiring ports and managing environments/aliases.
Copyright   :
License     :
Maintainer  : ricardofilhoschool@gmail.com
Stability   : experimental
Portability : portable

This module builds a 'DFG' from a 'Syntax.Program'. It:

* Tracks lexical environments and free variables during synthesis.
* Emits nodes/edges, including fan-out via an alias mechanism.
* Handles applications (including n-ary flattening), conditionals, lists/tuples.
* Creates call/return groups for function calls and lambdas.
* Assigns names to @Super@ blocks via 'Semantic.assignSuperNames' before building.
-}
module Synthesis.Builder
  ( DFG
  , buildProgram
  ) where

import           Prelude hiding (lookup)
import           Control.Monad          (forM, forM_, zipWithM_, when)
import           Control.Monad.State    (StateT, get, put, runStateT, gets, modify)
import           Control.Monad.Trans    (lift)
import           Data.Maybe             (listToMaybe)
import           GHC.Float              (castFloatToWord32)
import qualified Data.Map              as M
import qualified Data.Set              as S

import           Semantic              (assignSuperNames)
import           Syntax
import           Types                  (DGraph(..), Edge, NodeId, emptyGraph, addNode, addEdge)
import           Port                   (Port(..), (-->))
import           Unique                 (Unique, evalUnique, freshId)
import           Node                   (DNode(..), out1Port)

-- Grafo final

-- | Final dataflow graph specialized to 'DNode'.
type DFG = DGraph DNode

-- Ambiente

-- | Builder-time binding: either a realized 'Port' or a lambda to be built.
data Binding = BPort Port | BLam [Ident] Expr

-- | A single-scope environment mapping identifiers to 'Binding'.
type Env = M.Map Ident Binding

-- | Aliases for a producer output identified by ('NodeId', output name).
type AliasMap    = M.Map (NodeId, String) [Port]

-- | Stack of currently active (being-built) functions.
type ActiveStack = [Ident]

-- | Global state for the builder pass.
data BuildS = BuildS
  { bsGraph      :: !DFG           -- ^ Accumulated graph.
  , bsEnv        :: ![Env]         -- ^ Environment stack (innermost at head).
  , bsAliases    :: !AliasMap      -- ^ Extra outputs that mirror a producer port.
  , bsActive     :: !ActiveStack   -- ^ Functions under construction (re-entrancy guard).
  , bsFloatFuns  :: !(S.Set Ident) -- ^ Functions observed in float contexts.
  , bsListFuns   :: !(S.Set Ident) -- ^ Functions that build/return lists.
  , bsRetVals    :: !(M.Map Ident Port) -- ^ Return value port for each function.
  , bsGuard      :: !(Maybe Port)  -- ^ Optional guard for gating calls in branches.
  , bsRecIx      :: !(M.Map Ident Int) -- ^ Recursion call-site indices per function.
  , bsCallIx     :: !(M.Map Ident Int) -- ^ Callgroup output indices per function.
  }

-- | Initial empty builder state.
emptyS :: BuildS
emptyS = BuildS emptyGraph [M.empty] M.empty [] S.empty S.empty M.empty Nothing M.empty M.empty

-- | Builder monad with unique-id generation.
newtype Build a = Build { unBuild :: StateT BuildS Unique a }
  deriving (Functor, Applicative, Monad)

-- | Execute a 'Build' computation, returning the result and final state.
runBuild :: Build a -> (a, BuildS)
runBuild m = evalUnique (runStateT (unBuild m) emptyS)

-- escopo ----------------------------------------------------------------

-- | Push a fresh environment onto the stack.
pushEnv, popEnv :: Build ()
pushEnv = Build $ modify (\s -> s { bsEnv = M.empty : bsEnv s })

-- | Pop the current environment (no-op on empty).
popEnv  = Build $ modify (\s -> case bsEnv s of [] -> s; (_:rs) -> s { bsEnv = rs })

-- | Run a computation with a temporary fresh environment.
withEnv :: Build a -> Build a
withEnv m = do pushEnv; x <- m; popEnv; pure x

-- | Run a computation with a temporary guard (used to gate calls in branches).
withGuard :: Port -> Build a -> Build a
withGuard guard m = do
  oldGuard <- Build $ gets bsGuard
  combined <- case oldGuard of
    Nothing -> pure guard
    Just g0 -> do
      g1 <- alignExecTo guard g0
      andP guard g1
  Build $ modify (\s' -> s' { bsGuard = Just combined })
  r <- m
  Build $ modify (\s' -> s' { bsGuard = oldGuard })
  pure r

-- | Run a computation with guard cleared (used when building function bodies).
withNoGuard :: Build a -> Build a
withNoGuard m = do
  s <- Build get
  Build $ put s { bsGuard = Nothing }
  r <- m
  Build $ modify (\s' -> s' { bsGuard = bsGuard s })
  pure r

-- | Apply the current guard to a value if one is active.
guardIfNeeded :: Port -> Build Port
guardIfNeeded p = do
  mg <- Build $ gets bsGuard
  case mg of
    Nothing -> pure p
    Just g  -> do
      gTok <- guardToken g
      mc <- getConstI p
      case mc of
        Just k -> do
          p0 <- withNoGuard (constI k)
          p' <- alignExecTo gTok p0
          sid <- newNode "steer" (NSteer "")
          connect gTok (InstPort sid "0")
          connect p'   (InstPort sid "1")
          pure (SteerPort sid "t")
        Nothing -> do
          g' <- alignGuardTo p gTok
          sid <- newNode "steer" (NSteer "")
          connect g' (InstPort sid "0")
          connect p  (InstPort sid "1")
          pure (SteerPort sid "t")

-- | Produce a branch execution token from a guard.
-- The token carries the guard value in its exec/tag so it can be used
-- as the callsnd operand to trigger a single branch execution.
guardToken :: Port -> Build Port
guardToken g = do
  one <- withNoGuard (constI 1)
  one' <- alignExecTo g one
  sid <- newNode "steer" (NSteer "")
  connect g    (InstPort sid "0")
  connect one' (InstPort sid "1")
  pure (SteerPort sid "t")

-- | Align a value's exec/tag to a guard port (so steers can match).
alignExecTo :: Port -> Port -> Build Port
alignExecTo guard val = do
  mc <- getConstI val
  case mc of
    Just k -> constFrom guard k
    Nothing -> retagTo guard val

-- | Align exec tags ignoring tag matching (exec-only).
alignExecToExecOnly :: Port -> Port -> Build Port
alignExecToExecOnly guard val = do
  mc <- getConstI val
  case mc of
    Just k -> constFrom guard k
    Nothing -> retagToExecOnly guard val

-- | Retag a value to match a tag source (uses tagval/valtag).
retagTo :: Port -> Port -> Build Port
retagTo tagSrc val = do
  tv <- newNode "tagval" (NTagVal "")
  connectPlus tagSrc (InstPort tv "0")
  vt <- newNode "valtag" (NValTag "")
  connectPlus val (InstPort vt "0")
  connectPlus (out0 tv) (InstPort vt "1")
  pure (out0 vt)

-- | Retag a value to match a tag source using exec-only matching.
-- Encodes the tag as a negative marker so TALM ignores tag matching.
retagToExecOnly :: Port -> Port -> Build Port
retagToExecOnly tagSrc val = do
  tv <- newNode "tagval" (NTagVal "")
  connectPlus tagSrc (InstPort tv "0")
  one <- constFrom tagSrc 1
  tv1 <- addI (out0 tv) 1
  z <- constFrom tagSrc 0
  neg <- bin2 "sub" (NSub "") z tv1
  vt <- newNode "valtag" (NValTag "")
  connectPlus val (InstPort vt "0")
  connectPlus neg (InstPort vt "1")
  pure (out0 vt)

-- | Retag a value to a constant tag k using exec-only matching.
retagToConstTagExecOnly :: Int -> Port -> Build Port
retagToConstTagExecOnly k val = do
  negK <- constFrom val (-(k + 1))
  vt <- newNode "valtag" (NValTag "")
  connectPlus val (InstPort vt "0")
  connectPlus negK (InstPort vt "1")
  pure (out0 vt)

-- | Increment tag of a value (inctag).
incTag :: Port -> Build Port
incTag p = do
  nid <- newNode "inctag" (NIncTag "")
  connectPlus p (InstPort nid "0")
  pure (out0 nid)

-- | Increment tag by an immediate (inctagi).
incTagI :: Int -> Port -> Build Port
incTagI k p = do
  nid <- newNode ("inctagi_" ++ show k) (NIncTagI "" k)
  connectPlus p (InstPort nid "0")
  pure (out0 nid)

-- | Decrement tag by an immediate (inctagi with negative).
decTagI :: Int -> Port -> Build Port
decTagI k p = incTagI (-k) p

-- | Radix used to encode recursive tag paths.
-- Must be > (max number of distinct call sites to the same function) + 1.
-- Each nesting level multiplies the tag by this radix, so it must fit
-- in 32-bit signed int for the deepest recursion expected.
-- Radix 9 supports up to 8 unique call sites and allows depth ~19
-- before overflowing signed 32-bit (9^19 ~ 1.35e18 < 2^31 is wrong,
-- but 9^9 ~ 387M fits comfortably; practical limit ~depth 9-10).
tagRadix :: Int
tagRadix = 9

-- | Build a unique child tag using parent tag * radix + k.
mkChildTag :: Int -> Port -> Build Port
mkChildTag k parent = do
  tv <- newNode "tagval" (NTagVal "")
  connectPlus parent (InstPort tv "0")
  scaled <- mulI (out0 tv) tagRadix
  bumped <- addI scaled k
  vt <- newNode "valtag" (NValTag "")
  connectPlus parent (InstPort vt "0")
  connectPlus bumped (InstPort vt "1")
  pure (out0 vt)

-- | Recover parent tag by dividing by the radix.
mkParentTag :: Port -> Build Port
mkParentTag child = do
  tv <- newNode "tagval" (NTagVal "")
  connectPlus child (InstPort tv "0")
  divN <- newNode ("divi_" ++ show tagRadix) (NDivI "" tagRadix)
  connectPlus (out0 tv) (InstPort divN "0")
  vt <- newNode "valtag" (NValTag "")
  connectPlus child (InstPort vt "0")
  connectPlus (out0 divN) (InstPort vt "1")
  pure (out0 vt)

-- | Recover parent tag using exec-only retagging (keeps values even on tag mismatch).
mkParentTagExecOnly :: Port -> Build Port
mkParentTagExecOnly child = do
  tv <- newNode "tagval" (NTagVal "")
  connectPlus child (InstPort tv "0")
  divN <- newNode ("divi_" ++ show tagRadix) (NDivI "" tagRadix)
  connectPlus (out0 tv) (InstPort divN "0")
  z <- constFrom child 0
  div1 <- addI (out0 divN) 1
  neg <- bin2 "sub" (NSub "") z div1
  vt <- newNode "valtag" (NValTag "")
  connectPlus child (InstPort vt "0")
  connectPlus neg (InstPort vt "1")
  pure (out0 vt)

-- | Allocate a small recursion call-site index for function @f@.
nextRecIx :: Ident -> Build Int
nextRecIx f = Build $ do
  s <- get
  let i = M.findWithDefault 0 f (bsRecIx s) + 1
  put s { bsRecIx = M.insert f i (bsRecIx s) }
  pure i

-- | Allocate a callgroup output index for function @f@ (0-based).
nextCallIx :: Ident -> Build Int
nextCallIx f = Build $ do
  s <- get
  let i = M.findWithDefault 0 f (bsCallIx s)
  put s { bsCallIx = M.insert f (i + 1) (bsCallIx s) }
  pure i

-- | Align a guard's exec/tag to match a value (so steers can fire).
alignGuardTo :: Port -> Port -> Build Port
alignGuardTo val guard = do
  mc <- getConstI guard
  case mc of
    Just k -> constFrom val k
    Nothing -> retagTo val guard

-- | Record/lookup the canonical return-value port for a function.
setRetVal :: Ident -> Port -> Build ()
setRetVal f p = Build $ modify (\s -> s { bsRetVals = M.insert f p (bsRetVals s) })

lookupRetVal :: Ident -> Build (Maybe Port)
lookupRetVal f = Build $ gets (M.lookup f . bsRetVals)

-- | Insert a 'Binding' for an identifier into the current environment.
insertB :: Ident -> Binding -> Build ()
insertB x b = Build $ modify $ \s -> case bsEnv s of
  (e:rs) -> s { bsEnv = M.insert x b e : rs }
  []     -> s

-- | Look up an identifier through the stacked environments (inner to outer).
lookupB :: Ident -> Build (Maybe Binding)
lookupB x = Build $ gets $ \s ->
  let go []     = Nothing
      go (e:rs) = maybe (go rs) Just (M.lookup x e)
  in go (bsEnv s)

-- | Update a binding at the scope where it was originally defined.
-- Unlike 'insertB' (which inserts into the innermost scope), this finds
-- the scope that already contains the identifier and updates it there.
-- This prevents duplicate evaluation of thunks across scope boundaries.
updateB :: Ident -> Binding -> Build ()
updateB x b = Build $ modify $ \s -> s { bsEnv = go (bsEnv s) }
  where
    go []     = []
    go (e:rs)
      | M.member x e = M.insert x b e : rs
      | otherwise     = e : go rs

-- marcação de função float ---------------------------------------------

-- | Mark a function as having been used in a floating-point context.
markFloatFun :: Ident -> Build ()
markFloatFun f = Build $ modify (\s -> s { bsFloatFuns = S.insert f (bsFloatFuns s) })

-- | Check whether a function is marked as float.
isFloatFun :: Ident -> Build Bool
isFloatFun f = Build $ gets (\s -> S.member f (bsFloatFuns s))

-- | Mark a function as building/returning lists.
markListFun :: Ident -> Build ()
markListFun f = Build $ modify (\s -> s { bsListFuns = S.insert f (bsListFuns s) })

-- | Check whether a function is marked as list-producing.
isListFun :: Ident -> Build Bool
isListFun f = Build $ gets (\s -> S.member f (bsListFuns s))

-- | True if the top of the active stack is a float-marked function.
isFloatActive :: Build Bool
isFloatActive = Build $ gets $ \s -> case bsActive s of
  (f:_) -> S.member f (bsFloatFuns s)
  _     -> False

-- | True if the top of the active stack is a list-marked function.
isListActive :: Build Bool
isListActive = Build $ gets $ \s -> case bsActive s of
  (f:_) -> S.member f (bsListFuns s)
  _     -> False

-- helper: está construindo 'f' agora?

-- | Is a given function currently being built (in the active stack)?
isActiveFun :: Ident -> Build Bool
isActiveFun f = Build $ gets (\s -> f `elem` bsActive s)

-- edges + aliases ------------------------------------------------------

-- | Emit a raw 'Edge' into the graph.
emit :: Edge -> Build ()
emit e = Build $ modify (\s -> s { bsGraph = addEdge e (bsGraph s) })

-- | Conservative check for list/tuple construction in an expression.
exprHasList :: Expr -> Bool
exprHasList = \case
  Cons _ _       -> True
  List _         -> True
  Tuple _        -> True
  Lambda _ e     -> exprHasList e
  If c t e       -> exprHasList c || exprHasList t || exprHasList e
  Case scr alts  -> exprHasList scr || any (exprHasList . snd) alts
  Let ds b       -> any declHasList ds || exprHasList b
  App f x        -> exprHasList f || exprHasList x
  BinOp _ l r    -> exprHasList l || exprHasList r
  UnOp _ e       -> exprHasList e
  _              -> False

declHasList :: Decl -> Bool
declHasList (FunDecl _ _ body) = exprHasList body

exprHasFloat :: Expr -> Bool
exprHasFloat = \case
  Lit (LFloat _) -> True
  Lambda _ e     -> exprHasFloat e
  If c t e       -> exprHasFloat c || exprHasFloat t || exprHasFloat e
  Case scr alts  -> exprHasFloat scr || any (exprHasFloat . snd) alts
  Let ds b       -> any declHasFloat ds || exprHasFloat b
  App f x        -> exprHasFloat f || exprHasFloat x
  BinOp _ l r    -> exprHasFloat l || exprHasFloat r
  UnOp _ e       -> exprHasFloat e
  _              -> False

declHasFloat :: Decl -> Bool
declHasFloat (FunDecl _ _ body) = exprHasFloat body

-- | Connect two 'Port's by emitting an edge.
connect :: Port -> Port -> Build ()
connect a b = emit (a --> b)

-- | Register additional alias outputs for the same producer port.
registerAlias :: Port -> [Port] -> Build ()
registerAlias src extras = Build $ modify $ \s ->
  let k = (pNode src, pName src)
  in s { bsAliases = M.insertWith (++) k extras (bsAliases s) }

-- | Connect a destination to a source and all of its aliases.
connectPlus :: Port -> Port -> Build ()
connectPlus src dst = Build $ do
  s <- get
  let k     = (pNode src, pName src)
      alts  = M.findWithDefault [] k (bsAliases s)
      allPs = src : alts
  put s { bsGraph = foldr (\p g -> addEdge (p --> dst) g) (bsGraph s) allPs }

-- nós ------------------------------------------------------------------

-- | Create a new node with label and payload, returning its 'NodeId'.
newNode :: String -> DNode -> Build NodeId
newNode lbl nd = Build $ do
  s   <- get
  nid <- lift freshId
  let g' = addNode nid (setName lbl nd) (bsGraph s)
  put s { bsGraph = g' }
  pure nid

-- | Create an n-ary node and connect sequential inputs to its ports.
naryNode :: String -> DNode -> [Port] -> Build NodeId
naryNode lbl nd ins = do
  nid <- newNode lbl nd
  zipWithM_ (\i p -> connectPlus p (InstPort nid (show i))) [0..] ins
  pure nid

-- | Convenience accessor for the first output port of a node.
out0 :: NodeId -> Port
out0 nid = InstPort nid "0"

-- | Convenience accessor for the second output port of a node.
out1 :: NodeId -> Port
out1 nid = InstPort nid "1"

-- | Write a display name into a 'DNode' (for debugging/graphs).
setName :: String -> DNode -> DNode
setName l n = case n of
  NConstI{}   -> n{ nName = l }
  NConstF{}   -> n{ nName = l }
  NConstD{}   -> n{ nName = l }
  NAdd{}      -> n{ nName = l }
  NSub{}      -> n{ nName = l }
  NMul{}      -> n{ nName = l }
  NDiv{}      -> n{ nName = l }
  NAddI{}     -> n{ nName = l }
  NSubI{}     -> n{ nName = l }
  NMulI{}     -> n{ nName = l }
  NFMulI{}    -> n{ nName = l }
  NDivI{}     -> n{ nName = l }
  NFAdd{}     -> n{ nName = l }
  NFSub{}     -> n{ nName = l }
  NFMul{}     -> n{ nName = l }
  NFDiv{}     -> n{ nName = l }
  NDAdd{}     -> n{ nName = l }
  NBand{}     -> n{ nName = l }
  NSteer{}    -> n{ nName = l }
  NLThan{}    -> n{ nName = l }
  NGThan{}    -> n{ nName = l }
  NEqual{}    -> n{ nName = l }
  NLThanI{}   -> n{ nName = l }
  NGThanI{}   -> n{ nName = l }
  NCallGroup{}-> n{ nName = l }
  NCallSnd{}  -> n{ nName = l }
  NRetSnd{}   -> n{ nName = l }
  NRet{}      -> n{ nName = l }
  NTagVal{}   -> n{ nName = l }
  NValTag{}   -> n{ nName = l }
  NIncTag{}   -> n{ nName = l }
  NIncTagI{}  -> n{ nName = l }
  NCpHToDev{} -> n{ nName = l }
  NCpDevToH{} -> n{ nName = l }
  NCommit{}   -> n{ nName = l }
  NStopSpec{} -> n{ nName = l }
  NArg{}      -> n{ nName = l }
  NSuper{}    -> n{ nName = l }

-- codificação pares/listas ---------------------------------------------

-- Builtin supers reserved in Semantic: s0..s3
builtinListCons :: Int
builtinListCons = 0

builtinListHead :: Int
builtinListHead = 1

builtinListTail :: Int
builtinListTail = 2

builtinListIsNil :: Int
builtinListIsNil = 3

superNameFromNum :: Int -> String
superNameFromNum n = "s" ++ show n

superNumFromName :: String -> Int
superNumFromName ('s':rest) =
  case reads rest of
    [(n,"")] -> n
    _        -> 0
superNumFromName _ = 0

-- | Emit an integer constant node.
constI :: Int -> Build Port
constI k = do
  mg <- Build $ gets bsGuard
  case mg of
    Nothing -> newNode ("const_" ++ show k) (NConstI "" k) >>= \nid -> pure (out0 nid)
    Just g  -> constFrom g k

-- | Try to read an integer literal from a port.
getConstI :: Port -> Build (Maybe Int)
getConstI p = Build $ gets $ \s ->
  case M.lookup (pNode p) (dgNodes (bsGraph s)) of
    Just (NConstI _ k) -> Just k
    Just (NConstF _ f) -> Just (fromIntegral (castFloatToWord32 f))
    _                  -> Nothing

-- | Build an int constant aligned to a reference port's exec/tag.
constFrom :: Port -> Int -> Build Port
constFrom ref k = do
  if pNode ref == (-1)
    then newNode ("const_" ++ show k) (NConstI "" k) >>= \nid -> pure (out0 nid)
    else do
      subN <- bin2Node "sub" (NSub "") ref ref
      let z = out0 subN
      if k == 0 then pure z else addI z k

-- immediates (sem aliases!)

-- | Add immediate @k@ to input (no alias expansion).
addI :: Port -> Int -> Build Port
addI p k
  | k == 0 = retagTo p p
  | otherwise = do
      nid <- newNode ("addi_" ++ show k) (NAddI "" k)
      connect p (InstPort nid "0")
      pure (out0 nid)

-- | Subtract immediate @k@ from input (no alias expansion).
subI :: Port -> Int -> Build Port
subI p k = do
  nid <- newNode ("subi_" ++ show k) (NSubI "" k)
  connect p (InstPort nid "0")
  pure (out0 nid)

-- | Multiply by immediate @k@ (no alias expansion).
mulI :: Port -> Int -> Build Port
mulI p k = do
  nid <- newNode ("muli_" ++ show k) (NMulI "" k)
  connect p (InstPort nid "0")
  pure (out0 nid)

-- fmuli helper (sem aliases!)

-- | Multiply by a floating immediate (no alias expansion).
fmulI :: Port -> Float -> Build Port
fmulI p k = do
  nid <- newNode ("fmuli_" ++ show k) (NFMulI "" k)
  connect p (InstPort nid "0")
  pure (out0 nid)

-- | Port representing the empty list.
nilP :: Build Port
nilP = constI 0

-- | Predicate: is the list port equal to 'nilP'?
isNilP :: Port -> Build Port
isNilP xs = callBuiltinSuper builtinListIsNil [xs]

callBuiltinSuper :: Int -> [Port] -> Build Port
callBuiltinSuper num ins = do
  ins' <- alignExecInputs ins
  let nm = "builtin_" ++ superNameFromNum num
  nid <- naryNode nm NSuper
           { nName     = ""
           , superNum  = num
           , superOuts = 1
           , superSpec = False
           , superImm  = Nothing
           } ins'
  pure (out0 nid)

-- | Align constant inputs to a non-constant reference (keeps exec tags consistent).
alignConstInputs :: [Port] -> Build [Port]
alignConstInputs ins = do
  cs <- mapM getConstI ins
  case [ (i,p) | (i,(p,mc)) <- zip [0..] (zip ins cs), mc == Nothing ] of
    []        -> pure ins
    ((_,r):_) -> mapM (alignOne r) (zip ins cs)
  where
    alignOne _ (p, Nothing) = pure p
    alignOne r (p, Just k)  = do _ <- pure p; constFrom r k

-- | Align all inputs (constants and non-constants) to a single reference exec/tag.
alignExecInputs :: [Port] -> Build [Port]
alignExecInputs ins = do
  cs <- mapM getConstI ins
  case [ p | (p,mc) <- zip ins cs, mc == Nothing ] of
    []    -> pure ins
    (r:_) -> mapM (alignOne r) (zip ins cs)
  where
    alignOne r (p, Just k)  = do _ <- pure p; constFrom r k
    alignOne _ (p, Nothing) = pure p

-- | Encode a pair/list cell via builtin list cons.
pairEnc :: Port -> Port -> Build Port
pairEnc a b = do
  -- Using cons implies list construction in the current function.
  act <- Build $ gets bsActive
  case act of
    (f:_) -> markListFun f
    _     -> pure ()
  ins <- alignExecInputs [a, b]
  case ins of
    [a', b'] -> do
      ma <- getConstI a'
      mb <- getConstI b'
      b'' <- if ma == Nothing && mb == Nothing
               then retagTo a' b'
               else pure b'
      callBuiltinSuper builtinListCons [a', b'']
    _        -> callBuiltinSuper builtinListCons [a, b]

-- | Decode first component from encoded pair.
fstDec :: Port -> Build Port
fstDec p = callBuiltinSuper builtinListHead [p]

-- | Decode second component from encoded pair.
sndDec :: Port -> Build Port
sndDec p = callBuiltinSuper builtinListTail [p]

-- | Local right-associative monadic fold (used for list construction).
foldrM' :: (a -> b -> Build b) -> b -> [a] -> Build b
foldrM' f z0 = go
  where
    go []     = pure z0
    go (y:ys) = do r <- go ys
                   f y r

-- API ------------------------------------------------------------------

-- | Build a 'DFG' from a 'Program'. Also assigns super names first.
buildProgram :: Program -> DFG
buildProgram p0 =
  let Program decls = assignSuperNames p0
      (_, st) = runBuild $ do
        mapM_ (\(FunDecl f ps body) -> insertB f (BLam ps body)) decls
        mapM_ buildZero decls
  in bsGraph st
  where
    retName f = f
    -- | Build and expose zero-argument functions as graph roots.
    buildZero (FunDecl f ps body) | null ps = do
      p <- withEnv (goExpr body)
      insertB f (BPort p)
      r <- retNodeId f
      setRetVal f p
      connectPlus p (InstPort r "0")
    buildZero _ = pure ()

-- função já construída?

-- | Has a return node for the given function @f@ already been emitted?
funBuilt :: Ident -> Build Bool
funBuilt f = Build $ gets $ \s -> any isRet (M.toList (dgNodes (bsGraph s)))
  where isRet (_, n) = case n of { NRet f' -> f' == f; _ -> False }

-- | Return node id for function @f@, creating it if needed.
retNodeId :: Ident -> Build NodeId
retNodeId f = Build $ do
  s <- get
  let nm    = f
      found = [ nid
              | (nid, n) <- M.toList (dgNodes (bsGraph s))
              , case n of
                  NRet nm' -> nm' == nm
                  _        -> False
              ]
  case found of
    (h:_) -> pure h
    []    -> do
      nid <- lift freshId
      let g' = addNode nid (NRet nm) (bsGraph s)
      put s { bsGraph = g' }
      pure nid

-- evita reentrada recursiva

-- | Ensure a function @f@ is built at most once; guard against recursion.
ensureBuilt :: Ident -> [Ident] -> Expr -> Build ()
ensureBuilt f ps body = do
  done   <- funBuilt f
  active <- isActiveFun f
  if done || active
     then pure ()
     else do
       when (exprHasList body) (markListFun f)
       when (exprHasFloat body) (markFloatFun f)
       retStub <- newNode (f ++ "_retstub") (NAddI "" 0)
       setRetVal f (out0 retStub)
       _ <- withActive f $ withNoGuard $ withEnv $ do
              forM_ (zip [0..] ps) $ \(i, v) -> do
                let slot = i + 1
                a <- argNode f slot
                insertB v (BPort a)
              res <- goExpr body
              _ <- retNodeId f
              connectPlus res (InstPort retStub "0")
       pure ()

-- variável livre -> NArg

-- | Treat an unbound variable as a free 'NArg' input node.
freeVar :: Ident -> Build Port
freeVar x = do
  nid <- newNode x (NArg x)
  let p = out0 nid
  insertB x (BPort p)
  pure p

-- detecta se um Port carrega float (por origem)

-- | Heuristically check if a port originates from floating-point ops/values.
portIsFloat :: Port -> Build Bool
portIsFloat p = Build $ gets $ \s -> case M.lookup (pNode p) (dgNodes (bsGraph s)) of
  Just NConstF{}     -> True
  Just NFAdd{}       -> True
  Just NFSub{}       -> True
  Just NFMul{}       -> True
  Just NFDiv{}       -> True
  Just (NRetSnd f _ _) -> S.member f (bsFloatFuns s)
  _                  -> False

-- | Is the current operation in a floating-point context?
isFloatContext :: Port -> Port -> Build Bool
isFloatContext a b = do
  af <- isFloatActive
  pa <- portIsFloat a
  pb <- portIsFloat b
  pure (af || pa || pb)

-- Expressões -----------------------------------------------------------

-- | Synthesize an expression into the graph and return its output 'Port'.
goExpr :: Expr -> Build Port
goExpr = \case
  Var x -> do
    lookupB x >>= \case
      Just (BPort p) -> pure p
      Just (BLam ps body) ->
        if null ps
          then do p <- withEnv (goExpr body)
                  updateB x (BPort p)
                  pure p
          else freeVar x
      Nothing -> freeVar x

  Lit lit -> litNode lit

  Lambda ps e ->
    withEnv $ do
      mapM_ (\v -> insertB v (BPort (InstPort (-1) v))) ps
      goExpr e

  If c t e -> do
    pc0 <- goExpr c
    pc <- boolify pc0
    pcTok <- guardToken pc
    vt0 <- withEnv (withGuard pc (goExpr t))
    vt <- alignExecTo pcTok vt0
    npc <- notP pc
    npcTok <- guardToken npc
    ve0 <- withEnv (withGuard npc (goExpr e))
    ve <- alignExecTo npcTok ve0
    stT <- newNode "if_t" (NSteer "")
    connect pc (InstPort stT "0")
    connect vt   (InstPort stT "1")
    let outT = SteerPort stT "t"

    stF <- newNode "if_f" (NSteer "")
    connect npc (InstPort stF "0")
    connect ve   (InstPort stF "1")
    let outF = SteerPort stF "t"

    registerAlias outT [outF]
    pure outT

  -- listas / tuplas
  Cons a b     -> do pa <- goExpr a; pb <- goExpr b; pairEnc pa pb
  List xs      -> do z <- nilP; es <- mapM goExpr xs; foldrM' pairEnc z es
  Tuple [a,b]  -> do pa <- goExpr a; pb <- goExpr b; pairEnc pa pb
  Tuple (a:_)  -> goExpr a
  Tuple []     -> constI 0

  Case scr alts -> compileCase scr alts

  Let decls body -> withEnv (mapM_ goDecl decls >> goExpr body)

  App f x -> let (g,args) = flattenApp (App f x) in goApp g args

  BinOp op l r -> do
    pl <- goExpr l
    pr <- goExpr r
    fctx <- isFloatContext pl pr
    case op of
      Add | fctx      -> bin2 "fadd" (NFAdd "")  pl pr
          | otherwise -> bin2 "add"  (NAdd  "")  pl pr
      Sub | fctx      -> do ny <- fmulI pr (-1.0)     -- fsub = fadd(x, y*-1)
                            bin2 "fadd" (NFAdd "") pl ny
          | otherwise -> bin2 "sub"  (NSub  "")  pl pr
      Mul | fctx      -> bin2 "fmul" (NFMul "")  pl pr
          | otherwise -> bin2 "mul"  (NMul  "")  pl pr
      Div | fctx      -> bin2 "div"  (NDiv  "")  pl pr  -- sem fdiv no ASM
          | otherwise -> bin2 "div"  (NDiv  "")  pl pr
      Mod -> do
        qN <- bin2Node "div" (NDiv "") pl pr
        pure (out1Port qN)
      Eq  -> bin2 "equal" (NEqual "") pl pr
      Lt  -> bin2 "lthan" (NLThan "") pl pr
      Gt  -> bin2 "gthan" (NGThan "") pl pr
      And -> bin2 "band"  (NBand  "") pl pr
      Or  -> do s <- bin2Node "add" (NAdd "") pl pr
                z <- constI 0
                bin2 "gthan" (NGThan "") (out0 s) z
      Le  -> do lt <- bin2 "lthan" (NLThan "") pl pr
                eq <- bin2 "equal" (NEqual "")  pl pr
                orP lt eq
      Ge  -> do gt <- bin2 "gthan" (NGThan "") pl pr
                eq <- bin2 "equal" (NEqual "")  pl pr
                orP gt eq
      Neq -> do eq <- bin2 "equal" (NEqual "")  pl pr
                notP eq

  UnOp u e -> do
    pe <- goExpr e
    case u of
      Neg -> do z <- constI 0; bin2 "sub" (NSub "") z pe
      Not -> notP pe

  Super nm kind inp out _ -> do
    pIn <- goExpr (Var inp)
    nid <- naryNode nm NSuper
             { nName     = ""
             , superNum  = superNumFromName nm
             , superOuts = 1
             -- Avoid speculative supers for HSK `super parallel` to preserve correctness
             -- when no explicit commit/stopspec nodes are emitted.
             , superSpec = False
             , superImm  = Nothing
             } [pIn]
    insertB out (BPort (out0 nid))
    pure (out0 nid)

-- Declarações ----------------------------------------------------------

-- | Insert a function lambda into the environment.
goDecl :: Decl -> Build ()
goDecl (FunDecl f ps body) = insertB f (BLam ps body)

-- Aplicação n-ária -----------------------------------------------------

-- | Flatten nested applications into @(head, args)@.
flattenApp :: Expr -> (Expr, [Expr])
flattenApp = \case
  App f x ->
    let (g, xs) = flattenApp f
    in (g, xs ++ [x])
  e -> (e, [])

-- | Mark a function as active while executing an action, then restore.
withActive :: Ident -> Build a -> Build a
withActive f m = Build $ do
  s <- get
  put s{ bsActive = f : bsActive s }
  r <- unBuild m
  s' <- get
  put s'{ bsActive = tail (bsActive s') }
  pure r

-- taskId determinístico

-- | Deterministic task identifier derived from the function name.
funTaskId :: Ident -> Int
funTaskId _ident = 0

-- nó de argumento formal

-- | Ensure the formal argument node @fun#i@ exists and return its output port.
argNode :: String -> Int -> Build Port
argNode fun i = Build $ do
  s <- get
  let nm    = fun ++ "#" ++ show i
      found = [ nid
              | (nid, n) <- M.toList (dgNodes (bsGraph s))
              , case n of
                  NArg nm' -> nm' == nm
                  _        -> False
              ]
  nid <- case found of
           (h:_) -> pure h
           []    -> do
             nid' <- lift freshId
             let g' = addNode nid' (NArg nm) (bsGraph s)
             put s { bsGraph = g' }
             pure nid'
  pure (out0 nid)

-- formal + alias para o real

-- | Bind a formal parameter to the actual input port, wiring aliases.
bindFormal :: String -> Int -> Ident -> Port -> Build ()
bindFormal fun i formal actual = do
  let slot = i + 1
  ap <- argNode fun slot
  insertB formal (BPort ap)
  case ap of
    InstPort nid _ -> connectPlus actual (InstPort nid "0")
    _              -> pure ()

-- | Apply a function or lambda to argument expressions.
goApp :: Expr -> [Expr] -> Build Port
goApp fun args = case fun of
  Var f -> do
    argv0 <- mapM goExpr args
    argv1 <- mapM guardIfNeeded argv0
    argv <- alignExecInputs argv1
    anyFloat <- or <$> mapM portIsFloat argv
    when anyFloat (markFloatFun f)

    lookupB f >>= \case
      Just (BLam ps body) -> ensureBuilt f ps body
      _                   -> pure ()

    let tid = funTaskId f
    cg <- newNode f (NCallGroup f)
    cgIx <- nextCallIx f
    let cgTag = "cg" ++ show cg
    recCall <- isActiveFun f
    listCall <- isListFun f
    callIx <- nextRecIx f
    let k = (callIx `mod` (tagRadix - 1)) + 1
    argv' <- pure argv
    tagTokParent <- case argv of
      (a0:_) -> pure a0
      []     -> constI 0
    tagTokChild <- mkChildTag k tagTokParent
    argvTagged <-
      mapM (mkChildTag k) argv'
    callOuts <- forM (zip [0..] argvTagged) $ \(i,a) -> do
      let slot = i + 1
      cs <- newNode (f ++ "#" ++ show slot) (NCallSnd (f ++ "#" ++ show slot) tid cg)
      connectPlus a   (InstPort cs "0")
      connectPlus tagTokChild (InstPort cs "1")
      ap <- argNode f slot
      case ap of
        InstPort nid _ -> connectPlus (out0 cs) (InstPort nid "0")
        _              -> pure ()
      pure (out0 cs)

    rs <- newNode (f ++ "#0") (NRetSnd (f ++ "#0") tid cg)
    connectPlus tagTokChild (InstPort rs "1")

    retN <- retNodeId f
    connectPlus tagTokChild (InstPort rs "0")
    let rsTag = out0 rs
    connectPlus rsTag (InstPort retN "1")
    mres <- lookupRetVal f
    resOut <- case mres of
      Just res -> do
        r <- retagTo rsTag res
        connectPlus r (InstPort retN "0")
        mkParentTag r
      Nothing -> do
        z <- constFrom rsTag 0
        connectPlus z (InstPort retN "0")
        mkParentTag z
    pure resOut

  Lambda ps body -> do
    let fname = "lambda"
        tid   = funTaskId fname
    argv0 <- mapM goExpr args
    argv1 <- mapM guardIfNeeded argv0
    argv <- alignExecInputs argv1
    cg <- newNode fname (NCallGroup fname)
    tagTok <- case argv of
      (a0:_) -> pure a0
      []     -> constI 0
    _callOuts <- forM (zip [0..] argv) $ \(i,a) -> do
      let slot = i + 1
      cs <- newNode (fname ++ "#" ++ show slot) (NCallSnd (fname ++ "#" ++ show slot) tid cg)
      connectPlus a   (InstPort cs "0")
      connectPlus tagTok (InstPort cs "1")
      pure (out0 cs)
    rs <- newNode (fname ++ "#0") (NRetSnd (fname ++ "#0") tid cg)
    connectPlus tagTok (InstPort rs "1")
    res <- withEnv $ do
             forM_ (zip3 [0..] ps argv) $ \(i,v,p) -> bindFormal fname i v p
             goExpr body
    connectPlus tagTok (InstPort rs "0")
    pure res

  _ -> do
    _ <- mapM goExpr args
    case args of
      [] -> constI 0
      _  -> goExpr (last args)

-- Literais -------------------------------------------------------------

-- | Build a constant for a 'Literal'.
litNode :: Literal -> Build Port
litNode = \case
  LInt n    -> constI n
  LFloat d  -> newNode "fconst" (NConstF "" (realToFrac d)) >>= \nid -> pure (out0 nid)
  LChar c   -> constI (fromEnum c)
  LString _ -> constI 0
  LBool b   -> constI (if b then 1 else 0)

-- Helpers --------------------------------------------------------------

-- | Convenience for a binary operation node, returning its output port.
bin2 :: String -> DNode -> Port -> Port -> Build Port
bin2 _lbl nd a b = out0 <$> bin2Node "b2" nd a b

-- | Build a binary operation node, returning its 'NodeId'.
bin2Node :: String -> DNode -> Port -> Port -> Build NodeId
bin2Node lbl nd a b = do
  ma <- getConstI a
  mb <- getConstI b
  a' <- case (ma, mb) of
          (Just k, Nothing) -> constFrom b k
          _                 -> pure a
  b' <- case (ma, mb) of
          (Nothing, Just k) -> constFrom a k
          _                 -> pure b
  ins <- alignExecInputs [a', b']
  let (a1,b1) = case ins of { [x,y] -> (x,y); _ -> (a',b') }
  nid <- newNode lbl nd
  connectPlus a1 (InstPort nid "0")
  connectPlus b1 (InstPort nid "1")
  pure nid

-- | Logical NOT implemented as equality with zero.
notP :: Port -> Build Port
notP x = do z <- constFrom x 0; bin2 "equal" (NEqual "") x z

-- | Normalize a boolean-like value to 0/1.
boolify :: Port -> Build Port
boolify x = do
  z <- constFrom x 0
  bin2 "gthan" (NGThan "") x z

-- | Logical OR implemented as @(a+b) > 0@.
orP :: Port -> Port -> Build Port
orP a b = do
  ins <- alignExecInputs [a, b]
  case ins of
    [a', b'] -> do
      s <- bin2Node "add" (NAdd "") a' b'
      z <- constFrom (out0 s) 0
      bin2 "gthan" (NGThan "") (out0 s) z
    _ -> do
      s <- bin2Node "add" (NAdd "") a b
      z <- constFrom (out0 s) 0
      bin2 "gthan" (NGThan "") (out0 s) z

-- | Logical AND using bitwise-and node.
andP :: Port -> Port -> Build Port
andP a b = do
  ins <- alignExecInputs [a, b]
  case ins of
    [a', b'] -> bin2 "band" (NBand "") a' b'
    _        -> bin2 "band" (NBand "") a b

-- | Boolean constants (1/0).
trueP, falseP :: Build Port
trueP  = constI 1
falseP = constI 0

-- CASE / Pattern matching ----------------------------------------------

-- | Compile a @case@ by building guards and steering results.
compileCase :: Expr -> [(Pattern, Expr)] -> Build Port
compileCase scr alts = do
  pscr <- goExpr scr
  case alts of
    [(p,e)] | patAlwaysTrue p -> do
      (_pp, binds) <- patPred pscr p
      withEnv $ do
        mapM_ (\(x,v) -> insertB x (BPort v)) binds
        goExpr e
    _ -> do
      taken0 <- constFrom pscr 0
      outs <- goAlts pscr taken0 alts []
      case outs of
        []       -> falseP
        (h:rest) -> registerAlias h rest >> pure h
  where
    patAlwaysTrue = \case
      PVar{}      -> True
      PWildcard   -> True
      PTuple [_,_] -> True
      _           -> False
    -- Última alternativa: NÃO compute orP/taken' (evita nó morto).
    goAlts _    _     []              acc = pure (reverse acc)
    goAlts pscr taken [(p,e)]         acc = do
      (pPred, binds, guardi) <- withNoGuard $ do
        (pp0, bs) <- patPred pscr p
        pp <- boolify pp0
        pp' <- alignExecTo taken pp
        nt  <- notP taken
        nt' <- alignExecTo pp' nt
        g   <- andP pp' nt'
        pure (pp', bs, g)
      val0 <- withEnv $ withGuard guardi $ do
               mapM_ (\(x,v) -> insertB x (BPort v)) binds
               goExpr e
      val <- alignExecTo guardi val0
      tok <- guardToken guardi
      sid <- newNode "steer" (NSteer "")
      connect tok (InstPort sid "0")
      connect val (InstPort sid "1")
      let out = SteerPort sid "t"
      pure (reverse (out:acc))

    -- Alternativas intermediárias: mantém o cálculo de taken'
    goAlts pscr taken ((p,e):rs)     acc = do
      (pPred, binds, guardi, taken') <- withNoGuard $ do
        (pp0, bs) <- patPred pscr p
        pp <- boolify pp0
        pp' <- alignExecTo taken pp
        nt  <- notP taken
        nt' <- alignExecTo pp' nt
        g   <- andP pp' nt'
        tk  <- orP taken pp'
        pure (pp', bs, g, tk)
      val0 <- withEnv $ withGuard guardi $ do
               mapM_ (\(x,v) -> insertB x (BPort v)) binds
               goExpr e
      val <- alignExecTo guardi val0
      tok <- guardToken guardi
      sid <- newNode "steer" (NSteer "")
      connect tok (InstPort sid "0")
      connect val (InstPort sid "1")
      let out = SteerPort sid "t"
      goAlts pscr taken' rs (out:acc)

-- | Build the predicate and bindings for matching a 'Pattern' against a scrutinee port.
patPred :: Port -> Pattern -> Build (Port, [(Ident, Port)])
patPred scr = \case
  PTuple [p1,p2] -> do
    a <- fstDec scr; b <- sndDec scr; t <- constFrom scr 1
    pure (t, bindIfVar p1 a ++ bindIfVar p2 b)
  PList [] -> do
    p <- isNilP scr; pure (p, [])
  -- Treat singleton list patterns as a cons with empty tail for consistent
  -- guard construction and binding behavior.
  PList [p] -> patPred scr (PCons p (PList []))
  PCons ph pt -> do
    nz <- notP =<< isNilP scr
    hd <- fstDec scr
    tl <- sndDec scr
    (pH, bH) <- patPred hd ph
    (pT, bT) <- patPred tl pt
    g1 <- andP nz pH
    g2 <- andP g1 pT
    pure (g2, bH ++ bT)
  PWildcard -> do t <- constFrom scr 1; pure (t, [])
  PVar x    -> do t <- constFrom scr 1; pure (t, [(x, scr)])
  PLit lit  -> do litP <- litNodeFrom scr lit
                  eq   <- bin2 "equal" (NEqual "") scr litP
                  pure (eq, [])
  _         -> do t <- constFrom scr 1; pure (t, [])

-- | Literal helper aligned to a reference port's exec.
litNodeFrom :: Port -> Literal -> Build Port
litNodeFrom ref = \case
  LInt n    -> constFrom ref n
  LChar c   -> constFrom ref (fromEnum c)
  LBool b   -> constFrom ref (if b then 1 else 0)
  LString _ -> constFrom ref 0
  LFloat d  -> newNode "fconst" (NConstF "" (realToFrac d)) >>= \nid -> pure (out0 nid)

-- | Bind @x@ if the pattern is 'PVar'; otherwise no bindings.
bindIfVar :: Pattern -> Port -> [(Ident, Port)]
bindIfVar (PVar x) p = [(x,p)]
bindIfVar _        _ = []

-- | Literal helper that defers to 'litNode'.
litNode' :: Literal -> Build Port
litNode' = litNode
