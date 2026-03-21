{-# LANGUAGE BangPatterns #-}

-- |
-- Module      : SupersProfile
-- Description : Minimal timing shim for supers (nanosecond wall time; TSV output).
-- Maintainer  : you@example.com
-- Stability   : experimental
-- Portability : portable
--
-- This module provides:
--
--   * 'withSupersTiming' — wraps a super entry point, measuring start/end
--     using @GHC.Clock.getMonotonicTimeNSec@ and appending a TSV row:
--
-- @
-- <super_name> \\t <start_ns> \\t <end_ns> \\t <duration_ns>
-- @
--
--   * Output file is taken from @SUPER_PROFILE_OUT@ (env var). If unset,
--     it defaults to @super_profile.tsv@ in the current working directory.

module SupersProfile
  ( withSupersTiming
  , superLogInit
  ) where

import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (lookupEnv)
import System.IO (hSetBuffering, BufferMode(LineBuffering), IOMode(AppendMode),
                  openFile, hClose)
import System.IO.Unsafe (unsafePerformIO)
import Control.Exception (bracket_)

-- | Resolve the log path (once) from @SUPER_PROFILE_OUT@ or default.
{-# NOINLINE superLogPath #-}
superLogPath :: FilePath
superLogPath = unsafePerformIO $ do
  m <- lookupEnv "SUPER_PROFILE_OUT"
  pure (maybe "super_profile.tsv" id m)

-- | Ensure the log file exists and is line-buffered.
{-# NOINLINE superLogInit #-}
superLogInit :: ()
superLogInit = unsafePerformIO $ do
  h <- openFile superLogPath AppendMode
  hSetBuffering h LineBuffering
  hClose h
  pure ()

-- | Wrap a super entry point to record a single timing row (TSV).
--
-- Typical use from generated code:
--
-- @
-- s1 :: Ptr Int64 -> Ptr Int64 -> IO ()
-- s1 = withSupersTiming "s1" s1_core
-- @
withSupersTiming
  :: String                 -- ^ super name (e.g., \"s1\")
  -> (a -> b -> IO ())      -- ^ the original super function
  ->  a -> b -> IO ()
withSupersTiming name f pin pout = do
  let !_ = superLogInit
  t0 <- getMonotonicTimeNSec
  f pin pout
  t1 <- getMonotonicTimeNSec
  appendFile superLogPath (name <> "\t" <> show t0 <> "\t" <> show t1 <> "\t" <> show (t1 - t0) <> "\n")
