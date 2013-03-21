(* Executing a path symbolically and collecting the constraints along it
 *
 * Igor Konnov, 2013
 *)

open Accums
open Cfg
open Printf
open Simplif
open Spin
open SpinIr
open SpinIrImp

exception SymbExec_error of string

type var_cons_tbl = (string, int) Hashtbl.t

let is_input (v: var): bool =
    let n = v#get_name in
    (String.length n) > 0 && (String.get n 0) = 'O'


let mk_input (type_tab: data_type_tab) (v: var): var =
    let nv = new var ("O" ^ v#get_name) (fresh_id ()) in
    let _ = type_tab#set_type nv (type_tab#get_type v) in
    nv


let linearize_blocks (path: token basic_block list) =
    let seq = List.concat (List.map (fun b -> b#get_seq) path) in
    let is_lin_stmt = function
    | Expr (_, Nop _) -> false
    | Expr (_, _) -> true
    | Decl (_, _, _) -> true
    | Assert (_, _) -> true
    | Assume (_, _) -> true
    | Havoc (_, _) -> true
    | _ -> false (* ignore anything else *)
    in
    List.filter is_lin_stmt seq


let sub_vars vals exp =
    let sub v =
        if not (is_input v) && (Hashtbl.mem vals v#id)
        then Hashtbl.find vals v#id
        else Var v
    in
    compute_consts (map_vars sub exp)


type simple_eval_res = TFalse | TTrue | TMaybe | Int of int

exception Eval_error of string

let is_sat solver type_tab exp =
    solver#push_ctx;
    let vars = expr_used_vars exp in
    let add_var v =
        let t = type_tab#get_type v in
        solver#append_var_def v t
    in
    if not (is_c_true exp)
    then begin
        List.iter add_var vars;
        solver#append_expr exp;
        let res = solver#check in
        solver#pop_ctx;
        res
    end else
        true


let indexed_var v idx = sprintf "%s_%d_" v#get_name idx

(* XXX: similar to Simplif.flatten_array_decl *)
let flatten_array_var type_tab new_type_tab new_sym_tab var =
    let tp = type_tab#get_type var in
    let decl_elem_var i =
        let nv = var#fresh_copy (indexed_var var i) in
        let nt = tp#copy in
        nt#set_nelems 1;
        new_type_tab#set_type nv nt;
        new_sym_tab#add_symb nv#get_name (nv :> symb)
    in
    if tp#is_array
    then List.iter decl_elem_var (range 0 tp#nelems)
    else begin
        new_type_tab#set_type var (type_tab#get_type var);
        new_sym_tab#add_symb var#get_name (var :> symb)
    end


let path_cnt = ref 0 (* DEBUGGING, remove it afterwards *)

let exec_path solver (type_tab: data_type_tab) (path: token basic_block list) =
    let new_sym_tab = new symb_tab "" in
    let new_type_tab = type_tab#copy in
    let rec replace_arr = function
    | BinEx (ARR_ACCESS, Var arr, Const i) ->
        Var ((new_sym_tab#lookup (indexed_var arr i))#as_var)
    | BinEx (ARR_ACCESS, Var arr, idx_exp) ->
        raise (SymbExec_error
            (sprintf "Expected a constant index, found: %s" (expr_s idx_exp)))
    | BinEx (t, l, r) -> BinEx (t, replace_arr l, replace_arr r)
    | UnEx (t, e) -> UnEx (t, replace_arr e)
    | _ as e -> e
    in
    let get_var = function
    | Var v ->
        v
    | _ as e ->
        raise (SymbExec_error (sprintf "Expected var, found: %s" (expr_s e)))
    in
    let vals = Hashtbl.create 10 in
    let add_input v =
        Hashtbl.add vals v#id (Var (mk_input new_type_tab v))
    in
    let stmts = linearize_blocks path in
    let exec path_cons = function
    | Expr (_, BinEx (ASGN, BinEx (ARR_ACCESS, Var arr, idx_exp), rhs)) ->
        let sub_lhs = BinEx (ARR_ACCESS, Var arr, (sub_vars vals idx_exp)) in
        let new_lhs = replace_arr sub_lhs in
        let new_rhs = replace_arr (sub_vars vals rhs) in
        let v = get_var new_lhs in
        Hashtbl.replace vals v#id new_rhs;
        path_cons

    | Expr (_, BinEx (ASGN, Var v, rhs)) ->
        let new_rhs = replace_arr (sub_vars vals rhs) in
        Hashtbl.replace vals v#id new_rhs;
        path_cons

    | Expr (_, e) ->
        let ne =
            try replace_arr (sub_vars vals e)
            with SymbExec_error s ->
            begin
                printf "The troublesome path is:\n";
                List.iter (fun s -> printf "  %s\n" (stmt_s s)) stmts;
                raise (SymbExec_error (s ^ " in: " ^ (expr_s e)))
            end
        in
        if is_c_true path_cons
        then ne
        else BinEx (AND, path_cons, ne)

    | _ -> path_cons
    in
    let vars = stmt_list_used_vars stmts in

    (* XXX: this can be done once and for all paths! Move it out... *)
    List.iter (flatten_array_var type_tab new_type_tab new_sym_tab) vars;
    let new_vars = List.map (fun (_, s) -> s#as_var) new_sym_tab#get_symbs in
    List.iter add_input new_vars;

    let path_cons = List.fold_left exec (Const 1) stmts in
    let path_cons = compute_consts path_cons in
    if not ((is_c_false path_cons)
        || (not (is_c_true path_cons)
            && not (is_sat solver new_type_tab path_cons)))
    then begin
        (* TODO: write debug info to a file *)
        (*
        printf "  Path constraint %d: %s\n" !path_cnt (expr_s path_cons);
        *)
        printf " %d\n" !path_cnt;
        path_cnt := !path_cnt + 1;
        (*
        let print_var v =
            let exp = Hashtbl.find vals v#id in
            printf " %s = %s," v#get_name (expr_s exp) in
        List.iter print_var new_vars;
        printf "\n\n"
        *)
    end

