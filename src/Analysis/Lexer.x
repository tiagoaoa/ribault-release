{
module Analysis.Lexer
  ( Token(..)
  , scanAll
  , alexMonadScan
  ) where

import Control.Monad (when)
import Data.List (stripPrefix)
}

%wrapper "monadUserState"

$white   = [\ \t\r]
$digit   = [0-9]
$alpha   = [A-Za-z]
$idchar  = [_A-Za-z0-9']

tokens :-

-- Normal mode: skip whitespace, newlines, comments
<0> $white+                         { skip }
<0> \n                              { actNewline }
<0> "--".*                          { skip }

-- Enter/leave super mode
<0>     "#BEGINSUPER"               { actBeginSuper }
<super> "#ENDSUPER"                 { actEndSuper }
<super> \n                          { actSuperAcc }
<super> .                           { actSuperAcc }

-- Keywords (normal mode only)
<0> "let"                           { actEmit TokenLet }
<0> "in"                            { actEmit TokenIn }
<0> "if"                            { actEmit TokenIf }
<0> "then"                          { actEmit TokenThen }
<0> "else"                          { actEmit TokenElse }
<0> "case"                          { actEmit TokenCase }
<0> "of"                            { actEmit TokenOf }
<0> "not"                           { actEmit TokenNot }

<0> "True"                          { actEmit (TokenBool True) }
<0> "False"                         { actEmit (TokenBool False) }

-- Operators (normal mode only)
<0> "->"                            { actEmit TokenArrow }
<0> "=="                            { actEmit TokenEq }
<0> "/="                            { actEmit TokenNeq }
<0> "<="                            { actEmit TokenLe }
<0> ">="                            { actEmit TokenGe }
<0> "<"                             { actEmit TokenLt }
<0> ">"                             { actEmit TokenGt }
<0> "&&"                            { actEmit TokenAnd }
<0> "||"                            { actEmit TokenOr }

<0> "+"                             { actEmit TokenPlus }
<0> "-"                             { actEmit TokenMinus }
<0> "*"                             { actEmit TokenTimes }
<0> "/"                             { actEmit TokenDiv }
<0> "%"                             { actEmit TokenMod }

<0> "="                             { actEmit TokenEquals }
<0> [\\]                            { actEmit TokenBackslash }
<0> "_"                             { actEmit TokenUnderscore }

-- Delimiters (normal mode only)
<0> "("                             { actEmit TokenLParen }
<0> ")"                             { actEmit TokenRParen }
<0> "["                             { actEmit TokenLBracket }
<0> "]"                             { actEmit TokenRBracket }
<0> ","                             { actEmit TokenComma }
<0> ":"                             { actEmit TokenColon }
-- NOTE: ';' is no longer a source-level separator. Layout will insert TokenSemi.
<0> ";"                             { skip }

-- Super headers (normal mode only)
<0> "super"                         { actEmit TokenSuper }
<0> "single"                        { actEmit TokenSingle }
<0> "parallel"                      { actEmit TokenParallel }
<0> "input"                         { actEmit TokenInput }
<0> "output"                        { actEmit TokenOutput }

-- Literals (normal mode only)
<0> $digit+ "." $digit+             { \i n -> actEmitLex (\s -> TokenFloat (read s)) i n }
<0> $digit+                         { \i n -> actEmitLex (\s -> TokenInt   (read s)) i n }

<0> \'[^\\\']\'                     { \i n -> actEmitLex (\s -> TokenChar   (read s)) i n }
<0> \"([^\\\"]|\\.)*\"              { \i n -> actEmitLex (\s -> TokenString (read s)) i n }

-- Identifiers (normal mode only)
<0> $alpha $idchar*                 { \i n -> actEmitLex TokenIdent i n }

-- Catch-all in normal mode: skip any remaining character
<0> .                               { skip }

{
-- ===== Tokens =====
data Token
  = TokenLet | TokenIn | TokenIf | TokenThen | TokenElse
  | TokenCase | TokenOf
  | TokenNot
  | TokenBool Bool
  | TokenSuper | TokenSingle | TokenParallel
  | TokenInput | TokenOutput
  | TokenSuperBody String
  | TokenArrow
  | TokenEq | TokenNeq | TokenLe | TokenGe | TokenLt | TokenGt
  | TokenAnd | TokenOr
  | TokenPlus | TokenMinus | TokenTimes | TokenDiv | TokenMod
  | TokenEquals
  | TokenBackslash
  | TokenUnderscore
  | TokenLParen | TokenRParen
  | TokenLBracket | TokenRBracket
  | TokenComma | TokenColon | TokenSemi
  | TokenLayoutEnd
  | TokenInt Int | TokenFloat Double | TokenChar Char | TokenString String
  | TokenIdent String
  | TokenEOF
  deriving (Eq, Show)

-- ===== User state: only super bodies =====
data AlexUserState = AlexUserState
  { stSuper   :: [Char]
  , stInSuper :: !Bool
  , stLastTok :: Maybe Token
  , stLayout  :: [(Int, Int)]  -- (indent, parenDepth)
  , stNeedLayout :: !Bool
  , stPending :: [Token]
  , stParens  :: !Int
  }

alexInitUserState :: AlexUserState
alexInitUserState = AlexUserState
  { stSuper   = []
  , stInSuper = False
  , stLastTok = Nothing
  , stLayout  = []
  , stNeedLayout = False
  , stPending = []
  , stParens  = 0
  }

-- ===== Emit helpers =====
actEmit :: Token -> AlexAction Token
actEmit t _ _ = do
  st <- alexGetUserState
  case t of
    TokenLParen -> do
      alexSetUserState st { stLastTok = Just t, stNeedLayout = False, stParens = stParens st + 1 }
      pure t
    TokenRParen -> do
      let curP = stParens st
          newP = max 0 (curP - 1)
          (pops, remaining) = popWhileDepth curP (stLayout st)
      if pops > 0 && canInsertSemi (stLastTok st)
        then do
          let pending = replicate (pops - 1) TokenLayoutEnd ++ TokenRParen : stPending st
          alexSetUserState st
            { stLastTok = Just TokenLayoutEnd
            , stLayout  = remaining
            , stPending = pending
            , stParens  = newP
            }
          pure TokenLayoutEnd
        else do
          alexSetUserState st { stLastTok = Just t, stNeedLayout = False, stParens = newP }
          pure t
    _ -> do
      let st' = case t of
            TokenOf  -> st { stLastTok = Just t, stNeedLayout = True }
            TokenLet -> st { stLastTok = Just t, stNeedLayout = True }
            _        -> st { stLastTok = Just t, stNeedLayout = False }
      alexSetUserState st'
      pure t

actEmitLex :: (String -> Token) -> AlexAction Token
actEmitLex f (_,_,_,str) n = do
  let t = f (take n str)
  st <- alexGetUserState
  alexSetUserState st { stLastTok = Just t }
  pure t

-- ===== super mode =====
actBeginSuper :: AlexAction Token
actBeginSuper _ _ = do
  alexSetStartCode super
  st <- alexGetUserState
  alexSetUserState st { stInSuper = True, stSuper = [] }
  alexMonadScan

actSuperAcc :: AlexAction Token
actSuperAcc _ n = do
  (_,_,_,str) <- alexGetInput
  st <- alexGetUserState
  alexSetUserState st { stSuper = stSuper st ++ take n str }
  alexMonadScan

actEndSuper :: AlexAction Token
actEndSuper _ _ = do
  alexSetStartCode 0
  st <- alexGetUserState
  let t = TokenSuperBody (stSuper st)
  alexSetUserState st { stInSuper = False, stLastTok = Just t }
  pure t

canInsertSemi :: Maybe Token -> Bool
canInsertSemi mt =
  case mt of
    Just (TokenIdent _) -> True
    Just (TokenInt _)   -> True
    Just (TokenFloat _) -> True
    Just (TokenChar _)  -> True
    Just (TokenString _) -> True
    Just (TokenBool _)  -> True
    Just TokenRParen    -> True
    Just TokenRBracket  -> True
    Just (TokenSuperBody _) -> True
    Just TokenSemi      -> False
    Just TokenLayoutEnd -> False
    _                   -> False

actNewline :: AlexAction Token
actNewline _ _ = do
  st <- alexGetUserState
  (_,_,_,str) <- alexGetInput
  case stNeedLayout st of
    True ->
      case peekIndent str of
        Just (ind, _) -> do
          alexSetUserState st { stNeedLayout = False, stLayout = (ind, stParens st) : stLayout st }
          alexMonadScan
        Nothing -> do
          alexSetUserState st { stNeedLayout = False }
          alexMonadScan
    False ->
      case stLayout st of
        ((ind,pd):rest) ->
          case peekIndent str of
            Just (nextInd, nextRest)
              | nextInd < ind -> do
                  let (pops, remaining) = popWhileIndent (\i -> nextInd < i) ((ind,pd) : rest)
                  let extraEnds = replicate (pops - 1) TokenLayoutEnd
                  let extraSemi = if null remaining then [TokenSemi] else []
                  let pending = extraEnds ++ extraSemi ++ stPending st
                  alexSetUserState st { stLayout = remaining, stLastTok = Just TokenLayoutEnd, stPending = pending }
                  pure TokenLayoutEnd
              | nextInd == ind ->
                  if canInsertSemi (stLastTok st) && not (isContinuationStart nextRest)
                    then do
                      alexSetUserState st { stLastTok = Just TokenSemi }
                      pure TokenSemi
                    else alexMonadScan
              | otherwise -> alexMonadScan
            Nothing -> do
              let pops = length ((ind,pd):rest)
              let pending = replicate (pops - 1) TokenLayoutEnd ++ stPending st
              alexSetUserState st { stLayout = [], stLastTok = Just TokenLayoutEnd, stPending = pending }
              pure TokenLayoutEnd
        [] ->
          if canInsertSemi (stLastTok st) && not (isContinuationStart str)
            then do
              alexSetUserState st { stLastTok = Just TokenSemi }
              pure TokenSemi
            else alexMonadScan

isContinuationStart :: String -> Bool
isContinuationStart s =
  let s' = skipJunk s
  in case s' of
      [] -> False
      '-' : '>' : _ -> True
      c : _ | c `elem` "+-*/%<>=&|:," -> True
      ')' : _ -> True
      ']' : _ -> True
      '#' : _ -> startsWithPrefix "#BEGINSUPER" s'
      _ -> startsWithKeyword "else" s'
        || startsWithKeyword "in" s'
        || startsWithKeyword "then" s'
        || startsWithKeyword "of" s'

peekIndent :: String -> Maybe (Int, String)
peekIndent s = go s
  where
    go [] = Nothing
    go xs =
      let (ind, rest) = countIndent xs
      in case rest of
          [] -> Nothing
          '\n' : ys -> go ys
          '\r' : ys -> go ys
          '-' : '-' : ys -> go (dropWhile (/= '\n') ys)
          _ -> Just (ind, rest)

countIndent :: String -> (Int, String)
countIndent s = step 0 s
  where
    step n xs =
      case xs of
        ' '  : ys -> step (n + 1) ys
        '\t' : ys -> step (n + 1) ys
        '\r' : ys -> step n ys
        _ -> (n, xs)

popWhile :: (a -> Bool) -> [a] -> (Int, [a])
popWhile p xs = go 0 xs
  where
    go n ys =
      case ys of
        (z:zs) | p z -> go (n + 1) zs
        _ -> (n, ys)

popWhileIndent :: (Int -> Bool) -> [(Int, Int)] -> (Int, [(Int, Int)])
popWhileIndent p xs = go 0 xs
  where
    go n ys =
      case ys of
        ((i, pd):zs) | p i -> go (n + 1) zs
        _ -> (n, ys)

popWhileDepth :: Int -> [(Int, Int)] -> (Int, [(Int, Int)])
popWhileDepth d xs = go 0 xs
  where
    go n ys =
      case ys of
        ((i, pd):zs) | pd == d -> go (n + 1) zs
        _ -> (n, ys)

skipJunk :: String -> String
skipJunk s =
  case s of
    [] -> []
    ' '  : xs -> skipJunk xs
    '\t' : xs -> skipJunk xs
    '\r' : xs -> skipJunk xs
    '\n' : xs -> skipJunk xs
    '-' : '-' : xs -> skipJunk (dropWhile (/= '\n') xs)
    _ -> s

startsWithKeyword :: String -> String -> Bool
startsWithKeyword kw s =
  case stripPrefix kw s of
    Just rest ->
      case rest of
        (c:_) | isIdChar c -> False
        _ -> True
    Nothing -> False

startsWithPrefix :: String -> String -> Bool
startsWithPrefix pref s =
  case stripPrefix pref s of
    Just _ -> True
    Nothing -> False

isIdChar :: Char -> Bool
isIdChar c =
  c == '_' || c == '\'' ||
  (c >= 'A' && c <= 'Z') ||
  (c >= 'a' && c <= 'z') ||
  (c >= '0' && c <= '9')

-- ===== EOF / scanAll =====

alexEOF :: Alex Token
alexEOF = pure TokenEOF

scanAll :: String -> Either String [Token]
scanAll s = runAlex s (go [])
  where
    go :: [Token] -> Alex [Token]
    go acc = do
      t <- nextToken
      case t of
        TokenEOF -> pure (reverse acc)
        _        -> go (t : acc)

nextToken :: Alex Token
nextToken = do
  st <- alexGetUserState
  case stPending st of
    (t:ts) -> do
      alexSetUserState st { stPending = ts }
      pure t
    [] -> alexMonadScan

}
