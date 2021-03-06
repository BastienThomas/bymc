(*
  Convenient representation of an (extended) Promela program to simplify
  analysis and transformation passes.

  Igor Konnov, 2012
 *)

open Accums
open SpinIr

exception Program_error of string

(* a program under analysis and transformation.  *)

type program_t

type expr_t = Spin.token expr

type path_elem_t =
    | State of expr_t list (* a state as a set of variable constraints *)
    | Intrinsic of string StringMap.t (* intrinsic data: key=value *)

type path_t = path_elem_t list
type lasso_t = path_t * path_t (* (prefix, loop) *)

val program_of_units: data_type_tab -> Spin.token prog_unit list -> program_t
val units_of_program: program_t -> Spin.token prog_unit list
val empty: program_t

val prog_uid: program_t -> int

val get_params: program_t -> var list
val set_params: var list -> program_t -> program_t

(* shared (global) variables *)
val get_shared: program_t -> var list
(* @deprecated this function sets initialization expression to NOP *)
val set_shared: var list -> program_t -> program_t

(* shared variables with the initialization expressions *)
val get_shared_with_init: program_t -> (var * expr_t) list
val set_shared_with_init: (var * expr_t) list -> program_t -> program_t

(* extract all local variables declared in processes (may be slow!) *)
val get_all_locals: program_t -> var list

(* get the datatype of a variable (or Program_error if no such variable) *)
val get_type: program_t -> var -> data_type

(* get/set data type table *)
val get_type_tab: program_t -> data_type_tab
val set_type_tab: data_type_tab -> program_t -> program_t

(* get the main symbols table *)
val get_sym_tab: program_t -> symb_tab

(* global instrumental variables added by the abstractions,
   not part of the original problem *)
val get_instrumental: program_t -> var list
val set_instrumental: var list -> program_t -> program_t

(* assumptions that restrict the state space *)
val get_assumes: program_t -> expr_t list
val set_assumes: expr_t list -> program_t -> program_t

(* Constraints that capture the transitions known to be spurious.
  For instance, the CEGAR loop can report on such transitions *)
val get_spurious_steps: program_t ->
    ((* pre *) expr_t * (* post *) expr_t) list
val set_spurious_steps: 
    (expr_t * expr_t) list -> program_t -> program_t

(* unsafe expressions that are going to be intepreted by an external tool *)
val get_unsafes: program_t -> string list
val set_unsafes: string list -> program_t -> program_t

(* processes *)
val get_procs: program_t -> (Spin.token proc) list
val set_procs: (Spin.token proc) list -> program_t -> program_t

(* atomic propositions *)
val get_atomics: program_t -> (var * Spin.token atomic_expr) list
val get_atomics_map: program_t -> (Spin.token atomic_expr) StringMap.t
val set_atomics: (var * Spin.token atomic_expr) list -> program_t -> program_t

(* ltl formulas *)
val get_ltl_forms: program_t -> (expr_t) StringMap.t
val get_ltl_forms_as_hash: program_t -> (string, expr_t) Hashtbl.t
val set_ltl_forms: (expr_t) StringMap.t -> program_t -> program_t

(* is variable global *)
val is_global: program_t -> var -> bool
val is_not_global: program_t -> var -> bool

(* has any plugin find a bug? *)
val has_bug: program_t -> bool

(* indicate that a bug has been found *)
val set_has_bug: bool -> program_t -> program_t

