{

open Util
open Vyos1x_parser

exception Error of string

let lexing_error lexbuf msg =
  let line, column = Util.get_lexing_position lexbuf in
  raise (Syntax_error (Some (line, column), msg))

(*

The language of the VyOS 1.x config file has multiple ambiguities that
make it not even context free.

The main issue is lack of explicit statement separators, so if we ignore whitespace,
a parser is left to guess if, for example

address dhcp # leaf node with a value
disable      # valueless leaf node

is three valueless nodes, a valueless node followed by a node with a value,
or a node with a value followed by a valueless node.

The only cue is the newline, which means that newlines are sometimes significant,
and sometimes they aren't.

interfaces { # doesn't matter
  ethernet 'eth0' { # doesn't matter
    address '192.0.2.1/24' # significant!
    disable # significant!

    # empty line -- doesn't matter
    hw-id 00:aa:bb:cc:dd:ee # significant!
  } # doesn't matter
}

If there were explicit terminators (like we do in VyConf, or like JunOS does),
the language would be context free. Enter the lexer hack: let's emit newlines only
when they are significant, so that the parser can use them as terminators.

The informal idea is that a newline is only significant if it follows a leaf node.
So we need rules for finding out if we are inside a leaf node or not.

These are the formal rules. A newline is significant if and only if
1. Preceding token is an identifier
2. Preceding token is a quoted string

We set the vy_inside_node flag to true when we enter a leaf node and reset it when
we reach the end of it.

*)

let vy_inside_node = ref false

}

rule token = parse
| [' ' '\t' '\r']
    { token lexbuf }
| '\n'
    { Lexing.new_line lexbuf; if !vy_inside_node then (vy_inside_node := false; NEWLINE) else token lexbuf }
| '"'
    { vy_inside_node := true; read_double_quoted_string (Buffer.create 16) lexbuf }
| '''
    { vy_inside_node := true; read_single_quoted_string (Buffer.create 16) lexbuf }
| "/*"
    { vy_inside_node := false; read_comment (Buffer.create 16) lexbuf }
| '{'
    { vy_inside_node := false; LEFT_BRACE }
| '}'
    { vy_inside_node := false; RIGHT_BRACE }
| "//" [^ '\n']*
    { token lexbuf }
| [^ ' ' '\t' '\n' '\r' '{' '}' '"' ''' ]+ as s
    { vy_inside_node := true; IDENTIFIER s}
| eof
    { EOF }
| _ as bad_char
{ lexing_error lexbuf (Printf.sprintf "unexpected character \'%c\'" bad_char) }

and read_double_quoted_string buf =
  parse
  | '"'       { STRING (Buffer.contents buf) }
  | '\\' '/'  { Buffer.add_char buf '/'; read_double_quoted_string buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_double_quoted_string buf lexbuf }
  | '\\' 'b'  { Buffer.add_char buf '\b'; read_double_quoted_string buf lexbuf }
  | '\\' 'f'  { Buffer.add_char buf '\012'; read_double_quoted_string buf lexbuf }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_double_quoted_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_double_quoted_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_double_quoted_string buf lexbuf }
  | '\\' '\'' { Buffer.add_char buf '\''; read_double_quoted_string buf lexbuf }
  | '\\' '"' { Buffer.add_char buf '"'; read_double_quoted_string buf lexbuf }
  | '\n'      { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; read_double_quoted_string buf lexbuf }
  | [^ '"' '\\']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_double_quoted_string buf lexbuf
    }
  | eof { lexing_error lexbuf "Quoted string is missing the closing double quote" }

and read_single_quoted_string buf =
  parse
  | '''       { STRING (Buffer.contents buf) }
  | '\\' '/'  { Buffer.add_char buf '/'; read_single_quoted_string buf lexbuf }
  | '\\' '\\' { Buffer.add_char buf '\\'; read_single_quoted_string buf lexbuf }
  | '\\' 'b'  { Buffer.add_char buf '\b'; read_single_quoted_string buf lexbuf }
  | '\\' 'f'  { Buffer.add_char buf '\012'; read_single_quoted_string buf lexbuf }
  | '\\' 'n'  { Buffer.add_char buf '\n'; read_single_quoted_string buf lexbuf }
  | '\\' 'r'  { Buffer.add_char buf '\r'; read_single_quoted_string buf lexbuf }
  | '\\' 't'  { Buffer.add_char buf '\t'; read_single_quoted_string buf lexbuf }
  | '\\' '\'' { Buffer.add_char buf '\''; read_single_quoted_string buf lexbuf }
  | '\\' '"' { Buffer.add_char buf '"'; read_single_quoted_string buf lexbuf }
  | '\n'      { Lexing.new_line lexbuf; Buffer.add_char buf '\n'; read_single_quoted_string buf lexbuf }
  | [^ ''' '\\']+
    { Buffer.add_string buf (Lexing.lexeme lexbuf);
      read_single_quoted_string buf lexbuf
    }
  | eof { lexing_error lexbuf "Quoted string is missing the closing single quote" }

and read_comment buf =
  parse
  | "*/"
      { COMMENT (Buffer.contents buf) }
  | _
      { Buffer.add_string buf (Lexing.lexeme lexbuf);
        read_comment buf lexbuf
      }

(*

If you are curious how the original parsers handled the issue: they did not.
The CStore parser cheated by reading data from command definitions to resolve
the ambiguities, which made it impossible to use in standalone config
manipulation programs like migration scripts.

The XorpConfigParser could not tell tag nodes' name and tag from
a leaf node with a value, which made it impossible to manipulate
tag nodes or change values properly.

*)
