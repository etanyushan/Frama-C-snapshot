(**************************************************************************)
(*                                                                        *)
(*  This file is part of Frama-C.                                         *)
(*                                                                        *)
(*  Copyright (C) 2007-2008                                               *)
(*    CEA (Commissariat � l'�nergie Atomique)                             *)
(*                                                                        *)
(*  you can redistribute it and/or modify it under the terms of the GNU   *)
(*  Lesser General Public License as published by the Free Software       *)
(*  Foundation, version 2.1.                                              *)
(*                                                                        *)
(*  It is distributed in the hope that it will be useful,                 *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of        *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the         *)
(*  GNU Lesser General Public License for more details.                   *)
(*                                                                        *)
(*  See the GNU Lesser General Public License version 2.1                 *)
(*  for more details (enclosed in the file licenses/LGPLv2.1).            *)
(*                                                                        *)
(**************************************************************************)

open Abstract_interp
open Abstract_value

type itv = Int.t * Int.t

module Make 
  (V:sig 
    include Abstract_interp.Lattice 
    val tag: t -> int
   end) =
struct
  open Abstract_interp

  type t = Map of (bool*V.t) Int_Interv_Map.t | Degenerate of V.t

  let empty = Map Int_Interv_Map.empty

  let degenerate v = Degenerate v

  let pretty_with_type typ fmt m =
    match m with
      Degenerate v ->
	Format.fprintf fmt "@[[..] FROM @[%a@]@]"
	  V.pretty v
    | Map m ->
        let is_first = ref true in
	let pretty_binding (bi,ei) (default,v) =
          let left = match typ with
          | None -> Format.sprintf ":%a..%a" Int.pretty_s bi
              Int.pretty_s ei
          | Some typ -> Format.sprintf "%s"
               (fst
                  (Bit_utils.pretty_bits typ
                     ~use_align:false ~align:Int.zero ~rh_size:Int.one
                     ~start:bi ~stop:ei))
          in
          if !is_first then is_first := false else
            Format.fprintf fmt "@,";
	  Format.fprintf fmt "@[%s FROM @[%a@](and default:%b)@]"
	    left V.pretty v default
	in
	Format.fprintf fmt "@[<v>";
	Int_Interv_Map.iter pretty_binding m;
	Format.fprintf fmt "@]"

  let pretty = pretty_with_type None     

  let rec rehash t = 
    match t with
      Degenerate v -> Degenerate (V.Datatype.rehash v)
    | Map t ->
	Map (Int_Interv_Map.map (fun (b,v) -> b,(V.Datatype.rehash v)) t)

  let rehash_initial_values () = 
    List.iter (fun x -> ignore (rehash x)) [ empty ]

  let name = Project.Datatype.Name.extend "offsetmap_bitwise" V.Datatype.name

  module Datatype =
    Project.Datatype.Register
      (struct
	 type tt = t
	 type t = tt
	 let copy x = x
	 let rehash = rehash
	 let before_load = rehash_initial_values
	 let after_load () = ()
	 let name = name 
	 let dependencies = [ V.Datatype.self ] 
       end)

  let is_empty m =
    match m with
      Map m -> Int_Interv_Map.is_empty m
    | Degenerate _ -> false

  let find default ((bi,ei) as i) m =
    match m with
      Degenerate v -> v
    | Map m ->
	let concerned_intervals =
	  Int_Interv_Map.concerned_intervals Int_Interv.fuzzy_order i m
	in
	let treat_mid_interval (_bk,ek) (bl,_el) acc =
       (*   Format.printf "treat_mid_itv: ek:%a bl:%a@\n" Int.pretty ek
            Int.pretty bl; *)
          let s_ek = Int.succ ek in
          if Int.lt s_ek bl then
	    V.join (default s_ek (Int.pred bl)) acc
          else acc
	in
        let concerned_intervals = List.rev concerned_intervals in
	match concerned_intervals with
	  [] -> default bi ei
	| ((_bk,ek),_)::_ ->
	    let implicit_right =
	      if Int.gt ei ek
	      then default (Int.succ ek) ei
	      else V.bottom
	    in
	    let rec implicit_mid_and_left list acc =
	      match list with
	      | [(bl,_el),_] ->
		  if Int.lt bi bl
		  then V.join acc (default bi (Int.pred bl))
		  else acc
	      | (k,_)::(((l,_)::_) as tail) ->
		  treat_mid_interval k l (implicit_mid_and_left tail acc)
	      | [] -> assert false
	    in
	    let implicit =
	      implicit_mid_and_left concerned_intervals implicit_right
	    in
	    (* now add the explicit values *)
	    List.fold_left
	      (function acc -> function ((bi,ei),(d,v)) ->
		 let valu = V.join v acc in
		 if d then (V.join valu (default bi ei)) else valu
	      )
	      implicit
	      concerned_intervals

  let find_intervs default intervs m =
    Int_Intervals.fold (fun itv acc -> V.join (find default itv m) acc)
      intervs
      V.bottom

  let same_values ((bx:bool),x) (by,y) =
    (bx = by) && (V.equal x y )

  let add_map_internal i v map =
    match Int_Interv_Map.cleanup_overwritten_bindings same_values i v map
    with
    | None -> map
    | Some(new_bi, new_ei, cleaned_m) ->
        (* Add the new binding *)
	let result = Int_Interv_Map.add (new_bi,new_ei) v cleaned_m in
	result

  let merge_map m1 m2 =
    Int_Interv_Map.fold (fun k v acc -> add_map_internal k v acc) m1 m2

(* low-level add to manipulate the pairs (default,value) *)
  let add_internal ((_bi,_ei) as i) (_bv, tv as v) m =
    match m with
    | Degenerate v1 -> Degenerate (V.join tv v1)
    | Map map ->
	Map (add_map_internal i v map)
(* exact add *)
  let add i v m = add_internal i (false,v) m

(* approximate add; currently not as precise as could be *)
  let add_approximate (bi, ei as i) v m =
   match m with
    | Degenerate v1 -> Degenerate (V.join v v1)
    | Map map ->
	let concerned_intervals =
	  Int_Interv_Map.concerned_intervals Int_Interv.fuzzy_order i map
	in
	let new_v =
	  List.fold_left
	    (fun vacc (_,(_,v)) ->
	      (V.join vacc v))
	    v
	    concerned_intervals
	in
	let d =
	  match concerned_intervals with
	    [(bj,ej),(d,_)] ->
	      if (Int.le bj bi) && (Int.ge ej ei)
	      then d
	      else true
	  | _ -> true
	in
	add_internal i (d, new_v) m

  let collapse m =
    match m with
    | Degenerate v -> v
    | Map map ->
	Int_Interv_Map.fold (fun _ (_,v) acc -> V.join acc v) map V.bottom

  let find_iset default alldefault is m =
    if Int_Intervals.is_top is
    then
      V.join alldefault (collapse m)
    else
      let s = Int_Intervals.project_set is in
      if s = [] 
      then V.bottom
      else begin 
	  match m with
	  | Degenerate v ->
	      List.fold_left
		(fun acc i -> V.join acc (default (fst i) (snd i)))
		v s
	  | Map _ ->
	      let f acc i =  V.join acc (find default i m) in
	      List.fold_left f V.bottom s
	end

  let add_iset ~exact is v m =
    if Int_Intervals.is_top is 
    then Degenerate (V.join v (collapse m))
    else begin
	let s = Int_Intervals.project_set is in
	match m with
	| Degenerate v1 -> Degenerate (V.join v v1)
	| Map _ ->
	    let result =
	      List.fold_left
		(fun acc i ->
		   (if exact then add else add_approximate)
		   i v acc)
		m
		s
	    in
	    result
    end

  let joindefault_internal =
    Int_Interv_Map.map
      (fun v -> true, (snd v))

  let fold f m acc =
    match m with
      | Degenerate v ->
	  f Int_Intervals.top (true,v) acc
      | Map m ->
	  Int_Interv_Map.fold
	    (fun i v acc ->
	       f (Int_Intervals.inject [i]) v acc)
	    m
	    acc

  let map_map f m =
    Int_Interv_Map.fold
      (fun i v acc -> add_map_internal i (f v) acc)
      (* [pc] add_internal could be replaced by a more efficient
	 function that assumes there are no bindings above i *)
      m
      Int_Interv_Map.empty

  let map f m =
    match m with
      | Degenerate v -> Degenerate (snd (f (true,v)))
      | Map m ->
          Map (map_map f m)
	
  let equal_map mm1 mm2 =
    ( try
	Int_Interv_Map.equal
          (fun (bx,x) (by,y) -> (bx = by) && V.equal x y )
          mm1 mm2
      with Int_Interv.Cannot_compare_intervals -> false )

  let equal m1 m2 =
    match m1, m2 with
      Degenerate v1, Degenerate v2 ->
	V.equal v1 v2 
    | Map mm1, Map mm2 ->
	equal_map mm1 mm2
    | Map _, Degenerate _ | Degenerate _, Map _ -> false

(*  let check_contiguity m = 
    let id = map (fun x -> x) m in
    assert (equal id m)

  let check_map_contiguity m =
    let id = map_map (fun x -> x) m in
    assert (equal_map id m)
*)
  let joindefault m =
    match m with
      Degenerate _ -> m
    | Map m ->
	Map (joindefault_internal m)

  let map2
      (f : (bool * V.t) option -> (bool * V.t) option -> bool * V.t)
      mm1 mm2 =
(*    check_contiguity(mm2);
    check_contiguity(mm1); *)
    let result = 
    match mm1, mm2 with
    | Degenerate(v), m | m, Degenerate(v) ->
	Degenerate (snd (f (Some (true, v)) (Some (true, collapse m))))
    | Map(m1), Map(m2) ->
	(*Format.printf "map2: m1:@\n%a@\nm2:@\n%a@\n"
	  pretty mm1 pretty mm2;*)
	let compute_remains_m1_and_merge m1 acc =
	  let remains =
	    map_map
	      (fun vv -> f (Some vv) None)
	      m1
	  in
	   merge_map remains acc
	in
	let compute_remains_m2_and_merge m2 acc =
(*	  check_map_contiguity(acc); *)
	  let remains = map_map
	    (fun vv -> f None (Some vv))
	    m2
	  in
(*	  check_map_contiguity(remains); *)
	  let result = merge_map remains acc in
(*	  check_map_contiguity(result);*)
	  result
	in
	let rec out_out (b1,_e1 as i1) v1 m1 (b2, _e2 as i2) v2 m2 acc =
	  (*Format.printf "out_out: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1 Int.pretty e1 Int.pretty b2 Int.pretty e2; *)
(*	  check_map_contiguity(acc);*)
	  let result = 
	    if Int.lt b1 b2
	    then in_out i1 v1 m1  i2 v2 m2  acc
	    else if Int.gt b1 b2
	    then out_in i1 v1 m1  i2 v2 m2  acc
	    else (* b1 = b2 *)
	      in_in i1 v1 m1  i2 v2 m2  acc
	  in
(*	  check_map_contiguity(result);*)
	  result
	and in_out (b1,e1 as i1) v1 m1  (b2, _e2 as i2) v2 m2  acc =
           (*Format.printf "in_out: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1 Int.pretty e1 Int.pretty  b2 Int.pretty e2; *)
(*	  check_map_contiguity(acc);*)
          assert (Int.gt b2 b1);
	  let result =
	    let pb2 = Int.pred b2 in
	    let new_v = f (Some v1) None in
	    if Int.lt pb2 e1
	    then begin (* -> in_in *)
		let new_acc = add_map_internal (b1,pb2) new_v acc in
		in_in (b2,e1) v1 m1  i2 v2 m2  new_acc
	      end
	    else begin
		let new_acc = add_map_internal i1 new_v acc in
		try
		  let (new_i1, new_v1) = Int_Interv_Map.lowest_binding m1 in
		  let new_m1 = Int_Interv_Map.remove new_i1 m1 in
		  if Int.lt e1 pb2
		  then (* -> out_out *)
		    out_out new_i1 new_v1 new_m1 i2 v2 m2  new_acc
		  else (* pb2 = e1 *)
		    (* -> in_or_out_in *)
	            in_or_out_in new_i1 new_v1 new_m1  i2 v2 m2  new_acc
		with Int_Interv_Map.Empty_rangemap ->
		  compute_remains_m2_and_merge (add_map_internal i2 v2 m2) new_acc
	      end
	  in
(*	  check_map_contiguity(result);*)
	  result
	and out_in (b1,_e1 as i1) v1 m1  (b2, e2 as i2) v2 m2  acc =
           (* Format.printf "out_in: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1
	     Int.pretty e1
	     Int.pretty b2
	     Int.pretty e2; *)
(*	  check_map_contiguity(acc);*)
          assert (Int.lt b2 b1);
	  let result =
	  let pb1 = Int.pred b1 in
	  let new_v = f None (Some v2) in
	  if Int.lt pb1 e2
	  then begin (* -> in_in *)
	    let new_acc = add_map_internal (b2,pb1) new_v acc in
	    in_in i1 v1 m1  (b1,e2) v2 m2  new_acc
	  end
	  else begin
	    let new_acc = add_map_internal i2 new_v acc in
	    try
	      let (new_i2, new_v2) = Int_Interv_Map.lowest_binding m2 in
	      let new_m2 = Int_Interv_Map.remove new_i2 m2 in
	      if Int.lt e2 pb1
	      then (* -> out_out *)
		out_out i1 v1 m1 new_i2 new_v2 new_m2  new_acc
	      else (* pb1 = e2 *)
		(* -> in_in_or_out *)
		in_in_or_out i1 v1 m1 new_i2 new_v2 new_m2  new_acc
	    with Int_Interv_Map.Empty_rangemap ->
	      compute_remains_m1_and_merge (add_map_internal i1 v1 m1) new_acc
	    end
	  in
(*	  check_map_contiguity(result);*)
	  result
	and in_in_or_out (b1,_e1 as i1) v1 m1  (b2,_e2 as i2) v2 m2 acc =
	    (*Format.printf "in_in_or_out: b1=%a e1=%a b2=%a e2=%a@\n"
	     Int.pretty b1 Int.pretty e1 Int.pretty b2 Int.pretty e2;*)
          (if Int.eq b1 b2 then in_in else (assert (Int.lt b1 b2);in_out))
            i1 v1 m1 i2 v2 m2 acc
	and in_or_out_in (b1,_e1 as i1) v1 m1  (b2,_e2 as i2) v2 m2 acc =
	   (*Format.printf "in_or_out_in: b1=%a e1=%a b2=%a e2=%a@\n"
	    Int.pretty b1
	     Int.pretty e1
	     Int.pretty b2
	     Int.pretty e2;*)
          (if Int.eq b1 b2 then in_in else (assert (Int.gt b1 b2);out_in))
            i1 v1 m1 i2 v2 m2 acc
	and in_in_e1_first (_b1, e1 as i1) _v1 m1 (_b2, e2) v2 m2 acc new_v12 =
          (*Format.printf "in_in_e1_first: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1 Int.pretty e1 Int.pretty b2 Int.pretty e2; *)
	  assert (Int.lt e1 e2);
	  let new_acc = add_map_internal i1 new_v12 acc in
	  let new_i2 = (Int.succ e1,e2) in
	  try
	    let (new_i1, new_v1) = Int_Interv_Map.lowest_binding m1 in
	    let new_m1 = Int_Interv_Map.remove new_i1 m1 in
	    in_or_out_in new_i1 new_v1 new_m1  new_i2 v2 m2  new_acc
	  with Int_Interv_Map.Empty_rangemap ->
	    compute_remains_m2_and_merge 
	      (add_map_internal new_i2 v2 m2) new_acc
	and in_in_e2_first (_b1, e1) v1 m1 (_b2, e2 as i2) _v2 m2 acc new_v12=
          (*Format.printf "in_in_e2_first: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1 Int.pretty e1 Int.pretty b2 Int.pretty e2; *)
	  assert (Int.lt e2 e1);
	  let new_acc = add_map_internal i2 new_v12 acc in
	  let new_i1 = (Int.succ e2,e1) in
	  try
	    let (new_i2, new_v2) = Int_Interv_Map.lowest_binding m2 in
	    let new_m2 = Int_Interv_Map.remove new_i2 m2 in
	    in_in_or_out new_i1 v1 m1  new_i2 new_v2 new_m2  new_acc
	  with Int_Interv_Map.Empty_rangemap ->
	    compute_remains_m1_and_merge 
	      (add_map_internal new_i1 v1 m1) new_acc
	and in_in_same_end (_b1, e1 as i1) _v1 m1 (_b2, e2) _v2 m2 acc new_v12=
	  (*Format.printf "in_in_same_end: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1 Int.pretty e1 Int.pretty b2 Int.pretty e2; *)
	  assert (Int.eq e1 e2);
     
	  let acc = add_map_internal i1 new_v12 acc in
          try
	    let (new_i1, new_v1) = Int_Interv_Map.lowest_binding m1 in
	    let new_m1 = Int_Interv_Map.remove new_i1 m1 in
	    try
	      let (new_i2, new_v2) = Int_Interv_Map.lowest_binding m2 in
	      let new_m2 = Int_Interv_Map.remove new_i2 m2 in
	      out_out new_i1 new_v1 new_m1  new_i2 new_v2 new_m2 acc
	    with Int_Interv_Map.Empty_rangemap ->
	      compute_remains_m1_and_merge m1 acc
	  with Int_Interv_Map.Empty_rangemap ->
	    compute_remains_m2_and_merge m2 acc
	and in_in (b1, e1 as i1) v1 m1 (b2, e2 as i2) v2 m2 acc =
	  (*Format.printf "in_in: b1=%a e1=%a b2=%a e2=%a@\n"
            Int.pretty b1 Int.pretty e1 Int.pretty b2 Int.pretty e2; *)
          assert (Int.eq b1 b2);
      
	  let new_v12 = f (Some v1) (Some v2) in
	  (if Int.gt e1 e2
	   then in_in_e2_first
	   else if Int.lt e1 e2
	   then in_in_e1_first
	   else in_in_same_end)
	    i1 v1 m1  i2 v2 m2  acc  new_v12
	in
	try
	  let i1, v1 = Int_Interv_Map.lowest_binding m1 in
	  try
	    let i2, v2 = Int_Interv_Map.lowest_binding m2 in
	    let new_m1 = Int_Interv_Map.remove i1 m1 in
	    let new_m2 = Int_Interv_Map.remove i2 m2 in
	    Map (out_out i1 v1 new_m1 i2 v2 new_m2 Int_Interv_Map.empty)
	  with Int_Interv_Map.Empty_rangemap -> mm1
	with Int_Interv_Map.Empty_rangemap -> mm2
    in
(*    check_contiguity(result);*)
    result

  let rec check_inter offs1 offs2 =
    let check bi ei =
      let concerned_intervals =
	Int_Interv_Map.concerned_intervals
	  Int_Interv.fuzzy_order (bi,ei) offs2
      in
      List.iter
	(fun (_,(b,_v)) -> if not b then raise Is_not_included)
	concerned_intervals
    in
    let f (bi,ei) _ acc =
      match acc with
	None ->
	  (* (* now we do something about -**..bi *)
	  if Int.neq bi Int.min_int
	  then check Int.min_int (Int.pred bi);*)
	  Some ei
      | Some ek ->
	  let pbi = Int.pred bi in
	  if Int.lt ek pbi
	  then check (Int.succ ek) pbi;
	  Some ei
    in
    match Int_Interv_Map.fold f offs1 None with
    | None -> ()
    | Some _ek ->
	(* if Int.lt ek Int.max_int
	then check (Int.succ ek) Int.max_int *)
        ()

  let is_included_exn offs1 offs2 =
    if offs1 != offs2 then
      match offs1, offs2 with
      | Map offs1, Map offs2 ->
	  let treat_itv (_bi, _ei as i) (di,vi) =
	    let concerned_intervals =
	      Int_Interv_Map.concerned_intervals Int_Interv.fuzzy_order i offs2
	    in
	    Int_Interv.check_coverage i concerned_intervals;
	    List.iter
	      (fun ((_bj, _ej),(dj,vj)) ->
		 if di && (not dj) then raise Is_not_included;
		 if not (V.is_included vi vj) then raise Is_not_included)
	      concerned_intervals
	  in
	  Int_Interv_Map.iter treat_itv offs1    ;
	  check_inter offs1 offs2
      | Degenerate _v1, Map _offs2 ->
          raise Is_not_included
      | _, Degenerate v2 ->
	  if not (V.is_included (collapse offs1) v2)
	  then raise Is_not_included

  let is_included m1 m2 =
    try is_included_exn m1 m2; true with
      Is_not_included -> false

  let join mm1 mm2 =
(*    check_contiguity(mm1);
    check_contiguity(mm2);
*)
    if mm1 == mm2 then mm1 else
      let result = map2
	(fun v1 v2 -> match v1,v2 with
	   | None, None -> assert false
	   | Some v , None | None, Some v -> true, snd v
	   | Some v1, Some v2 ->
               (fst v1 || fst v2), (V.join (snd v1) (snd v2)))
	mm1 mm2
      in
(*      check_contiguity(result);*)
      result

  (* map [f] on [offs] and merge with [acc] *)
  let map_and_merge f offs acc =
(*    check_contiguity(acc);
    check_contiguity(offs);*)
    let generic_f v1 v2 = match v1,v2 with
    | None, None -> assert false
    | Some (d,v), None  ->
        d,f v
    | None, Some vv -> vv
    | Some (d1,v1), Some (d2,v2) ->
        d1&&d2,
        if d1 then V.join (f v1) v2 else f v1
    in
    (*Format.printf "Offsetmap.map_and_merge offs:%a and acc:%a@." 
         (pretty None) offs
         (pretty None) acc;*)
    let result = map2 generic_f offs acc in
(*    check_contiguity(result);*)
    result

(* this code was copied from the non-bitwise lattice, it could be shared
   if it was placed in Int_Interv_Map. TODO PC 2007/02 *)
  let copy_paste_map ~f from start stop start_to _to =
    let result =
      let ss = start,stop in
      let to_ss = start_to, Int.sub (Int.add stop start_to) start in
        (* First removing the bindings of the destination interval *)
      let _to = Int_Interv_Map.remove_itv Int_Interv.fuzzy_order to_ss _to in
      let concerned_itv =
        Int_Interv_Map.concerned_intervals Int_Interv.fuzzy_order ss from
      in
      let offset = Int.sub start_to start in
      let current = ref start in
      let f, treat_empty_space =
	match f with
	  Some (f, default) -> f, 
	    (fun acc i ->
	      let src_b = !current in
	      if My_bigint.le_big_int i src_b 
	      then acc
	      else
		let src_e = Int.pred i in
		let dest_itv = Int.add (!current) offset, Int.add src_e offset in
		(*	    Format.printf "treat_empty ib=%a ie=%a@."
			    Int.pretty src_b
			    Int.pretty src_e;*)
		add_map_internal dest_itv (f (true, default src_b src_e)) acc)
        | None -> (fun x -> x), (fun acc _i -> acc)
      in
      let treat_interval ((b,_) as i,v) acc =
	let acc = treat_empty_space acc b in
        let new_vv = f v in
        let src_b, src_e = Int_Interv.clip_itv ss i in
        let dest_i = Int.add src_b offset, Int.add src_e offset in
	current := Int.succ src_e;
        (*Format.printf "treat_itv: ib=%a ie=%a v=%a dib=%a die=%a@."
          Int.pretty (fst i) Int.pretty (snd i)
          V.pretty v
          Int.pretty (fst dest_i) Int.pretty (snd dest_i);*)
        add_map_internal dest_i new_vv acc
      in
      let acc = List.fold_right treat_interval concerned_itv _to in
      treat_empty_space acc (Int.succ stop)
    in
(*      Format.printf "Offsetmap.copy_paste from:%a start:%a stop:%a start_to:%a to:%a result:%a@\n"
        (pretty None) (Map from)
        Int.pretty start
        Int.pretty stop
        Int.pretty start_to
        (pretty None) (Map _to)
        (pretty None) (Map result); *)
      result  
	
  let copy_paste ~f from start stop start_to _to =
    match from, _to with
      Map from, Map _to -> Map (copy_paste_map ~f from start stop start_to _to)
    | _, _ -> 
	let collapse_from = collapse from in
	let value_from =
	 ( match f with
	    Some (f,_default) ->
	       (snd (f (true,collapse_from)))
	| None -> collapse_from )
	in
	Degenerate (V.join value_from (collapse _to))

  let copy_merge from start stop start_to _to =
    let old_value =
      copy_paste ~f:None
	_to start_to
        (Int.sub (Int.add start_to stop) start)
        start empty
    in
    let merged_value = join old_value from in
    copy_paste ~f:None merged_value start stop start_to _to

  let copy ~f from start stop =
    copy_paste ~f from start stop Int.zero empty

  let tag x = match x with
    | Degenerate v -> 571 + V.tag v
    | Map map -> 
	Int_Interv_Map.fold 
	  (fun k (_b, v) acc -> Int_Interv.hash k + V.tag v * 3 + 5 * acc)
	  map
	  0

end