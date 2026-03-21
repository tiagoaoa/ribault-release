{-# LANGUAGE RecordWildCards #-}

-- |
-- Module      : Port
-- Description : Node port abstractions (akin to the C-compiler's SteerPort / InstPort).
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Provides typed ports for nodes and helpers to build edges safely.

module Port
  ( -- * Types
    Port(..)
  , portNode          -- extract the NodeId
  , portId            -- extract the port name

    -- * Connectors
  , (-->), edge
  ) where

import           Types  (NodeId, PortId, Edge)

--------------------------------------------------------------------------------
-- Internal port
--------------------------------------------------------------------------------

-- | “Node output” or “connection point” as used in GraphViz.
data Port
  = InstPort  { pNode :: !NodeId, pName :: !PortId }   -- ^ generic port
  | SteerPort { pNode :: !NodeId, pName :: !PortId }   -- ^ \"t\" / \"f\"
  deriving (Eq, Ord, Show)

-- | Extract the 'NodeId'.
portNode :: Port -> NodeId
portNode = pNode

-- | Extract the port name.
portId :: Port -> PortId
portId = pName

--------------------------------------------------------------------------------
-- Edge construction
--------------------------------------------------------------------------------

infixr 1 -->
-- | Syntactic sugar: @a --> b@ builds an edge 'out → in'.
(--> ) :: Port            -- ^ source
       -> Port            -- ^ target
       -> Edge
a --> b = ( portNode a, portId a
          , portNode b, portId b )

-- | Build an edge by explicitly specifying all port names.
edge :: NodeId -> PortId -> NodeId -> PortId -> Edge
edge = (,,,)
