{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Unique
-- Description : Generation of fresh (unique) integers in pure and monadic code.
-- Copyright   : (c) 2025
-- License     :
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- This module provides a small utility to generate fresh, monotonically
-- increasing integers:
--
--   * 'UniqueT' — a monad transformer that threads an @Int@ counter.
--   * 'MonadUnique' — a class for monads that can produce fresh IDs.
--   * 'Unique' — a pure ('State')-based variant.
--
-- The counter starts at 0 for all @run*@ functions in this module.
--
-- === Examples
--
-- Pure:
--
-- >>> import Control.Monad.State (runState)
-- >>> let x = do a <- freshId; b <- freshId; pure (a,b) :: Unique (Int,Int)
-- >>> runUnique x
-- ((0,1),2)
--
-- With 'UniqueT' over 'IO':
--
-- >>> :{
-- let prog :: UniqueT IO (Int,Int)
--     prog = do a <- freshId; b <- freshId; pure (a,b)
-- :}
-- >>> evalUniqueT prog
-- (0,1)
--
module Unique
  ( -- * Transformer
    UniqueT, runUniqueT, evalUniqueT
    -- * Utility class
  , MonadUnique(..)
    -- * Pure version
  , Unique, runUnique, evalUnique
  ) where

----------------------------------------------------------------------
-- imports
----------------------------------------------------------------------
import           Control.Monad.State (State, StateT, get, put, evalState, evalStateT)
import qualified Control.Monad.State as S
import           Control.Monad.Trans (MonadTrans, lift)
import           Control.Monad.Reader (ReaderT)
import           Control.Monad.Writer (WriterT)
import           Control.Monad.Except (ExceptT)
import           Data.Monoid (Monoid)

----------------------------------------------------------------------
-- Transformer
----------------------------------------------------------------------

-- | A monad transformer that carries a fresh-identifier counter.
--
-- The internal state is an 'Int' starting at 0 when run via 'runUniqueT'.
newtype UniqueT m a = UniqueT { unUniqueT :: StateT Int m a }
  deriving (Functor, Applicative, Monad, MonadTrans)

-- | Run a 'UniqueT' computation, returning the result and the final counter.
--
-- The initial counter is @0@.
runUniqueT :: UniqueT m a -> m (a, Int)
runUniqueT (UniqueT m) = S.runStateT m 0

-- | Run and discard the final counter, returning only the result.
evalUniqueT :: Monad m => UniqueT m a -> m a
evalUniqueT = fmap fst . runUniqueT

----------------------------------------------------------------------
-- Class
----------------------------------------------------------------------

-- | Monads that can produce fresh (unique) integers.
class Monad m => MonadUnique m where
  -- | Produce the next fresh integer.
  freshId  :: m Int
  -- | Produce @n@ fresh integers (default implementation).
  freshIds :: Int -> m [Int]
  freshIds n = sequence (replicate n freshId)

-- | 'MonadUnique' instance for 'UniqueT'.
instance Monad m => MonadUnique (UniqueT m) where
  freshId = UniqueT $ do
    n <- get
    put (n + 1)
    pure n

-- | Lift 'freshId' through common monad transformers.
instance MonadUnique m => MonadUnique (ReaderT r m) where
  freshId = lift freshId

instance (Monoid w, MonadUnique m) => MonadUnique (WriterT w m) where
  freshId = lift freshId

instance MonadUnique m => MonadUnique (ExceptT e m) where
  freshId = lift freshId

----------------------------------------------------------------------
-- Pure version
----------------------------------------------------------------------

-- | A pure alias using 'State' to carry the counter.
type Unique = State Int

-- | Run a pure 'Unique' computation, returning the result and final counter.
--
-- The initial counter is @0@.
runUnique :: Unique a -> (a, Int)
runUnique m = S.runState m 0

-- | Evaluate a pure 'Unique' computation, discarding the final counter.
evalUnique :: Unique a -> a
evalUnique = evalState <*> pure 0

-- | 'MonadUnique' instance for the pure 'Unique' monad.
instance MonadUnique Unique where
  freshId = do
    n <- get
    put (n + 1)
    pure n
