(**
 Checking the properties using semi-linear regular path schemas
 that is computed with respect to the diameter.
 
 @see PorBounds, SchemaChecker, SchemaCheckerLtl
 
 @author Igor Konnov, 2014-2016
 *)

open Printf

open Accums
open Debug
open SymbSkel
open Plugin
open PorBounds
open Spin
open SpinIr
open PromelaToTaPlugin

module L = SchemaCheckerLtl

let is_safety_spec tt s =
    match Ltl.classify_spec tt s with
    | Ltl.CondSafety (_, _) -> true
    | _ -> false


let get_proper_specs opts sk check_fun =
    let is_good name form =
        let asked = opts.Options.spec in
        (asked = "all" || asked = name) && (check_fun form)
    in
    let good, bad = StrMap.partition is_good sk.Sk.forms in
    let p name _ =
        if opts.Options.spec <> "all" && opts.Options.spec <> name
        then printf "      > Skipped %s (since you asked)\n" name
        else printf "      > Skipped %s (not supported)\n" name
    in
    StrMap.iter p bad;
    good


class slps_checker_plugin_t (plugin_name: string) (ta_source: TaSource.ta_source_t) =
    object(self)
        inherit analysis_plugin_t plugin_name

        method is_ltl tech =
            tech <> Some "cav15" && tech <> Some "cav15-opt"

        method is_ltl_mpi tech =
            tech = Some "ltl-mpi"

        method transform rt =
            let sprog = self#get_input0 in
            let tech = Options.get_plugin_opt rt#caches#options "schema.tech" in
            let sk = ta_source#get_ta in
            self#set_options rt;
            let is_buggy = if "bounds" <> rt#caches#options.Options.spec
                then self#check tech rt sprog sk
                else begin (* compute the bounds using the summary *)
                    let dom = rt#caches#analysis#get_pia_dom in
                    let dom_size = dom#length in
                    PorBounds.compute_diam rt#solver dom_size sk;
                    false
                end
            in
            Program.set_has_bug is_buggy sprog


        (* CAV'15 *)
        method check_reachability_cav15 rt sk tt =
            let tree, deps = PorBounds.make_schema_tree rt#solver sk in
            PorBounds.D.to_dot "flow.dot" sk deps;

            let nleafs = PorBounds.tree_leafs_count tree in
            let npaths, minlen, maxlen, totallen =
                    ref 0, ref max_int, ref 0, ref 0 in
            let reset_stat () =
                npaths := 0; minlen := max_int; maxlen := 0; totallen := 0
            in
            let update_stat length =
                npaths := !npaths + 1;
                minlen := min length !minlen;
                maxlen := max length !maxlen;
                totallen := !totallen + length
            in
            let print_stat () =
                if !npaths = 0
                then npaths := 1;
                log INFO (sprintf "  > nschemas = %d, min length = %d, max length = %d, avg length = %d"
                    !npaths !minlen !maxlen (!totallen / !npaths));
            in

            let lasttime = ref (Unix.time ()) in
            let on_leaf length =
                update_stat length;
                let newtime = Unix.time () in
                if (newtime -. !lasttime) > 5.0
                then begin
                    lasttime := newtime;
                    logtm INFO (sprintf "    checked path schema: %4d length: %4d progress: %2d%%"
                    !npaths length (!npaths * 100 / nleafs))
                end
            in
            let check_tree name form tree =
                SchemaChecker.is_error_tree rt tt sk on_leaf name form deps tree
            in
            log INFO "  > Running SchemaChecker (the CAV'15 reachability version)...";
            log INFO (sprintf "    > %d schemas to inspect..." nleafs);
            let each_form name form err_found =
                if err_found
                then true
                else begin
                    reset_stat ();
                    logtm INFO (sprintf "      > Checking %s..." name);
                    let err = check_tree name form tree in
                    let msg =
                        if err
                        then sprintf "    > SLPS: counterexample for %s found" name
                        else sprintf "      > Spec %s holds" name
                    in
                    log INFO msg;
                    print_stat ();
                    err
                end
            in
            let specs =
                get_proper_specs rt#caches#options sk (is_safety_spec tt) in
            StrMap.fold each_form specs false


        (* POPL'17 *)
        method check_ltl rt sk tt =
            let flow_opt = SchemaOpt.is_flow_opt_enabled () in
            let deps = PorBounds.compute_deps ~against_only:flow_opt rt#solver sk in
            PorBounds.D.to_dot "flow.dot" sk deps;
            log INFO "  > Running SchemaCheckerLtl (on the fly)...";
            let each_form name form err_found =
                if err_found
                then true
                else begin
                    logtm INFO (sprintf "      > Checking %s..." name);
                    let end_iter =
                        L.find_error_in_single_form rt tt sk name form deps in
                    let is_err_found = L.SchemaIter.iter_is_err_found end_iter in
                    let stat = L.SchemaIter.iter_get_stat end_iter in
                    let msg =
                        if is_err_found
                        then sprintf "    > SLPS: counterexample for %s found" name
                        else sprintf "      > Spec %s holds" name
                    in
                    log INFO msg;
                    printf "%s\n" (L.stat_s stat);
                    is_err_found
                end
            in
            let can_handle f =
                let negated = Ltl.normalize_form (UnEx (NEG, f)) in
                L.can_handle_spec tt sk negated
            in
            let specs = get_proper_specs rt#caches#options sk can_handle in
            StrMap.fold each_form specs false


        (* Unpublished, a parallel version with MPI *)
        method check_ltl_parallel rt sk tt =
            let flow_opt = SchemaOpt.is_flow_opt_enabled () in
            let deps = PorBounds.compute_deps ~against_only:flow_opt rt#solver sk in
            PorBounds.D.to_dot "flow.dot" sk deps;
            let can_handle f =
                let negated = Ltl.normalize_form (UnEx (NEG, f)) in
                L.can_handle_spec tt sk negated
            in
            let specs = get_proper_specs rt#caches#options sk can_handle in
            let forms = StrMap.bindings specs in
            log INFO "  > Running SchemaCheckerLtl (MPI experimental)...";
            let res = L.find_error_in_many_forms_parallel rt tt sk forms deps in
            match res with
            | None ->
                log INFO "      > The specifications hold";
                false

            | Some name ->
                log INFO (sprintf "    > SLPS: counterexample for %s found" name);
                true


        method check tech rt sprog sk =
            (* introduce variables for the location counters *)
            let loc_vars = IntMap.values sk.Sk.loc_vars in
            let ntt = (Program.get_type_tab sprog)#copy in
            let set_type v = ntt#set_type v (new data_type SpinTypes.TUNSIGNED) in
            BatEnum.iter set_type loc_vars;
            (* call the required technique *)
            if self#is_ltl tech
            then if self#is_ltl_mpi tech
                then self#check_ltl_parallel rt sk ntt
                else self#check_ltl rt sk ntt
            else self#check_reachability_cav15 rt sk ntt

        method update_runtime rt =
            ()

        method set_options rt =
            let opts = rt#caches#options in
            let getopt s = Options.get_plugin_opt opts s in
            let is_enabled opt = 
                opt = Some "1" || opt = Some "true" in
            let is_disabled no_opt = 
                no_opt = Some "1" || no_opt = Some "true" in
            let no_flow_opt = getopt "schema.noflowopt" in
            let no_reach_opt = getopt "schema.noreachopt" in
            let no_adaptive_reach_opt = getopt "schema.noadaptive" in
            let incremental = getopt "schema.incremental" in
            let no_guard_preds = getopt "schema.noguardpreds" in
            let always_compute_nschemas = getopt "schema.compute-nschemas" in

            let reach_on =
                if no_reach_opt <> None
                (* a manually set option overrides everything *)
                then not (is_disabled no_reach_opt)
                else if is_enabled incremental
                    then begin
                        Debug.log INFO "  # schema.incremental=1 sets schema.noreachopt=1";
                        true  (* enable in the incremental mode *)
                    end else begin
                        Debug.log INFO "  # schema.incremental=0 sets schema.noreachopt=0";
                        false (* disable in the non-incremental mode *)
                    end
            in
            let adaptive_on =
                if no_adaptive_reach_opt <> None
                (* a manually set option overrides everything *)
                then not (is_disabled no_adaptive_reach_opt)
                else if is_enabled incremental
                    then begin
                        Debug.log INFO "  # schema.incremental=1 sets schema.noadaptive=1";
                        true (* enable in the incremental mode *)
                    end else begin
                        Debug.log INFO "  # schema.incremental=0 sets schema.noadaptive=0";
                        false  (* disable in the non-incremental mode *)
                    end
            in

            SchemaOpt.set_incremental (is_enabled incremental);
            Debug.log INFO
                (sprintf "  # Incremental mode: %s"
                    (if is_enabled incremental then "enabled" else "disabled"));

            SchemaOpt.set_flow_opt (not (is_disabled no_flow_opt));
            Debug.log INFO
                (sprintf "  # Control flow optimization: %s"
                    (if is_disabled no_flow_opt then "disabled" else "enabled"));

            SchemaOpt.set_reach_opt reach_on;
            Debug.log INFO
                (sprintf "  # Reachability optimization: %s"
                    (if reach_on then "enabled" else "disabled"));

            SchemaOpt.set_adaptive_reach_opt adaptive_on;
            Debug.log INFO
                (sprintf "  # Adaptive reachability optimization: %s"
                    (if adaptive_on then "enabled" else "disabled"));

            SchemaOpt.set_use_guard_predicates (not (is_disabled no_guard_preds));
            Debug.log INFO
                (sprintf "  # Guards predicates: %s"
                    (if is_disabled no_flow_opt then "disabled" else "enabled"));

            SchemaOpt.set_always_compute_nschemas (is_enabled always_compute_nschemas);
            Debug.log INFO
                (sprintf "  # Always predict the number of schemas: %s"
                    (if is_enabled always_compute_nschemas
                        then "enabled"
                        else "disabled"));
    end

