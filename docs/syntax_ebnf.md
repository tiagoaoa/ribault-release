# Ribault Language Syntax (EBNF)

This document is a formal description of the surface syntax accepted by the
parser in `src/Analysis/Parser.y` and lexer in `src/Analysis/Lexer.x`.

Notation:
- `{ X }` means zero or more repetitions of `X`.
- `[ X ]` means optional `X`.
- `|` means alternatives.
- Terminals are in quotes.

## Lexical

```
letter      = "A".."Z" | "a".."z" ;
digit       = "0".."9" ;
idchar      = letter | digit | "_" | "'" ;
ident       = letter , { idchar } ;

int_lit     = digit , { digit } ;
float_lit   = digit , { digit } , "." , digit , { digit } ;
char_lit    = "'" , ( ? any char except ' and \ ? | escape ) , "'" ;
string_lit  = "\"" , { ? any char or escape except " ? } , "\"" ;

comment     = "--" , { ? any char except newline ? } ;
whitespace  = " " | "\t" | "\r" | "\n" ;
```

## Program structure

```
program     = decl_list ;

decl_list   = decl , { decl } ;

decl        = ident , params , "=" , expr ;
params      = { ident } ;
```

Note: the real parser uses **layout (indentation)** instead of semicolons.
The EBNF above omits layout rules; a new declaration starts when indentation
returns to the previous level.

## Expressions

```
expr        = lambda
            | if_expr
            | case_expr
            | let_expr
            | expr_or
            | expr , ":" , expr ;

lambda      = "\" , lam_params , "->" , expr ;
lam_params  = params | "(" , ident_list , ")" ;
ident_list  = ident , { "," , ident } ;

if_expr     = "if" , expr , "then" , expr , "else" , expr ;

case_expr   = "case" , expr , "of" , alts ;
alts        = alt_list ;
alt_list    = alt , { alt } ;
alt         = pattern , "->" , expr ;

let_expr    = "let" , decl_list , "in" , expr ;

expr_or     = expr_and , { "||" , expr_and } ;
expr_and    = expr_eq  , { "&&" , expr_eq  } ;
expr_eq     = expr_rel , { eq_op , expr_rel } ;
eq_op       = "==" | "/=" ;

expr_rel    = expr_add , { rel_op , expr_add } ;
rel_op      = "<" | "<=" | ">" | ">=" ;

expr_add    = expr_mul , { add_op , expr_mul } ;
add_op      = "+" | "-" ;

expr_mul    = expr_unary , { mul_op , expr_unary } ;
mul_op      = "*" | "/" | "%" ;

expr_unary  = "not" , expr_unary
            | "-"   , expr_unary
            | expr_app ;

expr_app    = atom , { atom } ;
```

## Atoms, literals, lists, tuples, supers

```
atom        = literal
            | ident
            | "(" , expr , ")"
            | list
            | tuple
            | super_expr ;

literal     = int_lit | float_lit | char_lit | string_lit
            | "True" | "False" ;

list        = "[" , [ expr_list ] , "]" ;
expr_list   = expr , { "," , expr } ;

tuple       = "(" , expr , "," , expr , { "," , expr } , ")" ;

super_expr  = "super" , super_kind ,
              "input"  , "(" , ident , ")" ,
              "output" , "(" , ident , ")" ,
              super_body ;

super_kind  = "single" | "parallel" ;

super_body  = "#BEGINSUPER" , super_text , "#ENDSUPER" ;
super_text  = { ? any character including newlines ? } ;
```

## Patterns

```
pattern     = "_"
            | ident
            | literal
            | pattern , ":" , pattern
            | list_pattern
            | tuple_pattern ;

list_pattern = "[" , [ pattern_list ] , "]" ;
pattern_list = pattern , { "," , pattern } ;

tuple_pattern = "(" , pattern , pattern_tuple_tail , ")" ;
pattern_tuple_tail = "," , pattern , { "," , pattern } ;
```

Note: only **pair tuples** `(a,b)` are represented correctly at runtime.
Larger tuples are parsed but not supported by the compiler backend.

## Precedence and associativity (informal)

From lowest to highest:
- `||`
- `&&`
- `==`, `/=`
- `<`, `<=`, `>`, `>=`
- `+`, `-`
- `*`, `/`, `%`
- unary `not`, unary `-`
- application (left-associative)
- `:` (right-associative)

This matches the precedence declarations in `Parser.y`.
