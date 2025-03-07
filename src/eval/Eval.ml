(*
  This file is part of scilla.

  Copyright (c) 2018 - present Zilliqa Research Pvt. Ltd.
  
  scilla is free software: you can redistribute it and/or modify it under the
  terms of the GNU General Public License as published by the Free Software
  Foundation, either version 3 of the License, or (at your option) any later
  version.
 
  scilla is distributed in the hope that it will be useful, but WITHOUT ANY
  WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
  A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 
  You should have received a copy of the GNU General Public License along with
  scilla.  If not, see <http://www.gnu.org/licenses/>.
*)

open Core_kernel
open Scilla_base
open Identifier
open ParserUtil
open Syntax
open ErrorUtils
open EvalUtil
open MonadUtil
open EvalMonad
open EvalMonad.Let_syntax
open PatternMatching
open Stdint
open ContractUtil
open PrettyPrinters
open EvalTypeUtilities
open EvalIdentifier
open EvalType
open EvalLiteral
open EvalSyntax
module CU = ScillaContractUtil (ParserRep) (ParserRep)

(***************************************************)
(*                    Utilities                    *)
(***************************************************)

let reserved_names =
  List.map
    ~f:(fun entry ->
      match entry with
      | LibVar (lname, _, _) -> get_id lname
      | LibTyp (tname, _) -> get_id tname)
    RecursionPrinciples.recursion_principles

(* Printing result *)
let pp_result r exclude_names gas_remaining =
  let enames = List.append exclude_names reserved_names in
  match r with
  | Error (s, _) -> sprint_scilla_error_list s
  | Ok ((e, env), _) ->
      let filter_prelude (k, _) =
        not @@ List.mem enames k ~equal:[%equal: EvalName.t]
      in
      sprintf "%s,\n%s\nGas remaining: %s" (Env.pp_value e)
        (Env.pp ~f:filter_prelude env)
        (Stdint.Uint64.to_string gas_remaining)

(* Makes sure that the literal has no closures in it *)
(* TODO: Augment with deep checking *)
let rec is_pure_literal l =
  match l with
  | Clo _ -> false
  | TAbs _ -> false
  | Msg es -> List.for_all es ~f:(fun (_, _, l') -> is_pure_literal l')
  | ADTValue (_, _, es) -> List.for_all es ~f:(fun e -> is_pure_literal e)
  (* | Map (_, ht) ->
   *     let es = Caml.Hashtbl.to_alist ht in
   *     List.for_all es ~f:(fun (k, v) -> is_pure_literal k && is_pure_literal v) *)
  | _ -> true

(* Sanitize before storing into a message *)
let sanitize_literal l =
  let open MonadUtil in
  let open Result.Let_syntax in
  let%bind t = literal_type l in
  if is_legal_message_field_type t then pure l
  else fail0 ~kind:"Cannot serialize literal" ~inst:(pp_literal l)

let eval_gas_charge env g =
  let open MonadUtil in
  let open Result.Let_syntax in
  let open EvalGas.GasSyntax in
  let resolver = function
    | SGasCharge.SizeOf vstr ->
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        let%bind lc = EvalGas.literal_cost l in
        pure @@ GasCharge.GInt lc
    | SGasCharge.ValueOf vstr -> (
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        match l with
        | UintLit (Uint32L ui) -> pure @@ GasCharge.GInt (Uint32.to_int ui)
        | UintLit (Uint64L ui) -> pure @@ GasCharge.GFloat (Uint64.to_float ui)
        | UintLit (Uint128L ui) ->
            pure @@ GasCharge.GFloat (Uint128.to_float ui)
        | UintLit (Uint256L ui) ->
            pure @@ GasCharge.GFloat (Integer256.Uint256.to_float ui)
        | ByStrX s' when Bystrx.width s' = Scilla_crypto.Snark.scalar_len ->
            let s = Bytes.of_string @@ Bystrx.to_raw_bytes s' in
            let ui = Integer256.Uint256.of_bytes_big_endian s 0 in
            pure @@ GasCharge.GFloat (Integer256.Uint256.to_float ui)
        | _ ->
            fail0 ~kind:"Variable did not resolve to an integer"
              ~inst:(EvalName.as_error_string vstr))
    | SGasCharge.LengthOf vstr -> (
        let%bind l = Env.lookup env (mk_loc_id vstr) in
        match l with
        | Map (_, m) -> pure @@ GasCharge.GInt (Caml.Hashtbl.length m)
        | ADTValue _ ->
            let%bind l' = Datatypes.scilla_list_to_ocaml l in
            pure @@ GasCharge.GInt (List.length l')
        | _ ->
            fail0
              ~kind:"eval_gas_charge: Can only take length of Maps and Lists"
              ?inst:None)
    | SGasCharge.MapSortCost vstr ->
        let%bind m = Env.lookup env (mk_loc_id vstr) in
        pure @@ GasCharge.GInt (EvalGas.map_sort_cost m)
    | SGasCharge.SumOf _ | SGasCharge.ProdOf _ | SGasCharge.DivCeil _
    | SGasCharge.MinOf _ | SGasCharge.StaticCost _ | SGasCharge.LogOf _ ->
        fail0 ~kind:"eval_gas_charge: Must be handled by GasCharge" ?inst:None
  in
  match%bind SGasCharge.eval resolver g with
  | GasCharge.GInt i -> pure i
  | GasCharge.GFloat _ ->
      fail0 ~kind:"eval_gas evaluated to a float value" ?inst:None

let builtin_cost env f targs tps args_id =
  let open MonadUtil in
  let open Result.Let_syntax in
  let%bind cost_expr =
    EvalGas.builtin_cost f ~targ_types:targs ~arg_types:tps args_id
  in
  let%bind cost = eval_gas_charge env cost_expr in
  pure cost

(* Return a builtin_op wrapped in EvalMonad *)
let builtin_executor env f targs args_id =
  let open MonadUtil in
  let open Result.Let_syntax in
  let%bind arg_lits = mapM args_id ~f:(fun arg -> Env.lookup env arg) in
  (* Builtin elaborators need to know the literal type of arguments *)
  let%bind tps = mapM arg_lits ~f:(fun l -> literal_type l) in
  let%bind ret_typ, op =
    EvalBuiltIns.EvalBuiltInDictionary.find_builtin_op f ~targtypes:targs
      ~vargtypes:tps
  in
  let%bind cost = builtin_cost env f targs tps args_id in
  let res () = op targs arg_lits ret_typ in
  pure (res, Uint64.of_int cost)

(* Replace address types with ByStr20 in a literal. 
   This is to ensure that address types are treated as ByStr20 throughout the interpreter.  *)
let replace_address_types l =
  let rec replace_in_type t =
    match t with
    | PrimType _ | TypeVar _ | PolyFun _ | Unit -> t
    | Address _ -> bystrx_typ Type.address_length
    | MapType (kt, vt) -> MapType (replace_in_type kt, replace_in_type vt)
    | FunType (t1, t2) -> FunType (replace_in_type t1, replace_in_type t2)
    | ADT (tname, targs) -> ADT (tname, List.map targs ~f:replace_in_type)
  in
  let replace_in_literal l =
    match l with
    | StringLit _ | IntLit _ | UintLit _ | BNum _ | ByStrX _ | ByStr _ | Clo _
    | TAbs _ ->
        l
    | Msg _ ->
        (* Messages are constructed using already sanitised literals, so no action needed *)
        l
    | Map ((kt, vt), tbl) ->
        (* Key/value pairs sanitised when inserted into the map. Only need to handle the types in the empty map *)
        Map ((replace_in_type kt, replace_in_type vt), tbl)
    | ADTValue (cname, targs, vargs) ->
        (* vargs sanitised before ADTValue is constructed. Only need to handle type arguments *)
        ADTValue (cname, List.map targs ~f:replace_in_type, vargs)
  in
  replace_in_literal l

(*******************************************************)
(* A monadic big-step evaluator for Scilla expressions *)
(*******************************************************)

(* [Evaluation in CPS]

   The following evaluator is implemented in a monadic style, with the
   monad, at the moment to be CPS, with the specialised return result
   type as described in [Specialising the Return Type of Closures].
 *)

let rec exp_eval erep env =
  let e, loc = erep in
  match e with
  | Literal l -> pure (replace_address_types l, env)
  | Var i ->
      let%bind v = fromR @@ Env.lookup env i in
      pure @@ (v, env)
  | Let (i, _, lhs, rhs) ->
      let%bind lval, _ = exp_eval lhs env in
      let env' = Env.bind env (get_id i) lval in
      exp_eval rhs env'
  | Message bs ->
      (* Resolve all message payload *)
      let resolve pld =
        match pld with
        | MLit l -> sanitize_literal l
        | MVar i ->
            let open Result.Let_syntax in
            let%bind v = Env.lookup env i in
            sanitize_literal v
      in
      let%bind payload_resolved =
        (* Make sure we resolve all the payload *)
        mapM bs ~f:(fun (s, pld) ->
            let%bind sanitized_lit = fromR @@ resolve pld in
            (* Messages should contain simplified types, so use literal_type *)
            let%bind t = fromR @@ literal_type sanitized_lit in
            pure (s, t, sanitized_lit))
      in
      pure (Msg payload_resolved, env)
  | Fun (formal, _, body) ->
      (* Apply to an argument *)
      let runner arg =
        let env1 = Env.bind env (get_id formal) arg in
        fstM @@ exp_eval body env1
      in
      pure (Clo runner, env)
  | App (f, actuals) ->
      (* Resolve the actuals *)
      let%bind args =
        mapM actuals ~f:(fun arg -> fromR @@ Env.lookup env arg)
      in
      let%bind ff = fromR @@ Env.lookup env f in
      (* Apply iteratively, also evaluating curried lambdas *)
      let%bind fully_applied =
        List.fold_left args ~init:(pure ff) ~f:(fun res arg ->
            let%bind v = res in
            try_apply_as_closure v arg)
      in
      pure (fully_applied, env)
  | Constr (cname, ts, actuals) ->
      let open Datatypes.DataTypeDictionary in
      let%bind _, constr =
        fromR
        @@ lookup_constructor ~sloc:(SR.get_loc (get_rep cname)) (get_id cname)
      in
      let alen = List.length actuals in
      if constr.arity <> alen then
        fail1 ~kind:"Constructor arity mismatch"
          ~inst:
            (sprintf "%s expects %d arguments, but got %d."
               (as_error_string cname) constr.arity alen)
          (SR.get_loc (get_rep cname))
      else
        (* Resolve the actuals *)
        let%bind args =
          mapM actuals ~f:(fun arg -> fromR @@ Env.lookup env arg)
        in
        (* Make sure we only pass "pure" literals, not closures *)
        let lit = ADTValue (get_id cname, ts, args) in
        pure (replace_address_types lit, env)
  | MatchExpr (x, clauses) ->
      let%bind v = fromR @@ Env.lookup env x in
      (* Get the branch and the bindings *)
      let%bind (_, e_branch), bnds =
        tryM clauses
          ~msg:(fun () ->
            mk_error1 ~kind:"Match expression failed. No clause matched."
              ?inst:None loc)
          ~f:(fun (p, _) -> fromR @@ match_with_pattern v p)
      in
      (* Update the environment for the branch *)
      let env' =
        List.fold_left bnds ~init:env ~f:(fun z (i, w) ->
            Env.bind z (get_id i) w)
      in
      exp_eval e_branch env'
  | Builtin (i, targs, actuals) ->
      let%bind thunk, cost = fromR @@ builtin_executor env i targs actuals in
      let%bind res = checkwrap_opR thunk cost in
      pure (res, env)
  | Fixpoint (g, _, body) ->
      let rec fix arg =
        let env1 = Env.bind env (get_id g) clo_fix in
        let%bind fbody, _ = exp_eval body env1 in
        match fbody with
        | Clo f -> f arg
        | _ ->
            fail0 ~kind:"Cannot apply fixpoint argument to a value" ?inst:None
      and clo_fix = Clo fix in
      pure (clo_fix, env)
  | TFun (tv, body) ->
      let typer arg_type =
        let body_subst = subst_type_in_expr tv arg_type body in
        fstM @@ exp_eval body_subst env
      in
      pure (TAbs typer, env)
  | TApp (tf, arg_types) ->
      let%bind ff = fromR @@ Env.lookup env tf in
      let%bind fully_applied =
        List.fold_left arg_types ~init:(pure ff) ~f:(fun res arg_type ->
            let%bind v = res in
            try_apply_as_type_closure v arg_type)
      in
      pure (fully_applied, env)
  | GasExpr (g, e') ->
      let thunk () = exp_eval e' env in
      let%bind cost = fromR @@ eval_gas_charge env g in
      let emsg = sprintf "Ran out of gas" in
      (* Add end location too: https://github.com/Zilliqa/scilla/issues/134 *)
      checkwrap_op thunk (Uint64.of_int cost)
        (mk_error1 ~kind:emsg ?inst:None loc)

(* Applying a function *)
and try_apply_as_closure v arg =
  match v with
  | Clo clo -> clo arg
  | _ ->
      fail0 ~kind:"Trying to apply a non-functional value"
        ~inst:(Env.pp_value v)

and try_apply_as_type_closure v arg_type =
  match v with
  | TAbs tclo -> tclo arg_type
  | _ ->
      fail0 ~kind:"Trying to type-apply a non-type closure"
        ~inst:(Env.pp_value v)

(* [Initial Gas-Passing Continuation]

   The following function is used as an initial continuation to
   "bootstrap" the gas-aware computation and then retrieve not just
   the result, but also the remaining gas.

*)
let init_gas_kont r gas' =
  match r with Ok z -> Ok (z, gas') | Error msg -> Error (msg, gas')

(* [Continuation for Expression Evaluation]

   The following function implements an impedance matcher. Even though
   it takes a continuation `k` from the callee, it starts evaluating
   an expression `expr` in a "basic" continaution `init_gas_kont` (cf.
   [Initial Gas-Passing Continuation]) with a _fixed_ result type (cf
   [Specialising the Return Type of Closures]). In short, it fully
   evaluates an expression with the fixed continuation, after which
   the result is passed further to the callee's continuation `k`.

*)
let exp_eval_wrapper_no_cps expr env k gas =
  let eval_res = exp_eval expr env init_gas_kont gas in
  let res, remaining_gas =
    match eval_res with Ok (z, g) -> (Ok z, g) | Error (m, g) -> (Error m, g)
  in
  k res remaining_gas

open EvalSyntax

(*******************************************************)
(* A monadic big-step evaluator for Scilla statemnts   *)
(*******************************************************)
let rec stmt_eval conf stmts =
  match stmts with
  | [] -> pure conf
  | (s, sloc) :: sts -> (
      match s with
      | Load (x, r) ->
          let%bind l = Configuration.load conf r in
          let conf' = Configuration.bind conf (get_id x) l in
          stmt_eval conf' sts
      | RemoteLoad (x, adr, r) -> (
          let%bind a = fromR @@ Configuration.lookup conf adr in
          match a with
          | ByStrX s' when Bystrx.width s' = Type.address_length ->
              let%bind l = Configuration.remote_load conf s' r in
              let conf' = Configuration.bind conf (get_id x) l in
              stmt_eval conf' sts
          | _ ->
              fail0 ~kind:"Expected remote load address to be ByStr20 value"
                ?inst:None)
      | Store (x, r) ->
          let%bind v = fromR @@ Configuration.lookup conf r in
          let%bind () = Configuration.store x v in
          stmt_eval conf sts
      | Bind (x, e) ->
          let%bind lval, _ = exp_eval_wrapper_no_cps e conf.env in
          let conf' = Configuration.bind conf (get_id x) lval in
          stmt_eval conf' sts
      | MapUpdate (m, klist, ropt) ->
          let%bind klist' =
            mapM ~f:(fun k -> fromR @@ Configuration.lookup conf k) klist
          in
          let%bind v =
            match ropt with
            | Some r ->
                let%bind v = fromR @@ Configuration.lookup conf r in
                pure (Some v)
            | None -> pure None
          in
          let%bind () = Configuration.map_update m klist' v in
          stmt_eval conf sts
      | MapGet (x, m, klist, fetchval) ->
          let%bind klist' =
            mapM ~f:(fun k -> fromR @@ Configuration.lookup conf k) klist
          in
          let%bind l = Configuration.map_get conf m klist' fetchval in
          let conf' = Configuration.bind conf (get_id x) l in
          stmt_eval conf' sts
      | RemoteMapGet (x, adr, m, klist, fetchval) -> (
          let%bind a = fromR @@ Configuration.lookup conf adr in
          match a with
          | ByStrX abystr when Bystrx.width abystr = Type.address_length ->
              let%bind klist' =
                mapM ~f:(fun k -> fromR @@ Configuration.lookup conf k) klist
              in
              let%bind l =
                Configuration.remote_map_get abystr m klist' fetchval
              in
              let conf' = Configuration.bind conf (get_id x) l in
              stmt_eval conf' sts
          | _ -> fail0 ~kind:"Expected address to be ByStr20 value" ?inst:None)
      | ReadFromBC (x, bf) ->
          let%bind l = Configuration.bc_lookup conf bf in
          let conf' = Configuration.bind conf (get_id x) l in
          stmt_eval conf' sts
      | TypeCast (x, r, t) ->
          let%bind l = fromR @@ Configuration.lookup conf r in
          let%bind l_as_bstr =
            match l with
            | ByStrX lbystr when Bystrx.width lbystr = Type.address_length ->
                pure lbystr
            | _ ->
                fail0 ~kind:"Expected address or ByStr20 in type cast"
                  ?inst:None
          in
          let%bind tc_res =
            fromR
            @@ EvalTypecheck.typecheck_remote_field_types ~caddr:l_as_bstr t
          in
          let res = if tc_res then build_some_lit l t else build_none_lit t in
          let conf' = Configuration.bind conf (get_id x) res in
          stmt_eval conf' sts
      | MatchStmt (x, clauses) ->
          let%bind v = fromR @@ Env.lookup conf.env x in
          let%bind (_, branch_stmts), bnds =
            tryM clauses
              ~msg:(fun () ->
                mk_error0
                  ~kind:
                    "Value does not match any clause of pattern matching \
                     statement"
                  ~inst:
                    (sprintf "%s\ndoes not match any clause of\n%s."
                       (Env.pp_value v) (pp_stmt s)))
              ~f:(fun (p, _) -> fromR @@ match_with_pattern v p)
          in
          (* Update the environment for the branch *)
          let conf' =
            List.fold_left bnds ~init:conf ~f:(fun z (i, w) ->
                Configuration.bind z (get_id i) w)
          in
          let%bind conf'' = stmt_eval conf' branch_stmts in
          (* Restore initial immutable bindings *)
          let cont_conf = { conf'' with env = conf.env } in
          stmt_eval cont_conf sts
      | AcceptPayment ->
          let%bind conf' = Configuration.accept_incoming conf in
          stmt_eval conf' sts
      (* Caution emitting messages does not change balance immediately! *)
      | SendMsgs ms ->
          let%bind ms_resolved = fromR @@ Configuration.lookup conf ms in
          let%bind conf' = Configuration.send_messages conf ms_resolved in
          stmt_eval conf' sts
      | CreateEvnt params ->
          let%bind eparams_resolved =
            fromR @@ Configuration.lookup conf params
          in
          let%bind conf' = Configuration.create_event conf eparams_resolved in
          stmt_eval conf' sts
      | CallProc (p, actuals) ->
          (* Resolve the actuals *)
          let%bind args =
            mapM actuals ~f:(fun arg -> fromR @@ Env.lookup conf.env arg)
          in
          let%bind proc, p_rest = Configuration.lookup_procedure conf p in
          (* Apply procedure. No gas charged for the application *)
          let%bind conf' = try_apply_as_procedure conf proc p_rest args in
          stmt_eval conf' sts
      | Iterate (l, p) ->
          let%bind l_actual = fromR @@ Env.lookup conf.env l in
          let%bind l' = fromR @@ Datatypes.scilla_list_to_ocaml l_actual in
          let%bind proc, p_rest = Configuration.lookup_procedure conf p in
          let%bind conf' =
            foldM l' ~init:conf ~f:(fun confacc arg ->
                let%bind conf' =
                  try_apply_as_procedure confacc proc p_rest [ arg ]
                in
                pure conf')
          in
          stmt_eval conf' sts
      | Throw eopt ->
          let%bind estr =
            match eopt with
            | Some e ->
                let%bind e_resolved = fromR @@ Configuration.lookup conf e in
                pure @@ pp_literal e_resolved
            | None -> pure ""
          in
          let err = mk_error1 ~kind:"Exception thrown" ~inst:estr sloc in
          let elist =
            List.map conf.component_stack ~f:(fun cname ->
                {
                  ekind = "Raised from " ^ as_error_string cname;
                  einst = None;
                  startl = ER.get_loc (get_rep cname);
                  endl = dummy_loc;
                })
          in
          fail (err @ elist)
      | GasStmt g ->
          let%bind cost = fromR @@ eval_gas_charge conf.env g in
          let err =
            mk_error1 ~kind:"Ran out of gas after evaluating statement"
              ?inst:None sloc
          in
          let remaining_stmts () = stmt_eval conf sts in
          checkwrap_op remaining_stmts (Uint64.of_int cost) err)

and try_apply_as_procedure conf proc proc_rest actuals =
  (* Create configuration for procedure call *)
  let sender = GlobalName.parse_simple_name MessagePayload.sender_label in
  let origin = GlobalName.parse_simple_name MessagePayload.origin_label in
  let amount = GlobalName.parse_simple_name MessagePayload.amount_label in
  let%bind sender_value =
    fromR @@ Configuration.lookup conf (mk_loc_id sender)
  in
  let%bind origin_value =
    fromR @@ Configuration.lookup conf (mk_loc_id origin)
  in
  let%bind amount_value =
    fromR @@ Configuration.lookup conf (mk_loc_id amount)
  in
  let%bind proc_conf =
    Configuration.bind_all
      { conf with env = conf.init_env; procedures = proc_rest }
      (origin
       ::
       sender
       ::
       amount
       :: List.map proc.comp_params ~f:(fun id_typ -> get_id (fst id_typ)))
      (origin_value :: sender_value :: amount_value :: actuals)
  in
  let%bind conf' = stmt_eval proc_conf proc.comp_body in
  (* Reset configuration *)
  pure
    {
      conf' with
      env = conf.env;
      procedures = conf.procedures;
      component_stack = proc.comp_name :: conf.component_stack;
    }

(*******************************************************)
(*          BlockchainState initialization             *)
(*******************************************************)

let check_blockchain_entries entries =
  let expected = [ (ContractUtil.blocknum_name, ContractUtil.blocknum_type) ] in
  (* every entry must be expected *)
  let c1 =
    List.for_all entries ~f:(fun (s, t, _) ->
        List.exists expected ~f:(fun (x, xt) ->
            String.(x = s) && [%equal: EvalType.t] xt t))
  in
  (* everything expected must be entered *)
  (* everything expected must be entered *)
  let c2 =
    List.for_all expected ~f:(fun (x, xt) ->
        List.exists entries ~f:(fun (s, t, _) ->
            String.(x = s) && [%equal: EvalType.t] xt t))
  in
  if c1 && c2 then pure entries
  else
    fail0 ~kind:"Mismatch in input blockchain variables"
      ~inst:
        (sprintf "expected:\n%s\nprovided:\n%s\n" (pp_str_typ_map expected)
           (pp_typ_literal_map entries))

(*******************************************************)
(*              Contract initialization                *)
(*******************************************************)

(* Evaluate constraint, and abort if false *)
let eval_constraint cconstraint env =
  let%bind contract_val, _ = exp_eval_wrapper_no_cps cconstraint env in
  match contract_val with
  | ADTValue (c, [], []) when Datatypes.is_true_ctr_name c -> pure ()
  | _ -> fail0 ~kind:"Contract constraint violation" ?inst:None

let init_lib_entries env libs =
  let init_lib_entry env id e =
    let%map v, _ = exp_eval_wrapper_no_cps e env in
    Env.bind env (get_id id) v
  in
  List.fold_left libs ~init:env ~f:(fun eres lentry ->
      match lentry with
      | LibTyp (tname, ctr_defs) ->
          let open Datatypes.DataTypeDictionary in
          let ctrs, tmaps =
            List.fold_right ctr_defs ~init:([], [])
              ~f:(fun ctr_def (tmp_ctrs, tmp_tmaps) ->
                let { cname; c_arg_types } = ctr_def in
                ( {
                    Datatypes.cname = get_id cname;
                    Datatypes.arity = List.length c_arg_types;
                  }
                  :: tmp_ctrs,
                  (get_id cname, c_arg_types) :: tmp_tmaps ))
          in
          let adt =
            {
              Datatypes.tname = get_id tname;
              Datatypes.tparams = [];
              Datatypes.tconstr = ctrs;
              Datatypes.tmap = tmaps;
            }
          in
          let _ = add_adt adt (get_rep tname) in
          let () =
            GlobalConfig.StdlibTracker.add_deflib_adttyp (as_string tname)
              (Filename.basename (get_rep tname).fname)
          in
          eres
      | LibVar (lname, _, lexp) ->
          let%bind env = eres in
          init_lib_entry env lname lexp)

(* Initializing libraries of a contract *)
let init_libraries clibs elibs =
  DebugMessage.plog "Loading library types and functions.";
  let%bind rec_env =
    let%bind rlibs =
      mapM
        ~f:(Fn.compose fromR EvalGas.lib_entry_cost)
        RecursionPrinciples.recursion_principles
    in
    init_lib_entries (pure Env.empty) rlibs
  in
  let rec recurser libnl =
    if List.is_empty libnl then pure rec_env
    else
      (* Walk through library dependence tree. *)
      foldM libnl ~init:[] ~f:(fun acc_env libnode ->
          let dep_env = recurser libnode.deps in
          let entries = libnode.libn.lentries in
          let%bind env' = init_lib_entries dep_env entries in
          (* Remove dep_env from env'. We don't want transitive imports.
           * TODO: Add a utility function in Env for this. *)
          let env =
            Env.filter env' ~f:(fun name ->
                (* If "name" exists in "entries" or rec_env, retain it. *)
                List.exists entries ~f:(fun entry ->
                    match entry with
                    | LibTyp _ -> false (* Types are not part of Env. *)
                    | LibVar (i, _, _) -> [%equal: EvalName.t] (get_id i) name)
                || List.Assoc.mem rec_env name ~equal:[%equal: EvalName.t])
          in
          pure @@ Env.bind_all acc_env env)
  in
  let extlibs_env = recurser elibs in
  (* Finally walk the local library. *)
  match clibs with
  | Some l -> init_lib_entries extlibs_env l.lentries
  | None -> extlibs_env

(* Initialize fields in a constant environment *)
let init_fields env fs =
  (* Initialize a field in a constant environment *)
  let init_field fname t fexp =
    let%bind v, _ = exp_eval_wrapper_no_cps fexp env in
    match v with
    | l when is_pure_literal l -> pure (fname, t, l)
    | _ ->
        fail0 ~kind:"Closure cannot be stored in a field"
          ~inst:(EvalName.as_error_string fname)
  in
  mapM fs ~f:(fun (i, t, e) -> init_field (get_id i) t e)

let init_contract libenv cparams' cfields initargs' init_bal =
  (* All contracts take a few implicit parameters. *)
  let cparams = CU.append_implicit_contract_params cparams' in
  (* Remove arguments that the evaluator doesn't (need to) deal with.
   * Validation of these init parameters is left to the blockchain. *)
  let initargs = CU.remove_noneval_args initargs' in
  (* There as an init arg for each parameter *)
  let%bind pending_dyn_checks =
    foldM cparams ~init:[] ~f:(fun acc_dyn_checks (x, xt) ->
        let%bind arg_dyn_checks =
          find_mapM initargs ~f:(fun (s, l) ->
              if not @@ EvalName.equal (get_id x) s then
                (* Not this entry *)
                pure None
              else
                (* Typecheck the literal against the parameter type *)
                let%bind dyn_checks =
                  fromR @@ assert_literal_type ~expected:xt l
                in
                pure (Some dyn_checks))
        in
        match arg_dyn_checks with
        | Some dyn_checks -> pure @@ dyn_checks @ acc_dyn_checks
        | None ->
            fail0 ~kind:"No init entry found matching contract parameter"
              ~inst:(as_error_string x))
  in
  (* There is a parameter for each init arg *)
  let%bind () =
    forallM initargs ~f:(fun (s, _l) ->
        if List.exists cparams ~f:(fun (x, _xt) -> EvalName.equal (get_id x) s)
        then pure ()
        else
          fail0 ~kind:"Parameter is not specified in the contract"
            ~inst:(EvalName.as_error_string s))
  in
  (* Each init arg is unique *)
  let%bind () =
    if
      List.contains_dup initargs ~compare:(fun (s, _) (s', _) ->
          EvalName.compare s s')
    then fail0 ~kind:"Duplicate init arguments entries found" ?inst:None
    else pure ()
  in
  (* Fold params into already initialized libraries, possibly shadowing *)
  let env = Env.bind_all libenv initargs in
  let fields = List.map cfields ~f:(fun (f, t, _) -> (get_id f, t)) in
  let balance = init_bal in
  let open ContractState in
  let cstate = { env; fields; balance } in
  pure (cstate, pending_dyn_checks)

(* Combine initialized state with infro from current state *)
let create_cur_state_fields initcstate curcstate =
  (* If there's a field in curcstate that isn't in initcstate,
     flag it as invalid input state *)
  let%bind () =
    forallM curcstate ~f:(fun (s, t, l) ->
        let%bind ex =
          existsM initcstate ~f:(fun (x, xt, _xl) ->
              if not @@ [%equal: EvalName.t] s x then
                (* Not this entry *)
                pure false
              else if not @@ [%equal: EvalType.t] xt t then
                fail0
                  ~kind:"State type of field does not match the declared type"
                  ~inst:
                    (sprintf "Field %s : %s does not match the declared type %s"
                       (EvalName.as_error_string s)
                       (pp_typ t) (pp_typ xt))
              else
                (* Check that the literal matches the stated type *)
                let%bind _dyn_checks =
                  fromR @@ assert_literal_type ~expected:t l
                in
                (* Ignore dynamic typechecks - if it's in the current state, then it's already been checked *)
                pure true)
        in
        if not ex then
          fail0 ~kind:"Field not defined in the contract"
            ~inst:
              (sprintf "field %s of type %s"
                 (EvalName.as_error_string s)
                 (pp_typ t))
        else pure ())
  in
  (* We allow fields in initcstate that isn't in curcstate *)
  (* Each curcstate field is unique *)
  let%bind () =
    if
      List.contains_dup curcstate ~compare:(fun (s, _, _) (s', _, _) ->
          EvalName.compare s s')
    then fail0 ~kind:"Duplicate field entries found" ?inst:None
    else pure ()
  in
  (* Get only those fields from initcstate that are not in curcstate *)
  let filtered_init =
    List.filter initcstate ~f:(fun (s, _, _) ->
        not
          (List.exists curcstate ~f:(fun x -> [%equal: EvalName.t] s (fst3 x))))
  in
  (* Combine filtered list and curcstate *)
  pure (filtered_init @ curcstate)

let check_contr libs_env cconstraint cfields initargs curargs =
  let initargs' = CU.remove_noneval_args initargs in
  let env = Env.bind_all libs_env initargs' in
  let%bind () = eval_constraint cconstraint env in
  let%bind field_vals = init_fields env cfields in
  let%bind curfield_vals = create_cur_state_fields field_vals curargs in
  pure curfield_vals

(* Initialize a module with given arguments and initial balance *)
let init_module libenv md initargs init_bal bstate =
  let { contr; _ } = md in
  let ({ cparams; cfields; _ } : contract) = contr in
  let%bind initcstate, pending_dyn_checks =
    init_contract libenv cparams cfields initargs init_bal
  in
  (* blockchain input provided is only validated and not used here. *)
  let%bind () = EvalMonad.ignore_m @@ check_blockchain_entries bstate in
  let cstate = { initcstate with fields = initcstate.fields } in
  pure (contr, cstate, pending_dyn_checks)

(*******************************************************)
(*               Message processing                    *)
(*******************************************************)

(* Extract necessary bits from the message *)
let preprocess_message es =
  let%bind tag = fromR @@ MessagePayload.get_tag es in
  let%bind amount = fromR @@ MessagePayload.get_amount es in
  let other = MessagePayload.get_other_entries es in
  pure (tag, amount, other)

(* Retrieve transition based on the tag *)
let get_transition_and_procedures ctr tag =
  let rec procedure_and_transition_finder procs_acc cs =
    match cs with
    | [] ->
        (* Transition not found *)
        (procs_acc, None)
    | c :: c_rest -> (
        match c.comp_type with
        | CompProc ->
            (* Procedure is in scope - continue searching *)
            procedure_and_transition_finder (c :: procs_acc) c_rest
        | CompTrans when String.(tag = as_string c.comp_name) ->
            (* Transition found - return *)
            (procs_acc, Some c)
        | CompTrans ->
            (* Not the correct transition - ignore *)
            procedure_and_transition_finder procs_acc c_rest)
  in
  let procs, trans_opt = procedure_and_transition_finder [] ctr.ccomps in
  match trans_opt with
  | None -> fail0 ~kind:"No contract transition for tag found" ~inst:tag
  | Some t ->
      let params = t.comp_params in
      let body = t.comp_body in
      let name = t.comp_name in
      pure (procs, params, body, name)

(* Ensure match b/w transition defined params and passed arguments (entries) *)
let check_message_entries cparams_o entries =
  let tparams = CU.append_implicit_comp_params cparams_o in
  (* There as an entry for each parameter *)
  let%bind pending_dyn_checks =
    foldM tparams ~init:[] ~f:(fun acc_dyn_checks (x, xt) ->
        let%bind entry_dyn_checks =
          find_mapM entries ~f:(fun (s, _t, l) ->
              if not @@ String.(as_string x = s) then
                (* Not this entry *)
                pure None
              else
                (* We ignore the type from the message entry, since that was used to parse the literal, and hence is known to be valid *)
                let%bind dyn_checks =
                  fromR @@ assert_literal_type ~expected:xt l
                in
                if
                  String.(
                    s = ContractUtil.MessagePayload.sender_label
                    || s = ContractUtil.MessagePayload.origin_label)
                then
                  (* _sender and _origin are known to be valid addresses, so ignore their dynamic typechecks *)
                  pure (Some [])
                else pure (Some dyn_checks))
        in
        match entry_dyn_checks with
        | Some dyn_checks -> pure @@ dyn_checks @ acc_dyn_checks
        | None ->
            fail0 ~kind:"No message entry found matching parameter"
              ~inst:(as_error_string x))
  in
  (* There is a parameter for each entry *)
  let%bind () =
    forallM entries ~f:(fun (s, _t, _l) ->
        if List.exists tparams ~f:(fun (x, _xt) -> String.(as_string x = s))
        then pure ()
        else fail0 ~kind:"No parameter found matching message entry" ~inst:s)
  in
  (* Each entry name is unique *)
  let%bind () =
    if
      List.contains_dup entries ~compare:(fun (s, _, _) (s', _, _) ->
          String.compare s s')
    then fail0 ~kind:"Duplicate message entries found" ?inst:None
    else pure ()
  in
  pure (entries, pending_dyn_checks)

(* Get the environment, incoming amount, procedures in scope, and body to execute*)
let prepare_for_message contr entries =
  let%bind tag, incoming_amount, other = preprocess_message entries in
  let%bind tprocedures, tparams, tbody, tname =
    get_transition_and_procedures contr tag
  in
  let%bind tenv, pending_dyn_checks = check_message_entries tparams other in
  pure ((tenv, incoming_amount, tprocedures, tbody, tname), pending_dyn_checks)

(* Subtract the amounts to be transferred *)
let post_process_msgs cstate outs =
  (* Evey outgoing message should carry an "_amount" tag *)
  let%bind amounts =
    mapM outs ~f:(fun l ->
        match l with
        | Msg es -> fromR @@ MessagePayload.get_amount es
        | _ -> fail0 ~kind:"Not a message literal" ~inst:(pp_literal l))
  in
  let open Uint128 in
  let to_be_transferred =
    List.fold_left amounts ~init:zero ~f:(fun z a -> add z a)
  in
  let open ContractState in
  if compare cstate.balance to_be_transferred < 0 then
    fail0
      ~kind:"The balance is too low to transfer all the funds in the messages"
      ~inst:
        (sprintf "balance = %s, amount to transfer = %s"
           (to_string cstate.balance)
           (to_string to_be_transferred))
  else
    let balance = sub cstate.balance to_be_transferred in
    pure { cstate with balance }

(* 
Handle message:
* tenv, incoming_funds, procedures, stmts, tname: Result of prepare_for_message, minus dynamic typechecks
* cstate : ContractState.t - current contract state
* bstate : (string * type * literal) list - blockchain state
*)
let handle_message (tenv, incoming_funds, procedures, stmts, tname) cstate
    bstate =
  let open ContractState in
  let { env; fields; balance } = cstate in
  (* Add all values to the contract environment *)
  let%bind actual_env =
    foldM tenv ~init:env ~f:(fun e (n, _t, l) ->
        (* TODO, Issue #836: Message fields may contain periods, which shouldn't be allowed. *)
        match String.split n ~on:'.' with
        | [ simple_name ] ->
            pure @@ Env.bind e (GlobalName.parse_simple_name simple_name) l
        | _ -> fail0 ~kind:"Illegal field in incoming message" ~inst:n)
  in
  let open Configuration in
  (* Create configuration *)
  let conf =
    {
      init_env = actual_env;
      env = actual_env;
      fields;
      balance;
      accepted = false;
      blockchain_state = List.map bstate ~f:(fun x -> (fst3 x, trd3 x));
      incoming_funds;
      procedures;
      component_stack = [ tname ];
      emitted = [];
      events = [];
    }
  in

  (* Finally, run the evaluator for statements *)
  let%bind conf' = stmt_eval conf stmts in
  let cstate' =
    { env = cstate.env; fields = conf'.fields; balance = conf'.balance }
  in
  let new_msgs = conf'.emitted in
  let new_events = conf'.events in
  (* Make sure that we aren't too generous and subract funds *)
  let%bind cstate'' = post_process_msgs cstate' new_msgs in

  (*Return new contract state, messages and events *)
  pure (cstate'', new_msgs, new_events, conf'.accepted)
