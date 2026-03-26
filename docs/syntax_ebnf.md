# Ribault Language Syntax (EBNF)

Formal description of the surface syntax accepted by `src/Analysis/Parser.y`
and `src/Analysis/Lexer.x`.

Notation: `{ X }` = zero or more; `[ X ]` = optional; `|` = alternatives.

## Lexical

    letter      = "A".."Z" | "a".."z" ;
    digit       = "0".."9" ;
    idchar      = letter | digit | "_" | "'" ;
    ident       = letter , { idchar } ;
    int_lit     = digit , { digit } ;
    float_lit   = digit , { digit } , "." , digit , { digit } ;
    comment     = "--" , { any char except newline } ;

## Program structure

    program     = decl_list ;
    decl_list   = decl , { decl } ;
    decl        = ident , params , "=" , expr
                | "(" , pattern , "," , pattern , ")" , "=" , expr ;
    params      = { ident } ;

Layout (indentation) delimits blocks. No semicolons.

## Expressions

    expr        = lambda | if_expr | case_expr | let_expr
                | super_expr | expr_or | expr , ":" , expr ;

    lambda      = "\" , lam_params , "->" , expr ;
    lam_params  = params | "(" , ident_list , ")" ;
    ident_list  = ident , { "," , ident } ;

    if_expr     = "if" , expr , "then" , expr , "else" , expr ;
    case_expr   = "case" , expr , "of" , alt , { alt } ;
    alt         = pattern , "->" , expr ;
    let_expr    = "let" , decl_list , "in" , expr ;

    expr_or     = expr_and , { "||" , expr_and } ;
    expr_and    = expr_eq  , { "&&" , expr_eq  } ;
    expr_eq     = expr_rel , { ( "==" | "/=" ) , expr_rel } ;
    expr_rel    = expr_add , { ( "<" | "<=" | ">" | ">=" ) , expr_add } ;
    expr_add    = expr_mul , { ( "+" | "-" ) , expr_mul } ;
    expr_mul    = expr_unary , { ( "*" | "/" | "%" ) , expr_unary } ;
    expr_unary  = "not" , expr_unary | "-" , expr_unary | expr_app ;
    expr_app    = atom , { atom } ;

## Atoms

    atom        = literal | ident | "(" , expr , ")"
                | "[" , [ expr , { "," , expr } ] , "]"
                | "(" , expr , "," , expr , { "," , expr } , ")" ;

    literal     = int_lit | float_lit | "True" | "False" ;

Only pair tuples `(a,b)` are supported at runtime.

## Super instructions

    super_expr  = "super" , ident , { ident } , "(" , super_body , ")"
                | "super" , ( "single" | "parallel" ) ,
                  "input" , "(" , ident , ")" ,
                  "output" , "(" , ident , ")" , legacy_body ;

    super_body  = balanced Haskell code (parens tracked by lexer) ;
    legacy_body = "#BEGINSUPER" , any text , "#ENDSUPER" ;

Primary syntax:

    result = super implName arg1 arg2 (
        implName a b = someExpression a b
    )

The body is delimited by balanced parentheses and compiled by GHC.

## Built-in print functions

Each prints the value and returns it (no super needed):

    print x      -- integer (Int64)
    prints xs    -- list of ASCII codes as string
    printl xs    -- list of integers
    printf x     -- float
    printlf xs   -- list of floats
    printmf xs   -- matrix (list of list of floats)

## Patterns

    pattern     = "_" | ident | literal
                | pattern , ":" , pattern
                | "[" , [ pattern , { "," , pattern } ] , "]"
                | "(" , pattern , "," , pattern , { "," , pattern } , ")" ;

## Let-pattern destructuring

    let (a, b) = expr in body

Desugared to `let _pat = expr in case _pat of (a, b) -> body`.

## Precedence (lowest to highest)

    ||  &&  == /=  < <= > >=  + -  * / %  not (unary -)  application  : (cons)

## Reserved words

    case else if in let of then not super single parallel input output
    True False print prints printl printf printlf printmf

## File extension

Ribault source files use `.hss`.
