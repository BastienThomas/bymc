(* Tracing codes (see Debug.trace).
 * The codes MUST be short, as they are used as the keys in
 * a hash table.
 *
 * Do not open this module, as it will pollute the name space,
 * but use the full name, e.g., Trc.SMT.
 *)

let smt = "SMT" (* smt *)
let ssa = "SSA" (* ssa *)
let cmd = "CMD" (* pipeCmd *)
let nse = "NSE" (* nusmvSsaEncoding *)
let pcr = "PCR" (* piaCtrRefinement *)
let syx = "SYX" (* symbExec *)
let bnd = "BND" (* porBounds *)
let sum = "SUM" (* summary *)

