{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}

-- |
-- Module      : Types
-- Description : Core types for the Dataflow graph generation phase.
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Core, minimal types used during dataflow graph construction.
-- Everything is kept generic in @n@ so that other modules (Node, Builder, …)
-- can choose the payload stored at each node.

module Types
  ( -- * Basic identifiers
    NodeId
  , PortId
    -- * Edges and graphs
  , Edge
  , DGraph(..)
    -- * Construction helpers
  , emptyGraph
  , addNode
  , addEdge
  ) where

import           Data.Map (Map)
import qualified Data.Map as Map

--------------------------------------------------------------------------------
-- Basic identifiers
--------------------------------------------------------------------------------

-- | Unique identifier for a node/instruction in the graph.
type NodeId = Int

-- | Port name within a node (e.g. \"out\", \"lhs\", \"rhs\", \"t\", \"f\", …).
type PortId = String

--------------------------------------------------------------------------------
-- Edges and graphs
--------------------------------------------------------------------------------

-- | Directed edge: (source node, source port, target node, target port).
type Edge = (NodeId, PortId, NodeId, PortId)

-- | Parametric graph: allows any node payload type.
data DGraph n = DGraph
  { dgNodes :: Map NodeId n   -- ^ All nodes, indexed by their 'NodeId'.
  , dgEdges :: [Edge]         -- ^ List of directed edges.
  }
  deriving (Show, Eq, Functor, Foldable, Traversable)

--------------------------------------------------------------------------------
-- Construction utilities
--------------------------------------------------------------------------------

-- | Empty graph — a suitable starting point for the 'Builder'.
emptyGraph :: DGraph n
emptyGraph = DGraph Map.empty []

-- | Insert (or replace) a node.
addNode :: NodeId -> n -> DGraph n -> DGraph n
addNode nid n g = g { dgNodes = Map.insert nid n (dgNodes g) }

-- | Add an edge (uses cons; reverse later if order matters).
addEdge :: Edge -> DGraph n -> DGraph n
addEdge e g = g { dgEdges = e : dgEdges g }
