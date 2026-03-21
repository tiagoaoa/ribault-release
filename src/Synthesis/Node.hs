{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE LambdaCase #-}

-- |
-- Module      : Node
-- Description : Dataflow nodes (mirroring TALM-like mnemonics) and port helpers.
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Defines the set of dataflow node constructors used by the builder/codegen
-- stages and utilities to query node names, arity, and standard output ports.

module Node
  ( DNode(..)
  , nodeName
  , nOutputs
  , outPort, out1Port, truePort, falsePort
  ) where

import           Types (NodeId)
import           Port  (Port(..))

-- | Dataflow node (mirrors assembler mnemonics).
data DNode
  -- Constants
  = NConstI  { nName :: !String, cInt    :: !Int    }
  | NConstF  { nName :: !String, cFloat  :: !Float  }
  | NConstD  { nName :: !String, cDouble :: !Double }

  -- Binary ALU
  | NAdd     { nName :: !String }
  | NSub     { nName :: !String }
  | NMul     { nName :: !String }
  | NDiv     { nName :: !String }      -- ^ 2 outputs
  | NFAdd    { nName :: !String }
  | NDAdd    { nName :: !String }
  | NBand    { nName :: !String }
  | NFSub    { nName :: !String }      -- ^ new
  | NFMul    { nName :: !String }      -- ^ new
  | NFDiv    { nName :: !String }      -- ^ new

  -- Immediate ALU
  | NAddI    { nName :: !String, iImm :: !Int }
  | NSubI    { nName :: !String, iImm :: !Int }
  | NMulI    { nName :: !String, iImm :: !Int }
  | NFMulI   { nName :: !String, fImm :: !Float }
  | NDivI    { nName :: !String, iImm :: !Int }  -- ^ 2 outputs

  -- Comparisons / steer
  | NLThan   { nName :: !String }
  | NGThan   { nName :: !String }
  | NEqual   { nName :: !String }
  | NLThanI  { nName :: !String, iImm :: !Int }
  | NGThanI  { nName :: !String, iImm :: !Int }
  | NSteer   { nName :: !String }                -- ^ ports \"t\" / \"f\"

  -- Calls (TALM)
  | NCallGroup { nName :: !String }              -- ^ emits a tag
  | NCallSnd   { nName :: !String, taskId :: !Int, cgId :: !NodeId }
  | NRetSnd    { nName :: !String, taskId :: !Int, cgId :: !NodeId }
  | NRet       { nName :: !String }

  -- Converters tag <-> value
  | NTagVal  { nName :: !String }
  | NValTag  { nName :: !String }
  | NIncTag  { nName :: !String }
  | NIncTagI { nName :: !String, iImm :: !Int }

  -- DMA / speculation
  | NCpHToDev  { nName :: !String }
  | NCpDevToH  { nName :: !String }
  | NCommit    { nName :: !String }             -- ^ 2 outputs
  | NStopSpec  { nName :: !String }             -- ^ 2 outputs

  -- Formal argument (visual / binding)
  | NArg       { nName :: !String }

  -- Super-instruction (opaque at this stage)
  | NSuper
      { nName      :: !String
      , superNum   :: !Int
      , superOuts  :: !Int
      , superImm   :: !(Maybe Int)
      , superSpec  :: !Bool
      }
  deriving (Eq, Show)

-- | Get the node's display/name label.
nodeName :: DNode -> String
nodeName = nName

-- | Number of outputs (arity) for a given node.
nOutputs :: DNode -> Int
nOutputs = \case
  NDiv{}      -> 2
  NDivI{}     -> 2
  NSteer{}    -> 2
  NCommit{}   -> 2
  NStopSpec{} -> 2
  NSuper{..}  -> superOuts
  _           -> 1

-- | Default primary output port \"0\".
outPort  :: NodeId -> Port
outPort  nid = InstPort nid "0"

-- | Secondary output port \"1\" (for multi-output nodes).
out1Port :: NodeId -> Port
out1Port nid = InstPort nid "1"

-- | True branch port of a 'NSteer' node.
truePort :: NodeId -> Port
truePort nid = SteerPort nid "t"

-- | False branch port of a 'NSteer' node.
falsePort :: NodeId -> Port
falsePort nid = SteerPort nid "f"
