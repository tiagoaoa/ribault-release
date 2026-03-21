{-# LANGUAGE ForeignFunctionInterface #-}

-- |
-- Module      : Synthesis.SupersEmit
-- Description : Emit a Haskell module exposing s# symbols via FFI (profile B).
-- Maintainer  : ricardofilhoschool@gmail.com
-- Stability   : experimental
-- Portability : portable
--
-- Generates the Haskell source for a module named @Supers@ that exports
-- super-instruction entry points via the FFI. Each exported symbol follows
-- “profile B”: @sN :: Ptr Int64 -> Ptr Int64 -> IO ()@, reading @in[0]@
-- and writing @out[0]@. Helpers for list encoding/decoding (compatible with
-- the Builder) are emitted alongside the supers.
module Synthesis.SupersEmit
  ( emitSupersModule  -- :: FileBase -> [SuperSpec] -> String
  ) where

import Synthesis.SuperExtract
import Data.Char (isSpace)
import Data.List (dropWhileEnd)

-- | Generate a complete Supers.hs module for a given program and its supers.
emitSupersModule :: String -> [SuperSpec] -> String
emitSupersModule baseName specs =
      let specs' = filter (\(SuperSpec nm _ _ _ _) -> nm `notElem` ["s0","s1","s2","s3"]) specs
      in unlines $
      [ "{-# LANGUAGE ForeignFunctionInterface #-}"
      , "-- Automatically generated for program: " ++ baseName
      , "module Supers where"
      , ""
      , "import Foreign.Ptr      (Ptr, IntPtr, ptrToIntPtr, intPtrToPtr)"
      , "import Foreign.Storable (peek, poke, peekElemOff, peekByteOff)"
      , "import Foreign.StablePtr (StablePtr, newStablePtr, deRefStablePtr"
      , "                        , castStablePtrToPtr, castPtrToStablePtr)"
      , "import Data.Int         (Int64)"
      , "import Data.Word        (Word32)"
      , "import Data.Bits        ((.&.))"
      , "import GHC.Conc (par, pseq)"
      , "import GHC.Float (castWord32ToFloat, castFloatToWord32)"
      , "import System.IO.Unsafe (unsafePerformIO)"
      , "import Data.IORef       (IORef, newIORef, readIORef, writeIORef)"
      , "import Control.Monad    (when)"
      , ""
      , "-- Profile B: sN :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "-- Contract: reads in[0] and writes to out[0]."
      , ""
      , "-- Encoding helpers compatible with the Builder:"
      , "pairBase :: Int64"
      , "pairBase = 0"
      , "handleNil :: Int64"
      , "handleNil = 0"
      , ""
      , "nil :: Int64"
      , "nil = handleNil"
      , ""
      , "handleFromStable :: StablePtr (Int64, Int64) -> Int64"
      , "handleFromStable sp = fromIntegral (ptrToIntPtr (castStablePtrToPtr sp))"
      , ""
      , "stableFromHandle :: Int64 -> StablePtr (Int64, Int64)"
      , "stableFromHandle h = castPtrToStablePtr (intPtrToPtr (fromIntegral h))"
      , ""
      , "readPairIO :: Int64 -> IO (Int64, Int64)"
      , "readPairIO h = deRefStablePtr (stableFromHandle h)"
      , ""
      , "mkPairIO :: Int64 -> Int64 -> IO Int64"
      , "mkPairIO a b = do sp <- newStablePtr (a, b); pure (handleFromStable sp)"
      , ""
      , "toListIO :: Int64 -> IO [Int64]"
      , "toListIO h"
      , "  | h == handleNil = pure []"
      , "  | otherwise = do"
      , "      (a, b) <- readPairIO h"
      , "      xs <- toListIO b"
      , "      pure (a : xs)"
      , ""
      , "fromListIO :: [Int64] -> IO Int64"
      , "fromListIO [] = pure handleNil"
      , "fromListIO (a:xs) = do"
      , "  b <- fromListIO xs"
      , "  mkPairIO a b"
      , ""
      , "toList :: Int64 -> [Int64]"
      , "{-# NOINLINE toList #-}"
      , "toList h = unsafePerformIO (toListIO h)"
      , ""
      , "fromList :: [Int64] -> Int64"
      , "{-# NOINLINE fromList #-}"
      , "fromList xs = unsafePerformIO (fromListIO xs)"
      , ""
      , "-- Float helpers (list elements may carry float bits in low 32 bits):"
      , "toFloat :: Int64 -> Float"
      , "{-# NOINLINE toFloat #-}"
      , "toFloat x = castWord32ToFloat (fromIntegral (x .&. 0xffffffff))"
      , ""
      , "fromFloat :: Float -> Int64"
      , "{-# NOINLINE fromFloat #-}"
      , "fromFloat f = fromIntegral (castFloatToWord32 f)"
      , ""
      , "toListF :: Int64 -> [Float]"
      , "{-# NOINLINE toListF #-}"
      , "toListF h = map toFloat (toList h)"
      , ""
      , "fromListF :: [Float] -> Int64"
      , "{-# NOINLINE fromListF #-}"
      , "fromListF xs = fromList (map fromFloat xs)"
      , ""
      , "-- C-list helpers (compatible with DF_LIST_BUILTIN=1 encoding):"
      , "-- df_list_cell_t is {int64_t head; int64_t tail;} = 16 bytes, nil=0"
      , "foreign import ccall \"df_list_cons\" c_df_list_cons :: Int64 -> Int64 -> IO Int64"
      , ""
      , "clistToHListIO :: Int64 -> IO [Int64]"
      , "clistToHListIO 0 = pure []"
      , "clistToHListIO h = do"
      , "  let p = intPtrToPtr (fromIntegral h)"
      , "  hd <- peekByteOff p 0 :: IO Int64"
      , "  tl <- peekByteOff p 8 :: IO Int64"
      , "  rest <- clistToHListIO tl"
      , "  pure (hd : rest)"
      , ""
      , "hlistToCListIO :: [Int64] -> IO Int64"
      , "hlistToCListIO [] = pure 0"
      , "hlistToCListIO (x:xs) = do"
      , "  tl <- hlistToCListIO xs"
      , "  c_df_list_cons x tl"
      , ""
      , "ctoList :: Int64 -> [Int64]"
      , "{-# NOINLINE ctoList #-}"
      , "ctoList h = unsafePerformIO (clistToHListIO h)"
      , ""
      , "cfromList :: [Int64] -> Int64"
      , "{-# NOINLINE cfromList #-}"
      , "cfromList xs = unsafePerformIO (hlistToCListIO xs)"
      , ""
      , "-- Compatibility helpers for older supers bodies:"
      , "encPair :: Int64 -> Int64 -> Int64"
      , "{-# NOINLINE encPair #-}"
      , "encPair a b = unsafePerformIO (mkPairIO a b)"
      , ""
      , "fstDec :: Int64 -> Int64"
      , "{-# NOINLINE fstDec #-}"
      , "fstDec h = unsafePerformIO (if h == handleNil then pure 0 else fst <$> readPairIO h)"
      , ""
      , "sndDec :: Int64 -> Int64"
      , "{-# NOINLINE sndDec #-}"
      , "sndDec h = unsafePerformIO (if h == handleNil then pure 0 else snd <$> readPairIO h)"
      , ""
      , "-- Builtins: s0..s3 reserved for list ops"
      , "foreign export ccall \"s0\" s0 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s0 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s0 pin pout = do"
      , "  a <- peekElemOff pin 0"
      , "  b <- peekElemOff pin 1"
      , "  h <- mkPairIO a b"
      , "  poke pout h"
      , ""
      , "foreign export ccall \"s1\" s1 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s1 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s1 pin pout = do"
      , "  h <- peek pin"
      , "  if h == handleNil"
      , "    then poke pout 0"
      , "    else do (a, _) <- readPairIO h; poke pout a"
      , ""
      , "foreign export ccall \"s2\" s2 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s2 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s2 pin pout = do"
      , "  h <- peek pin"
      , "  if h == handleNil"
      , "    then poke pout 0"
      , "    else do (_, b) <- readPairIO h; poke pout b"
      , ""
      , "foreign export ccall \"s3\" s3 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s3 :: Ptr Int64 -> Ptr Int64 -> IO ()"
      , "s3 pin pout = do"
      , "  h <- peek pin"
      , "  if h == handleNil then poke pout 1 else poke pout 0"
      ]
      ++ concatMap emitOne specs'

-- | Emit one super (its FFI wrapper + pure @_impl@).
emitOne :: SuperSpec -> [String]
emitOne (SuperSpec nm _kind inp out bodyRaw) =
  let bodyCore = normalizeIndent (trimBlankHash bodyRaw)
  in if null bodyCore
     then
       [ ""
       , "-- " ++ nm
      , "foreign export ccall \"" ++ nm ++ "\" " ++ nm ++ " :: Ptr Int64 -> Ptr Int64 -> IO ()"
       , nm ++ " :: Ptr Int64 -> Ptr Int64 -> IO ()"
       , nm ++ " pin pout = do"
       , "  x <- peek pin"
       , "  let r = " ++ nm ++ "_impl x"
       , "  poke pout r"
       , ""
       , nm ++ "_impl :: Int64 -> Int64"
       , nm ++ "_impl _x = handleNil"
       ]
     else
       [ ""
       , "-- " ++ nm
      , "foreign export ccall \"" ++ nm ++ "\" " ++ nm ++ " :: Ptr Int64 -> Ptr Int64 -> IO ()"
       , nm ++ " :: Ptr Int64 -> Ptr Int64 -> IO ()"
       , nm ++ " pin pout = do"
       , "  x <- peek pin"
       , "  let r = " ++ nm ++ "_impl x"
       , "  poke pout r"
       , ""
       , "-- Internal pure function:"
       , "-- - decodes the Int64 input into list '" ++ inp ++ "'"
       , "-- - executes the stored body (declarations + definition of '" ++ out ++ "')"
       , "-- - encodes '" ++ out ++ "' back to Int64"
       , nm ++ "_impl :: Int64 -> Int64"
       , nm ++ "_impl " ++ inp ++ " ="
       , "  let"
       ]
       ++ indent 4 bodyCore
       ++ [ "  in " ++ out ]

----------------------------------------------------------------
-- Formatting helpers
----------------------------------------------------------------

-- | Drop blank lines at the beginning/end and drop any line whose first
-- non-space character is '#'. This removes markers like #BEGINSUPER/#ENDSUPER
-- and avoids generating invalid Haskell.
trimBlankHash :: String -> String
trimBlankHash s =
  let ls0   = lines s
      isBlank l = all isSpace l
      isHash l  =
        case dropWhile isSpace l of
          ('#':_) -> True
          _       -> False
      isIgn l   = isBlank l || isHash l
      dropBE    = dropWhile isIgn . dropWhileEnd isIgn
      ls1       = dropBE ls0
      ls2       = filter (not . isHash) ls1
  in unlines ls2

-- | Remove the minimal common indentation from all non-blank lines.
normalizeIndent :: String -> [String]
normalizeIndent s =
  let ls       = lines s
      nonblank = filter (not . all isSpace) ls
      leadSpaces l = length (takeWhile isSpace l)
      base     = case nonblank of
                   [] -> 0
                   _  -> minimum (map leadSpaces nonblank)
  in map (drop base) ls

-- | Indent every line by @n@ spaces.
indent :: Int -> [String] -> [String]
indent n ls =
  let pad = replicate n ' '
  in map (pad ++) ls
