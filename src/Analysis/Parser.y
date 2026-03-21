{  
module Analysis.Parser where

import Syntax
import Analysis.Lexer (Token(..))
}

%nonassoc   "->"
%left "||"
%left "&&"
%nonassoc "==" "/="
%nonassoc "<" "<=" ">" ">="
%left "+" "-"
%left "*" "/" "%"
%right "not" "-"
%nonassoc "in"       
%nonassoc "else"
%right ":"
%left APP   

%name parse
%tokentype { Token }
%error { parseError }

%token
  superbody     { TokenSuperBody $$ }
  ";"           { TokenSemi }
  "layout_end"  { TokenLayoutEnd }
  ":"           { TokenColon }
  "let"         { TokenLet }
  "in"          { TokenIn }
  "if"          { TokenIf }
  "then"        { TokenThen }
  "else"        { TokenElse }
  "case"        { TokenCase }
  "of"          { TokenOf }
  "not"         { TokenNot }
  "->"          { TokenArrow }
  "\\"          { TokenBackslash }
  "="           { TokenEquals }
  "_"           { TokenUnderscore }
  "("           { TokenLParen }
  ")"           { TokenRParen }
  "["           { TokenLBracket }
  "]"           { TokenRBracket }
  ","           { TokenComma }
  "+"           { TokenPlus }
  "-"           { TokenMinus }
  "*"           { TokenTimes }
  "/"           { TokenDiv }
  "%"           { TokenMod }
  "=="          { TokenEq }
  "/="          { TokenNeq }
  "<"           { TokenLt }
  "<="          { TokenLe }
  ">"           { TokenGt }
  ">="          { TokenGe }
  "&&"          { TokenAnd }
  "||"          { TokenOr }
  int           { TokenInt $$ }
  float         { TokenFloat $$ }
  char          { TokenChar $$ }
  string        { TokenString $$ }
  "True"        { TokenBool True }
  "False"       { TokenBool False }
  ident         { TokenIdent $$ }
  "super"       { TokenSuper }
  "single"      { TokenSingle }
  "parallel"    { TokenParallel }
  "input"       { TokenInput }
  "output"      { TokenOutput }

%%

Program :: { Program }
    : DeclList                      { Program (reverse $1) }

-- DeclList: declarações separadas por ';' (com trailing opcional)
DeclList :: { [Decl] }
    : Decl DeclRest                 { $1 : $2 }

DeclRest :: { [Decl] }
    :                               { [] }
    | ";"                           { [] }
    | ";" Decl DeclRest             { $2 : $3 }

Decl :: { Decl }
    : ident Params "=" Expr         { FunDecl $1 $2 $4 }

Params :: { [Ident] }
    :                               { [] }
    | ident Params                  { $1 : $2 }

Expr :: { Expr }
    : Lambda                        { $1 }
    | IfExpr                        { $1 }
    | CaseExpr                      { $1 }
    | LetExpr                       { $1 }
    | ExprOr                        { $1 }
    | Expr ":" Expr                 { Cons $1 $3 }

Lambda :: { Expr }
    : "\\" LamParams "->" Expr      { Lambda $2 $4 }

-- parâmetros de lambda: ou vários ident ou um (x1,x2,…)
LamParams :: { [Ident] }
    : Params                        { $1 }
    | "(" IdentList ")"             { $2 }

IdentList :: { [Ident] }
    : ident                         { [$1] }
    | ident "," IdentList           { $1 : $3 }

IfExpr :: { Expr }
    : "if" Expr "then" Expr "else" Expr
                                   { If $2 $4 $6 }

CaseExpr :: { Expr }
    : "case" Expr "of" Alts        { Case $2 $4 }

Alts :: { [(Pattern,Expr)] }
    : AltList LayoutEnd            { $1 }

AltList :: { [(Pattern,Expr)] }
    : Alt                          { [$1] }
    | Alt ";" AltList              { $1 : $3 }

LayoutEnd :: { () }
    : "layout_end"                 { () }


Alt :: { (Pattern,Expr) }
    : Pattern "->" Expr            { ($1,$3) }

LetExpr :: { Expr }
    : "let" DeclList DeclBlockEnd "in" Expr
                                   { Let (reverse $2) $5 }

DeclBlockEnd :: { () }
    :                               { () }
    | "layout_end"                  { () }

-- expressões binárias, sem rec. à esquerda

ExprOr :: { Expr }
    : ExprAnd OrRest               { foldl (BinOp Or) $1 $2 }
OrRest :: { [Expr] }
    :                              { [] }
    | "||" ExprAnd OrRest          { $2 : $3 }

ExprAnd :: { Expr }
    : ExprEq AndRest               { foldl (BinOp And) $1 $2 }
AndRest :: { [Expr] }
    :                              { [] }
    | "&&" ExprEq AndRest          { $2 : $3 }

ExprEq :: { Expr }
    : ExprRel EqRest               { foldl (\e1 (op,e2) -> BinOp op e1 e2) $1 $2 }
EqRest :: { [(BinOperator,Expr)] }
    :                              { [] }
    | EqOp ExprRel EqRest          { ($1,$2) : $3 }
EqOp :: { BinOperator }
    : "=="                         { Eq }
    | "/="                         { Neq }

ExprRel :: { Expr }
    : ExprAdd RelRest              { foldl (\e1 (op,e2) -> BinOp op e1 e2) $1 $2 }
RelRest :: { [(BinOperator,Expr)] }
    :                              { [] }
    | RelOp ExprAdd RelRest        { ($1,$2) : $3 }
RelOp :: { BinOperator }
    : "<"                          { Lt }
    | "<="                         { Le }
    | ">"                          { Gt }
    | ">="                         { Ge }

ExprAdd :: { Expr }
    : ExprMul AddRest              { foldl (\e1 (op,e2) -> BinOp op e1 e2) $1 $2 }
AddRest :: { [(BinOperator,Expr)] }
    :                              { [] }
    | AddOp ExprMul AddRest        { ($1,$2) : $3 }
AddOp :: { BinOperator }
    : "+"                          { Add }
    | "-"                          { Sub }

ExprMul :: { Expr }
    : ExprUnary MulRest            { foldl (\e1 (op,e2) -> BinOp op e1 e2) $1 $2 }
MulRest :: { [(BinOperator,Expr)] }
    :                              { [] }
    | MulOp ExprUnary MulRest      { ($1,$2) : $3 }
MulOp :: { BinOperator }
    : "*"                          { Mul }
    | "/"                          { Div }
    | "%"                          { Mod }

ExprUnary :: { Expr }
    : "not" ExprUnary              { UnOp Not $2 }
    | "-" ExprUnary                { UnOp Neg $2 }
    | ExprApp                      { $1 }

-- aplicação n-ária
ExprApp :: { Expr }
    : Atom AppTail  %prec APP      { foldl App $1 $2 }
AppTail :: { [Expr] }
    :                              { [] }
    | Atom AppTail                 { $1 : $2 }

Atom :: { Expr }
    : Literal                      { Lit $1 }
    | ident                        { Var $1 }
    | "(" Expr ")"                 { $2 }
    | List                         { $1 }
    | Tuple                        { $1 }
    | "super" SuperKind "input" "(" ident ")" "output" "(" ident ")" superbody
                                   { Super "" $2 $5 $9 $11 }

SuperKind :: { SuperKind }
    : "single"                     { SuperSingle }
    | "parallel"                   { SuperParallel }

Literal :: { Literal }
    : int                          { LInt $1 }
    | float                        { LFloat $1 }
    | char                         { LChar $1 }
    | string                       { LString $1 }
    | "True"                       { LBool True }
    | "False"                      { LBool False }

List :: { Expr }
    : "[" ExprListOpt "]"          { List $2 }
ExprListOpt :: { [Expr] }
    :                              { [] }
    | ExprList                     { $1 }
ExprList :: { [Expr] }
    : Expr ExprListTail            { $1 : $2 }
ExprListTail :: { [Expr] }
    :                              { [] }
    | "," Expr ExprListTail        { $2 : $3 }

Tuple :: { Expr }
    : "(" Expr "," Expr TupleTail ")"  { Tuple ($2 : $4 : $5) }

TupleTail :: { [Expr] }
    :                              { [] }
    | "," Expr TupleTail           { $2 : $3 }

-- padrões

Pattern :: { Pattern }
    : "_"                          { PWildcard }
    | ident                        { PVar $1 }
    | Literal                      { PLit $1 }
    | "(" Pattern ")"              { $2 }
    | Pattern ":" Pattern          { PCons $1 $3 }
    | ListPattern                  { $1 }
    | TuplePattern                 { $1 }

ListPattern :: { Pattern }
    : "[" PatternListOpt "]"       { PList $2 }
PatternListOpt :: { [Pattern] }
    :                              { [] }
    | PatternList                  { $1 }
PatternList :: { [Pattern] }
    : Pattern PatternListTail      { $1 : $2 }
PatternListTail :: { [Pattern] }
    :                              { [] }
    | "," Pattern PatternListTail  { $2 : $3 }

TuplePattern :: { Pattern }
    : "(" Pattern "," Pattern PatternTupleTail ")"
                                   { PTuple ($2 : $4 : $5) }
PatternTupleTail :: { [Pattern] }
    :                              { [] }
    | "," Pattern PatternTupleTail { $2 : $3 }

{
parseError :: [Token] -> a
parseError (t:_) = error ("parse error: unexpected token " ++ show t)
parseError []    = error "parse error: empty input"
}
