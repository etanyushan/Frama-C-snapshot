(****************************************************************************)
(*                                                                          *)
(*  Copyright (C) 2001-2003                                                 *)
(*   George C. Necula    <necula@cs.berkeley.edu>                           *)
(*   Scott McPeak        <smcpeak@cs.berkeley.edu>                          *)
(*   Wes Weimer          <weimer@cs.berkeley.edu>                           *)
(*   Ben Liblit          <liblit@cs.berkeley.edu>                           *)
(*  All rights reserved.                                                    *)
(*                                                                          *)
(*  Redistribution and use in source and binary forms, with or without      *)
(*  modification, are permitted provided that the following conditions      *)
(*  are met:                                                                *)
(*                                                                          *)
(*  1. Redistributions of source code must retain the above copyright       *)
(*  notice, this list of conditions and the following disclaimer.           *)
(*                                                                          *)
(*  2. Redistributions in binary form must reproduce the above copyright    *)
(*  notice, this list of conditions and the following disclaimer in the     *)
(*  documentation and/or other materials provided with the distribution.    *)
(*                                                                          *)
(*  3. The names of the contributors may not be used to endorse or          *)
(*  promote products derived from this software without specific prior      *)
(*  written permission.                                                     *)
(*                                                                          *)
(*  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS     *)
(*  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT       *)
(*  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS       *)
(*  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE          *)
(*  COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,     *)
(*  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,    *)
(*  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;        *)
(*  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER        *)
(*  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT      *)
(*  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN       *)
(*  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE         *)
(*  POSSIBILITY OF SUCH DAMAGE.                                             *)
(*                                                                          *)
(*  File modified by CEA (Commissariat à l'énergie atomique et aux          *)
(*                        énergies alternatives)                            *)
(*               and INRIA (Institut National de Recherche en Informatique  *)
(*                          et Automatique).                                *)
(****************************************************************************)

(* Copied and modified from [cil/src/errormsg.ml] *)

(***** Handling parsing errors ********)
type parseinfo = {
  lexbuf : Lexing.lexbuf;
  inchan : in_channel;
  mutable current_working_directory : string option;
}

let dummyinfo = {
  lexbuf    = Lexing.from_string "";
  inchan    = stdin;
  current_working_directory = None;
}

let current = ref dummyinfo

let startParsing fname =
  (* We only support one open file at a time *)
  if !current != dummyinfo then begin
    Kernel.fatal
      "[Errorloc.startParsing] supports only one open file: \
You want to open %S and %S is still open"
      fname (Lexing.lexeme_start_p !current.lexbuf).Lexing.pos_fname
  end;
  let inchan =
    try open_in_bin fname
    with Sys_error s ->
      Kernel.abort "Cannot find input file %S: %s" fname s
  in
  let lexbuf = Lexing.from_channel inchan in
  let filename = Filepath.normalize fname in
  let i = { lexbuf; inchan; current_working_directory = None } in
  (* Initialize lexer buffer. *)
  lexbuf.Lexing.lex_curr_p <-
    { Lexing.pos_fname = filename;
      Lexing.pos_lnum  = 1;
      Lexing.pos_bol   = 0;
      Lexing.pos_cnum  = 0
    };
  current := i;
  lexbuf

let finishParsing () =
  let i = !current in
  assert (i != dummyinfo);
  close_in i.inchan;
  current := dummyinfo


(* Call this function to announce a new line *)
let newline () =
  Lexing.new_line !current.lexbuf

let setCurrentLine (i: int) =
  let pos = !current.lexbuf.Lexing.lex_curr_p in
  !current.lexbuf.Lexing.lex_curr_p <-
    { pos with
      Lexing.pos_lnum = i;
      Lexing.pos_bol = pos.Lexing.pos_cnum;
    }

let setCurrentWorkingDirectory s =
  !current.current_working_directory <- Some s;;

let setCurrentFile ?(normalize=true) (n: string) =
  let n =
    if not normalize then n
    else
      let base = !current.current_working_directory in
      Filepath.normalize ?base n
  in
  let pos = !current.lexbuf.Lexing.lex_curr_p in
  !current.lexbuf.Lexing.lex_curr_p <- { pos with Lexing.pos_fname = n }


(* Prints the [pos.pos_lnum]-th line from file [pos.pos_fname],
   plus up to [ctx] lines before and after [pos.pos_lnum] (if they exist),
   similar to 'grep -C<ctx>'. The first line is numbered 1.
   Most exceptions are silently caught and printing is stopped if they occur. *)
let pp_context_from_file ?(ctx=2) fmt pos =
  try
    let in_ch = open_in pos.Lexing.pos_fname in
    try
      begin
        let n = pos.Lexing.pos_lnum in
        let first_to_print = max (n-ctx) 1 in
        let last_to_print = n+ctx in
        let i = ref 1 in
        try
          (* advance to line *)
          while !i < first_to_print do
            ignore (input_line in_ch);
            incr i
          done;
          (* print context and target line *)
          while !i <= last_to_print do
            let line = input_line in_ch in
            if !i = n then begin
              Format.fprintf fmt "%-6d%s\n" !i line;
              let cursor =
                  String.make 6 ' ' ^
                  String.make (String.length line) '^'
              in
              Format.fprintf fmt "%s\n" cursor
            end
            else
              Format.fprintf fmt "%-6d%s\n" !i line;
            incr i
          done;
        with End_of_file ->
          if !i <= n then (* could not reach line, print warning *)
            Kernel.warning "end of file reached before line %d" n
          else (* context after line n, no warning *) ()
      end;
      close_in in_ch
    with _ -> close_in_noerr in_ch
  with _ -> ()

let parse_error ?(source=Lexing.lexeme_start_p !current.lexbuf) msg =
  Pretty_utils.ksfprintf (fun str ->
  Kernel.feedback "%s" str ~append:(fun fmt ->
      Format.fprintf fmt " at %s:%d:\n"
        (Filepath.pretty source.Lexing.pos_fname) source.Lexing.pos_lnum;
      Format.fprintf fmt "%a@." (pp_context_from_file ~ctx:2) source);
      raise (Log.AbortError "kernel"))
    msg

(* More parsing support functions: line, file, char count *)
let currentLoc () : Lexing.position * Lexing.position =
  let i = !current in
  Lexing.lexeme_start_p i.lexbuf, Lexing.lexeme_end_p i.lexbuf


(** Handling of errors during parsing *)

let hadErrors = ref false
let had_errors () = !hadErrors
let clear_errors () = hadErrors := false

let set_error (_:Log.event) = hadErrors := true

let () =
  Kernel.register Log.Error set_error;
  Kernel.register Log.Failure set_error
