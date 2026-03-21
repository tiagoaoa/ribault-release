{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Synthesis.Codegen
-- Description : Assemble a 'DGraph' of 'DNode's into TALM/FL textual instructions.
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Translates a dataflow graph into a linear sequence of FL instructions
-- (TALM runtime). The pass builds an input map per node (collecting sources
-- per destination port), then emits node-by-node instructions in a stable
-- order (sorted by 'NodeId'). Helpers produce canonical names for node
-- outputs and tags, and format operand lists.

module Synthesis.Codegen (assemble, assembleWithMap) where

import qualified Data.Map.Strict as M
import           Data.List       (sortOn, partition, nub)
import           Data.Char       (isDigit)
import qualified Data.Text       as T

import           Types           (DGraph(..), NodeId)
import           Node            (DNode(..))
import           Port            (Port(..))

----------------------------------------------------------------
-- Utilities
----------------------------------------------------------------
showT :: Show a => a -> T.Text
showT = T.pack . show

dstN, dstS :: NodeId -> T.Text
dstN nid = "n" <> showT nid
dstS nid = "s" <> showT nid

-- tag   ----------------------------------------------------------------
-- Use globally unique callgroup tags to avoid collisions in the preprocessor.
tagName :: NodeId -> T.Text
tagName nid = "cg" <> showT nid

-- "fun#i" -> "fun[i]"
argAsFunSlot :: String -> T.Text
argAsFunSlot nm =
  case break (=='#') nm of
    (f,'#':ix) | all isDigit ix -> T.pack f <> "[" <> T.pack ix <> "]"
    _                           -> T.pack nm

-- Output name to use as a source
outName :: DGraph DNode -> NodeId -> String -> T.Text
outName g s sp =
  case M.lookup s (dgNodes g) of
    -- steer: t -> .w / f -> .g (TALM preprocessor maps .g->.0, .w->.1)
    Just NSteer{} ->
      dstS s <> "." <> case sp of
                         "t" -> "w"
                         "f" -> "g"
                         _   -> T.pack sp
    Just n ->
      case n of
        NRetSnd{..} -> dstN s
        NCallSnd{..} -> argAsFunSlot nName
        NRet{..}    -> T.pack nName <> "." <> T.pack sp
        NDiv{}      -> if sp=="0" then dstN s else dstN s <> ".1"
        NDivI{}     -> if sp=="0" then dstN s else dstN s <> ".1"
        NCommit{}   -> if sp=="0" then dstN s else dstN s <> ".1"
        NStopSpec{} -> if sp=="0" then dstN s else dstN s <> ".1"
        _           -> dstN s
    Nothing -> dstN s

fmtOp :: [T.Text] -> T.Text
fmtOp []  = "z0"
fmtOp [x] = x
fmtOp xs  = "[" <> T.intercalate ", " xs <> "]"

----------------------------------------------------------------
-- Build input map
----------------------------------------------------------------
buildInputs :: DGraph DNode -> M.Map (NodeId,String) [T.Text]
buildInputs g =
  let step m (s,sp,d,dp) =
        let src = outName g s sp
        in M.insertWith (++) (d,dp) [src] m
  in M.map nub (foldl step M.empty (dgEdges g))

buildPreds :: DGraph DNode -> M.Map (NodeId,String) [NodeId]
buildPreds g =
  let step m (s,_sp,d,dp) = M.insertWith (++) (d,dp) [s] m
  in foldl step M.empty (dgEdges g)

lookupPreds :: M.Map (NodeId,String) [NodeId] -> NodeId -> String -> [NodeId]
lookupPreds preds nid port = M.findWithDefault [] (nid, port) preds

parseNodeId :: T.Text -> Maybe NodeId
parseNodeId t =
  case T.uncons t of
    Just ('n', rest) | not (T.null rest) ->
      case reads (T.unpack rest) of
        [(n,"")] -> Just n
        _        -> Nothing
    _ -> Nothing

callgroupForRetSnd :: DGraph DNode -> M.Map (NodeId,String) [NodeId] -> NodeId -> Maybe NodeId
callgroupForRetSnd g _preds rs =
  case M.lookup rs (dgNodes g) of
    Just NRetSnd{..} -> Just cgId
    _                -> Nothing

callgroupForValTag :: DGraph DNode -> M.Map (NodeId,String) [NodeId] -> NodeId -> Maybe NodeId
callgroupForValTag g preds vt =
  case lookupPreds preds vt "1" of
    (tv:_) ->
      case lookupPreds preds tv "0" of
        (rs:_) -> callgroupForRetSnd g preds rs
        _      -> Nothing
    _ -> Nothing

sortByCallgroup
  :: (NodeId -> Maybe NodeId)
  -> [T.Text]
  -> [T.Text]
sortByCallgroup cgOf srcs =
  let withKey = [ (cg, s)
                | s <- srcs
                , Just nid <- [parseNodeId s]
                , Just cg  <- [cgOf nid]
                ]
      without = [ s
                | s <- srcs
                , case parseNodeId s of
                    Nothing  -> True
                    Just nid -> case cgOf nid of
                                  Nothing -> True
                                  Just _  -> False
                ]
  in map snd (sortOn fst withKey) ++ without

orderedPins :: M.Map (NodeId,String) [T.Text] -> NodeId -> [String]
orderedPins im k = [ p | (n,p) <- M.keys im, n==k ]

----------------------------------------------------------------
-- Per-node emission
----------------------------------------------------------------
emitNode
  :: DGraph DNode
  -> M.Map (NodeId,String) [T.Text]
  -> (NodeId, DNode)
  -> [T.Text]
emitNode g im (nid, dn) =
  case dn of
    -------------------------------------------------- Constants
    NConstI{..} -> ["const "  <> dstN nid <> ", " <> showT cInt]
    NConstF{..} -> ["fconst " <> dstN nid <> ", " <> showT cFloat]
    NConstD{..} -> ["dconst " <> dstN nid <> ", " <> showT cDouble]

    -------------------------------------------------- Binary ALU
    NAdd{}  -> bin2 "add"
    NSub{}  -> bin2 "sub"
    NMul{}  -> bin2 "mul"
    NDiv{}  -> ["div "  <> dstN nid <> ", " <> fmtOp (gi "0") <> ", " <> fmtOp (gi "1")]
    NFAdd{} -> bin2 "fadd"
    NFSub{} -> bin2 "fsub"
    NFMul{} -> bin2 "fmul"
    NFDiv{} -> bin2 "fdiv"
    NDAdd{} -> bin2 "dadd"
    NBand{} -> bin2 "band"

    -------------------------------------------------- Immediate ALU
    NAddI{..}  -> bin1imm "addi"  (showT iImm)
    NSubI{..}  -> bin1imm "subi"  (showT iImm)
    NMulI{..}  -> bin1imm "muli"  (showT iImm)
    NFMulI{..} -> bin1imm "fmuli" (showT fImm)
    NDivI{..}  -> ["divi " <> dstN nid <> ", "
                          <> fmtOp (gi "0") <> ", " <> showT iImm]

    -------------------------------------------------- Comparisons / steer
    NLThan{}    -> bin2 "lthan"
    NGThan{}    -> bin2 "gthan"
    NEqual{}    -> bin2 "equal"
    NLThanI{..} -> bin1imm "lthani" (showT iImm)
    NGThanI{..} -> bin1imm "gthani" (showT iImm)
    NSteer{}    -> ["steer " <> dstS nid <> ", "
                           <> fmtOp (gi "0") <> ", " <> fmtOp (gi "1")]

    -------------------------------------------------- TALM runtime
    NCallGroup{..} ->
      [ "callgroup(\"" <> tagName nid <> "\",\"" <> T.pack nName <> "\")" ]

    NCallSnd{..} ->
      let src0   = fmtOp (gi "0")
          tagSrc = fmtOp (gi "1")
      in  [ "callsnd " <> argAsFunSlot nName
            <> ", " <> src0 <> ", " <> tagSrc <> ", " <> showT taskId ]

    NRetSnd{..} ->
      let src0   = fmtOp (gi "0")
          tagSrc = fmtOp (gi "1")
          cgTag  = tagName cgId
      in  [ "retsnd " <> dstN nid <> ", " <> src0 <> ", " <> tagSrc <> ", " <> cgTag ]

    NRet{..} ->
      let preds = buildPreds g
          src0s = sortByCallgroup (callgroupForValTag g preds) (gi "0")
          src0  = fmtOp src0s
          src1  = fmtOp (gi "1")
      in  [ "ret " <> T.pack nName <> ", " <> src0 <> ", " <> src1 ]

    -------------------------------------------------- tag/val
    NTagVal{} -> one1 "tagval"
    NValTag{} -> bin2 "valtag"
    NIncTag{} -> one1 "inctag"
    NIncTagI{..} -> bin1imm "inctagi" (showT iImm)

    -------------------------------------------------- DMA / spec
    NCpHToDev{}  -> ["cphtodev " <> dstN nid <> ", 0"]
    NCpDevToH{}  -> ["cpdevtoh " <> dstN nid <> ", 0"]

    -------------------------------------------------- commit / stopspec
    NCommit{}   -> multi "commit"
    NStopSpec{} -> multi "stopspec"

    -------------------------------------------------- Formal arg
    NArg{} -> ["addi " <> dstN nid <> ", " <> fmtOp (gi "0") <> ", 0"]

    -------------------------------------------------- Super-instruction
    NSuper{..} ->
      let pins = orderedPins im nid
          srcs = map (\p -> fmtOp (gi p)) pins
          base = case (superSpec, superImm) of
                   (False, Nothing) -> "super"
                   (True , Nothing) -> "specsuper"
                   (False, Just _)  -> "superi"
                   (True , Just _)  -> "specsuperi"
          imm  = maybe [] (\t -> [showT t]) superImm
      in  [ T.intercalate ", " $
              (T.pack base <> " " <> dstN nid)
              : [ showT superNum
                , showT (max 1 superOuts)
                ]
              ++ srcs ++ imm
          ]
  where
    gi  p     = M.findWithDefault [] (nid,p) im
    bin2 mnem = [ T.pack mnem <> " " <> dstN nid <> ", "
                              <> fmtOp (gi "0") <> ", " <> fmtOp (gi "1") ]
    bin1imm m immTxt =
      [ T.pack m <> " " <> dstN nid <> ", " <> fmtOp (gi "0") <> ", " <> immTxt ]
    one1 mnem  = [ T.pack mnem <> " " <> dstN nid <> ", " <> fmtOp (gi "0") ]
    multi base =
      let pins = orderedPins im nid
          srcs = map (\p -> fmtOp (gi p)) pins
      in  [ T.pack base <> " " <> T.intercalate ", " (dstN nid : srcs) ]

----------------------------------------------------------------
-- assemble : input = graph; output = .fl text
----------------------------------------------------------------
assemble :: DGraph DNode -> T.Text
assemble g =
  T.unlines $ "const z0, 0" : concatMap (emitNode g inMap) ordered
  where
    nodes = sortOn fst (M.toList (dgNodes g))
    inMap = buildInputs g
    (cgs, rest) = partition isCallGroup nodes
    ordered = cgs ++ rest
    isCallGroup (_, NCallGroup{}) = True
    isCallGroup _ = False

-- | Assemble and return a mapping from instruction index to node metadata.
-- The index matches the assembler's instruction IDs (callgroup macros excluded).
assembleWithMap :: DGraph DNode -> (T.Text, [(Int, NodeId, DNode, T.Text)])
assembleWithMap g =
  let nodes = sortOn fst (M.toList (dgNodes g))
      inMap = buildInputs g
      (cgs, rest) = partition isCallGroup nodes
      ordered = cgs ++ rest
      emitted = concatMap (\(nid, dn) -> map (\l -> (nid, dn, l)) (emitNode g inMap (nid, dn))) ordered
      asmLines = "const z0, 0" : map (\(_,_,l) -> l) emitted
      asmText  = T.unlines asmLines
      isMacroLine l = "callgroup(" `T.isPrefixOf` l
      instrLines = (0, 0, NConstI "" 0, "const z0, 0") :
                   [ (i, nid, dn, l)
                   | (i, (nid, dn, l)) <- zip [1..] (filter (not . isMacroLine . (\(_,_,l)->l)) emitted)
                   ]
  in (asmText, instrLines)
  where
    isCallGroup (_, NCallGroup{}) = True
    isCallGroup _ = False
